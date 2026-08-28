# RK915 WiFi on the Gusgu H7

Investigation record for the RK915 SDIO WiFi chip on the Gusgu H7 (RK3326),
running the ROCKNIX port on branch `gusgu-h7-port`, kernel 7.1.2.

## State of play

WiFi associates, gets a lease, and holds a stable MAC. Above a throughput
threshold the chip still faults — but a fault is now a brief self-healing blip
instead of a hard hang.

| | Before | Now |
|---|---|---|
| Fault under load | whole machine hangs, power cycle required | link drops, recovers itself |
| SDIO interrupt storm | starves every interrupt on CPU0 | contained — 937 masked in 9 min, no hang |
| Driver after a fault | tx/rx threads stuck in `D`, module unloadable | errors out, recovery runs |
| Firmware recovery | never completed | 10 recoveries in one session, link back every time |
| vif accounting | 2nd restart hit `Exceeded Maximum` | 10 restarts, no exhaustion |
| MAC / DHCP lease | new random MAC every module load | stable, from vendor storage |

**Not fixed:** sustained transfer above roughly 15–29 KB/s kills the link within
seconds, in either direction. Everything below documents what that is, what it is
not, and how to reproduce it.

**Workaround:** rate-limit. `rsync --bwlimit=15` moved a 24 MB kernel image onto
the device over this link, first attempt, zero faults.

## Reproducer

It is **throughput**, not concurrency and not direction. One connection is
enough, and receiving kills it as readily as transmitting.

| Test | Shape | Result |
|---|---|---|
| single stream, device transmits | continuous | died at 0.20 / 0.46 / 0.79 MB, ~10 s |
| single stream, device receives | continuous | died at 0.44 MB / 19 s, and 0.62 MB on a retest |
| 8 parallel keep-alive HTTP | continuous | dies after 10–80 requests |
| 24 MB rsync at `--bwlimit=15` | continuous | **clean, no faults** |
| 35 sequential ~49 KB bursts, 12 s apart | bursty | clean |
| ordinary idle use | bursty | 383 MB over 13 h 44 m, zero faults |

So the threshold is a *rate* — somewhere between 15 and 29 KB/s — not a byte
count. Minimal form, one stream, no HTTP:

```sh
laptop$  nc -l -p 5001 > /dev/null
device$  dd if=/dev/zero bs=64k | nc $LAPTOP_IP 5001
```

The browser-shaped version, which is how this was first hit — a directory listing
in the built-in web server is enough:

```python
# 8 parallel keep-alive connections; dies within ~10s
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

## The fixes

### Kernel — `patches/linux/036-dw_mmc-dont-spin-on-a-dead-bus.patch`

**TXDR/RXDR storm.** These signal "the FIFO needs CPU servicing" and are only
meaningful for PIO. `dw_mci_submit_data_dma()` *does* mask them for the duration
of a DMA transfer — but nothing masks them once a transfer is over. They are
enabled by `dw_mci_probe()`, again by `dw_mci_runtime_resume()`, and again by
every PIO transfer in `dw_mci_submit_data()`; the only thing that clears them is
the *next* DMA transfer. A driver mixing CMD52 (PIO) with block transfers
therefore leaves them enabled for long stretches with `host->sg == NULL`, where
the handler can only clear the latch. Harmless while the condition is transient;
lethal when the card dies, because it then persists and the level-triggered line
storms:

```
IRQTRACE 344 dwmci: 56:164736147  vop=11531 adc=24734 ser=418 gpio=10946
IRQTRACE 345 dwmci: 56:165433415  vop=11531 adc=24734 ser=418 gpio=10946
```

~697,000 more interrupts between two consecutive samples on `mmc@ff380000`, with
every other interrupt on that CPU frozen at a fixed count. All device interrupts
on this board are affine to CPU0, so the VOP stops (drm vblank timeouts), the
SARADC stops (joypad error spam) and the network dies. Fixed by masking the bit
in the handler when it fires with nothing to service; `dw_mci_submit_data()`
re-enables it for the next PIO transfer.

An earlier version of this patch also masked the bits in `dw_mci_submit_data()`'s
DMA branch. That was **removed as provably dead**: the branch runs only when
`dw_mci_submit_data_dma()` returned 0, which is the one path that has just
executed the identical mask, and `dw_mci_idmac_start_dma()` touches CTRL/BMOD/
PLDMND but never INTMASK. Verified on hardware after removal — same containment,
937 storms masked in 9 minutes with no hang.

**Write data timeout.** `dw_mci_set_drto()` was armed only for reads, so a write
to a card that stops responding had no timeout at all and `mmc_wait_for_req()`
waited forever:

```
task:rk915_tx  state:D
  wait_for_completion / mmc_wait_for_req_done / mmc_io_rw_extended
  / sdio_memcpy_toio / tx_thread [rk915]
