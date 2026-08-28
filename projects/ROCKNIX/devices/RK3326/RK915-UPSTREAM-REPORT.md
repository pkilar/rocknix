# Upstream report — draft for `sunshineinabox/rk915`, branch `WIP-RK915_7.1`

Filed against the branch we build from, following `docs/` as written: the 7.1
quirks patch, the DTS example, and `firmware/rockchip`. Hardware is a Gusgu H7
(RK3326/PX30), mainline 7.1.2, driver at `86f0d0e0`.

Our device tree matches `docs/mainline-linux-dts-example.dtsi` property for
property, differing only in the host-wake pin (`RK_PA1` on this board rather than
`RK_PA5`), and our copy of the quirks patch is byte-identical to yours.

The README lists two known issues. **The second one has a fix below.** The first
one we could not solve, but we can hand you a deterministic reproducer and a list
of what it is not.

---

## Known issue 2: "Unloading the driver will likely stall your system"

This is not really a driver bug — it is a gap in `dw_mmc`. `dw_mci_set_drto()` is
armed only for reads:

```c
if (host->dir_status == MMC_DATA_READ)
        dw_mci_set_drto(host);
```

so a **write** to a card that has stopped responding has no timeout at all, and
`mmc_wait_for_req()` waits forever. Captured with sysrq-w:

```
task:rk915_tx  state:D
  wait_for_completion / mmc_wait_for_req_done / mmc_io_rw_extended
  / sdio_memcpy_toio / rk915_data_write [rk915] / tx_thread [rk915]
task:rk915_rx  state:D
  __mmc_claim_host / sdio_claim_host / rk915_serias_read [rk915]
```

The rx thread is simply queued behind tx on the host lock. Nothing errors, so
recovery never starts and the module refcount never drops — hence the stall on
unload.

Arming `dw_mci_set_drto()` for writes as well fixes it. The timeout comes from
`TMOUT`, which `dw_mci_set_data_timeout()` programs per request from
`data->timeout_ns`, so it is the timeout the core asked for. After this, the same
fault produces:

```
rk915: rk915_data_write: addr=0 len=1542 -110
rk915: -------- fw error recovery (0) start --------
```

and the driver unloads normally.

We also hit a `dw_mmc` interrupt storm worth knowing about: `TXDR`/`RXDR` are
enabled unconditionally by the initial `INTMASK` and never masked for DMA
transfers, where `host->sg` is NULL and the handler can only clear the latch.
Harmless while DMA drains the FIFO — but when the card dies the condition
persists and the level-triggered line storms at ~684,000/s, which on RK3326
(where all device interrupts are affine to CPU0) takes the whole machine down.
Masking them for the duration of a DMA transfer fixes it. Happy to send both
patches.

---

## Bug: the `sdio_reset` latch makes firmware recovery a silent no-op

This one is squarely in the driver, and it is why recovery never works.

`_sdio_reset()` sets a file-static flag, after which **every accessor returns
success without performing any i/o**:

```c
static int sdio_send_data(struct host_io_info *host, u32 addr, u8 *buf, u32 len)
{
        if (sdio_reset == true)
                return 0;
        return sdio_memcpy_toio(func, addr, buf, len);
}
```

`rk915_io_reset()` arms it from six sites in `hal_io.c`, so any io error sets it,
and nothing clears it except `sdio_probe()`. So the firmware re-download that
error recovery depends on writes into nothing:

```
rk915: 30550/48056 bytes differ, first at 0x0 (wrote 0x81 read 0x00)
rk915: rk915_download: check downloaded fw failed
rk915: fw_bring_up: rk915_download_firmware failed
WARNING: net/mac80211/util.c:1956 at ieee80211_reconfig
```

Per-block timing shows nothing is transferred: a failing download "writes" 4096
bytes in **2 µs** (~2 GB/s) versus 269 µs for the same block when it works. It
also explains why reloading the module is the only thing that ever restores the
link — `sdio_probe()` clears the latch.

Clearing it at the end of `rk915_sdio_power_cycle()`, once the card has been
reset, re-enabled and had its block size restored, makes recovery work:
**23 recoveries, 31 successful firmware downloads, 0 failures**, link back with
the same interface and DHCP lease.

