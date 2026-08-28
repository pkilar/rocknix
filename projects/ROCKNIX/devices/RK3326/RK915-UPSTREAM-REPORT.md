# Upstream report: RK915 stops responding under concurrent traffic

Draft for <https://github.com/stolen/rk915>. Everything below was observed on a
Gusgu H7 (RK3326, PX30) running mainline 7.1.2, with the driver pinned to
`sunshineinabox/rk915` @ `86f0d0e0` (head of PR #2, the 7.1 branch).

## Symptom

Under **concurrent** network traffic the chip stops responding within seconds.
Sequential traffic does not trigger it: 35 back-to-back HTTP fetches in a row
were clean, while 8 parallel keep-alive connections kill it in ~10 s, after
anywhere from 10 to 80 requests.

The first thing the driver sees is a write timing out:

```
rk915: rk915_data_write: addr=0 len=1542 -110
rk915: -------- fw error recovery (0) start --------
rk915: fw error (0): requesting mac80211 restart
```

## Reproducer

```python
import threading, socket, base64
IP = "<device>"
auth = base64.b64encode(b"root:rocknix").decode()
def worker(path):
    while True:
        s = socket.create_connection((IP, 80), timeout=8)
        for _ in range(20):
            s.sendall((f"GET {path} HTTP/1.1\r\nHost: {IP}\r\n"
                       f"Authorization: Basic {auth}\r\n"
                       "Connection: keep-alive\r\n\r\n").encode())
            s.recv(65536)
        s.close()
for p in ["/roms/"]*6 + ["/", "/assets/"]:
    threading.Thread(target=worker, args=(p,), daemon=True).start()
```

Any source of several simultaneous TCP flows does it; a web browser loading a
directory listing is enough.

## What the chip does

An in-driver ring recording the last 24 data transfers, dumped when one fails:

```
RKTRACE -349058us wr addr=0 len=1542 ret=0
RKTRACE -348971us wr addr=0 len=762  ret=0
RKTRACE -348854us wr addr=0 len=1542 ret=0
   ... writes every ~118us ...
RKTRACE -348380us wr addr=0 len=1542 ret=0     <- last activity
RKTRACE     -59us wr addr=0 len=1542 ret=-110  <- 348ms later, ETIMEDOUT
```

The chip does not fail mid-transfer. It goes quiet during an idle gap in the data
path, and the next write times out. The host-wake GPIO stops asserting at the
same time (its interrupt count freezes), so the rx thread never wakes and nothing
notices until a write fails.

(The ring records data transfers only, not CMD52 register access.)

## Ruled out

Each of these was tested on the hardware, not just reasoned about:

- **Bus clock gating.** `CLKENA = 0x00000001` — `SDMMC_CLKENA_LOW_PWR` clear, so
  `MMC_QUIRK_SDIO_CONT_CLOCK` is doing its job and the clock runs during idle.
- **LMAC sleep.** `lpw_no_sleep=1`, and it reaches
  `wifi->params.rpu_sleep_type = LMAC_NO_SLEEP` in `proc_init()`.
- **`ALIGN(buf_len, 4)` in `rk915_data_write()`.** Present in the BSP import too,
  and every padded transfer returns 0 (`1542→1544`, `581→584`, `762→764`).
- **TX descriptor atomicity.** `rpu_send_cmd_datas()` claims and releases the
  host per frame, so rx can interleave between frames of one descriptor. Holding
  the host across the whole descriptor did not help.
- **The radio-retune window.** `rk915_serias_read()` carries a guard with the
  comment *"fw wedges the sdio engine if hit mid radio-retune"*; the tx path has
  none. Adding the same guard to `rk915_data_write()` did not help, though the
  background scan (`bg_scan_intval` 5 s) does open that window regularly.

## Two driver bugs found and fixed along the way

Independent of the fault above, these stopped the driver's own recovery from ever
working. Patches available on request.

### 1. The `sdio_reset` latch makes recovery a no-op

`_sdio_reset()` sets a file-static flag, and every accessor then returns success
**without performing any i/o**:

```c
static int sdio_send_data(struct host_io_info *host, u32 addr, u8 *buf, u32 len)
{
        if (sdio_reset == true)
                return 0;
        return sdio_memcpy_toio(func, addr, buf, len);
}
```

`rk915_io_reset()` arms it from six sites in `hal_io.c`, and nothing cleared it
except `sdio_probe()`. So after any io error the firmware re-download that
recovery depends on writes into nothing and the readback is all zeroes:

```
rk915: 30550/48056 bytes differ, first at 0x0 (wrote 0x81 read 0x00)
rk915: rk915_download: check downloaded fw failed
rk915: fw_bring_up: rk915_download_firmware failed
```

Per-block timing confirms nothing is transferred: a failing download "writes"
4096 bytes in **2 µs** (~2 GB/s) versus 269 µs for the same block when it works.
This is also why reloading the module was the only thing that ever restored the
link — `sdio_probe()` clears the latch.

Clearing it in `rk915_sdio_power_cycle()`, once the card has been reset,
re-enabled and had its block size restored, makes recovery work: 23 recoveries,
31 successful firmware downloads, 0 failures, link back with the same interface
and lease.

### 2. VIF accounting is never reset across a hardware restart

`current_vif_count` / `active_vifs` are cleared only in `rpu_init()`. mac80211
re-adds interfaces after `ieee80211_restart_hw()` but never calls
`remove_interface()` for the old ones, so once recovery started working the
*second* restart hit:

```
rk915: add_interface: Exceeded Maximum supported VIF's cur:2 max: 2
```

`add_interface()` returns `-ENOTSUPP` and the link stays down despite a clean
firmware reload. Clearing them in `start()` fixes it.

### Minor: racy fw-error claim

`rk915_signal_io_error()` guards with a plain test-then-set; rx and tx both get
through and `ieee80211_restart_hw()` is called twice, 163 µs apart. `cmpxchg()`
fixes it.

## Also worth knowing: MAC address

`init_mac_addr()` falls back to `eth_random_addr()` when the DT has no MAC, so
the interface gets a new address and DHCP lease on every load. The BSP used
`rockchip_wifi_mac_addr()` (Rockchip vendor storage), which has no mainline
equivalent. On Rockchip boards the vendor U-Boot already exports that MAC as
`ethaddr`, so an `/aliases/ethernet0` pointing at the wifi node lets
`fdt_fixup_ethernet()` supply it per-device — no DT hardcoding needed. Might be
worth a note in the README.

## Environment

- Gusgu H7, RK3326/PX30, SDIO wifi on `mmc@ff380000`, 4-bit, 50 MHz
- mainline 7.1.2, driver `86f0d0e0` (PR #2 branch)
- firmware `rk915_fw.bin` / `rk915_patch.bin`, patch 2_1_2 build Dec 29 2021,
  byte-identical to the blobs in the vendor image
- kernel-side quirks patch from PR #2 applied