task:rk915_rx  state:D
  __mmc_claim_host / sdio_claim_host / rk915_serias_read [rk915]
```

The rx thread is queued behind tx on the host lock, so nothing errors, recovery
never runs, and the module cannot be unloaded. Armed for writes as well; the
timeout comes from `TMOUT`, which is programmed per request from
`data->timeout_ns`.

### Driver

- **`rk915-0003-clear-sdio-reset-latch-on-power-cycle.patch`** — the root reason
  recovery never worked. `_sdio_reset()` latches a file-static flag on the first
  io error, after which every accessor returns success *without doing any i/o*.
  Per-block timing made it unambiguous: a failing download "wrote" 4096 bytes in
  **2 µs** (2 GB/s) against 269 µs for the same block on a working one.

  Two places clear the latch and neither runs during recovery. `sdio_probe()`
  only runs on a fresh probe — which is why a module reload was the one thing
  that ever helped. `rk915_sdio_recovery_init()` looks like exactly the right
  place, but its only caller `rk915_platform_bus_rec_init()` is called from
  nowhere; `nm` confirms both symbols are compiled and neither is referenced.

  That dead path is the regression. The BSP's `fw_bring_up()` called
  `rk915_platform_bus_rec_init()` on the recovery arm; the port replaced that
  with `rk915_sdio_power_cycle()`, which never inherited the clear. The patch
  gives the replacement the responsibility the replaced code carried.
- **`rk915-0004-reset-vif-accounting-on-hw-restart.patch`** — mac80211 re-adds
  interfaces after a restart but never calls `remove_interface()`, and the
  accounting was only cleared at module load, so the second restart hit
  `Exceeded Maximum supported VIF's cur:2 max: 2`.
- **`rk915-0002-atomic-fw-error-claim.patch`** — `rk915_signal_io_error()` used a
  plain test-then-set, so rx and tx both got through and
  `ieee80211_restart_hw()` was called twice, 163 µs apart.

### MAC address

The port falls back to `eth_random_addr()` when the DT carries no MAC, so the
interface came up with a new address and lease on every load. The BSP used
`rockchip_wifi_mac_addr()`, reading the factory MAC from Rockchip vendor storage
(tag `0x524B5644` at sector 7296, item id 3):

```
1e 28 78 xx xx xx   22 28 78 xx xx xx     wifi, then the derived P2P address
```

The vendor U-Boot already reads that and exports `ethaddr`/`eth1addr`, and its
`fdt_fixup_ethernet()` writes `ethaddr` into whatever `/aliases/ethernet0`
resolves to. Pointing that at the wifi node keeps the address **per device**
rather than baking one unit's MAC into a shared DTS.

### Console noise

`rocknix-joypad` logged an unratelimited `dev_err` per poll (~8/s forever) when
the SARADC stops answering — which it does as a side effect of the storm above.
Now `dev_err_ratelimited()`.

## What the remaining fault is not

Every one of these was tested on hardware and eliminated:

| Hypothesis | How it died |
|---|---|
| Bus clock gating on idle | `CLKENA = 0x00000001` — `LOW_PWR` clear, quirk working |
| Chip LMAC sleeping | `lpw_no_sleep=1`, wired to `rpu_sleep_type = LMAC_NO_SLEEP` — this is the fix for the *association* defect, and it holds; the traffic fault is separate |
| Direction (tx vs rx) | both kill it, at the same order of magnitude |
| Cumulative volume | 383 MB moved over 13 h 44 m with zero faults; 24 MB continuous at 15 KB/s also clean |
| `ALIGN(buf_len, 4)` length padding | present in the pristine BSP; all padded transfers return 0 |
| TX descriptor not atomic against RX | held the host lock across the whole descriptor — still died |
| Access during radio retune | added the RX path's guard to TX — still died |
| cpuidle / deep idle states | `cpuidle.off=1` changed nothing |
| Tickless idle | `nohz=off` changed nothing |
| A newer upstream fix | `stolen/rk915` main has nothing since 2025-07-08 |
| `debug_mask` timing (early theory) | did not replicate; that bisect was one run per arm |
| A `udelay()` in the chained-RX path | no effect at 200 µs or 2000 µs |
| Removing `cap-sdio-irq` | breaks wifi entirely — the core falls back to a polling SDIO irq thread whose CMD52s collide with the driver |