## Bug: vif accounting is never reset across a hardware restart

`current_vif_count` / `active_vifs` are cleared only in `rpu_init()`. mac80211
re-adds interfaces after `ieee80211_restart_hw()` but never calls
`remove_interface()` for the previous ones, so once recovery started working the
*second* restart hit:

```
rk915: add_interface: Exceeded Maximum supported VIF's cur:2 max: 2
```

`add_interface()` returns `-ENOTSUPP` and the link stays down despite a clean
firmware reload. Clearing both in `start()` fixes it — `start()` always runs
before interfaces are re-added.

## Minor: racy firmware-error claim

`rk915_signal_io_error()` guards with a plain test-then-set, so the rx and tx
threads both get through and `ieee80211_restart_hw()` is called twice, 163 µs
apart:

```
[2250.486151] rk915: -------- fw error recovery (0) start --------
[2250.486314] rk915: -------- fw error recovery (0) start --------
```

`cmpxchg()` on `fw_error_processing` fixes it.

---

## Known issue 1: "Soon after association chip disconnects from network"

Still unsolved here, but we can narrow it.

**It needs concurrency.** 35 sequential HTTP fetches were clean; 8 parallel
keep-alive connections kill it in ~10 s, after 10–80 requests. Any several
simultaneous TCP flows will do — a browser loading a directory listing is enough:

```python
import threading, socket, base64
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

**The chip goes quiet while idle, not mid-transfer.** An in-driver ring of the
last 24 data transfers, dumped when one fails:

```
RKTRACE -348497us wr addr=0 len=1542 ret=0    writes every ~118us
RKTRACE -348380us wr addr=0 len=1542 ret=0    last activity
RKTRACE     -59us wr addr=0 len=1542 ret=-110 348ms later, ETIMEDOUT
```

The host-wake GPIO stops asserting at the same time (its interrupt count
freezes), so the rx thread never wakes and nothing notices until a write fails.
The ring records data transfers only, not CMD52.

**Ruled out on hardware**, so nobody repeats them:

| Hypothesis | Result |
|---|---|
| Bus clock gating | `CLKENA = 0x00000001`, `LOW_PWR` clear — `MMC_QUIRK_SDIO_CONT_CLOCK` working |
| LMAC sleep | `lpw_no_sleep=1` reaching `rpu_sleep_type = LMAC_NO_SLEEP` |
| `ALIGN(buf_len, 4)` padding | also in the BSP import; every padded transfer returns 0 |
| TX descriptor atomicity | `rpu_send_cmd_datas()` claims/releases per frame so rx can interleave; holding the host across the descriptor did not help |
| Radio-retune window | added `rk915_serias_read()`'s guard to the tx path; did not help |
| cpuidle deep states | `cpuidle.off=1` — no change |
| Tickless idle | `nohz=off` — no change |
| Dropping `cap-sdio-irq` | breaks bring-up entirely: the core falls back to a polling SDIO irq thread whose CMD52s collide with the driver (`rk915_serias_read: error -110`) |

If there is a documented handshake for the host-wake line, or a flow-control or
buffer-credit rule around `num_frames_per_desc`, that is where we would look
next — the hardware datasheet in `docs/` is electrical only.

## Aside: MAC address

`init_mac_addr()` falls back to `eth_random_addr()` when the DT carries no MAC,
so the interface gets a new address and DHCP lease on every load — awkward given
how often the driver is reloaded. The BSP used `rockchip_wifi_mac_addr()`
(Rockchip vendor storage), which has no mainline equivalent.

On Rockchip boards the vendor U-Boot already reads that same vendor storage and
exports it as `ethaddr`, and `fdt_fixup_ethernet()` writes it into whatever
`/aliases/ethernet0` resolves to. Pointing that at the wifi node gives a stable
per-device MAC with nothing hardcoded:

```dts
aliases {
        ethernet0 = &rk915_wifi;
};
```

Verified: the node comes up carrying `local-mac-address = 1e 28 78 e8 94 15`
written by U-Boot, and `of_get_mac_address()` picks it up. Might be worth a line
in the README, since the binding already documents both MAC properties.