## What is known about the fault

With an in-driver ring recording the last transfers, the failure looks like this:

```
RKTRACE -348497us wr addr=0 len=1542 ret=0     writes every ~118us
RKTRACE -348380us wr addr=0 len=1542 ret=0     last activity
RKTRACE     -59us wr addr=0 len=1542 ret=-110  348ms later, ETIMEDOUT
```

The chip does not die *during* a transfer. It goes silent while the data path is
idle — no data reads or writes for ~348 ms — and the next write times out. The
host-wake GPIO stops at the same time, which is the driver's only RX wake source,
so nothing notices until a write fails.

Note the trace covers data transfers only; CMD52 register access is not recorded,
so "the driver did nothing" is not established — only that no data moved.

## Where a fix should start

**Both** of the upstream README's known issues are fixed here, and neither is the
remaining fault:

* *"Soon after association chip disconnects from network"* — that was the LMAC
  sleeping. Fixed by `rk915-0001-keep-lmac-awake.patch`. The link then held for
  13 h 44 m continuously.
* *"Unloading the driver will likely stall your system"* — fixed by arming the
  dw_mmc data timeout for writes.

The remaining throughput fault is a separate, previously undescribed defect.

**The strongest lead is that no host-side wake path exists — in either tree.**
Looking for the BSP's wake path to restore it, all four functions turn out to be
empty stubs:

```c
int  check_and_wakeup_rpu_nonblocking(void)     { return true; }
static void trigger_wakeup(enum RPU_SLEEP_TYPE) { return; }
```

`RPU_SLEEP_ENABLE` is defined via `EXTRA_CFLAGS`, so they compile and do nothing;
the `hal_ops` entries route to them, and the one site in `hal.c` that would wake
the chip before a transfer is inside `#if 0//def RPU_SLEEP_ENABLE` in the BSP as
well. So `lpw_no_sleep=1` is not a stopgap pending a proper wake path — there is
no wake path to restore, and writing one means reverse-engineering the firmware
interface, since the datasheet in their `docs/` is introduction, package and
electrical only, with no register map.

That matters here: if the firmware ever enters a low-power state that
`LMAC_NO_SLEEP` does not cover — buffer exhaustion under sustained transfer being
the obvious candidate — the host has no way at all to bring it back, and the
result would look exactly like the observed signature: chip stops mid-idle,
host-wake GPIO goes quiet, power cycle required.

Failing that, a flow-control or buffer-credit rule around `num_frames_per_desc`
is the next thing to check.

Our `&sdio` is brought to the same state as their
`docs/mainline-linux-dts-example.dtsi` (only the host-wake pin differs,
correctly, plus `/delete-property/` lines stripping the base DTS's SD-slot
properties and an `ethernet0` alias), and our quirks patch has a byte-identical
diff body to theirs, so nothing in their instructions is missing.

**Filed upstream:** <https://github.com/sunshineinabox/rk915/pull/1> — the four
driver fixes, the dw_mmc patch for their `docs/`, and the full write-up as the PR
description. Local copy in `RK915-UPSTREAM-REPORT.md`.

## Method note

Four hypotheses about the interrupt storm were wrong before the register dump
settled it in one cycle: an all-ones `MINTSTS`, the SDIO in-band bit, abnormal
IDMAC bits, and masking on first occurrence. The measurements that actually moved
this forward were `/proc/interrupts` traced to the console once a second,
`sysrq-w` for blocked-task stacks, a register dump every 200000th interrupt, and
an in-driver transfer ring. Reading the code suggested plausible answers; only
measuring distinguished them.
