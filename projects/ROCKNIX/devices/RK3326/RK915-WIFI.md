# RK915 WiFi on the Gusgu H7

Investigation record for the RK915 SDIO WiFi chip on the Gusgu H7 (RK3326),
running the ROCKNIX port on branch `gusgu-h7-port`, kernel 7.1.2.

## State of play

WiFi associates, gets a lease, and holds a stable MAC. Under **concurrent**
traffic the chip still faults — but a fault is now a brief self-healing blip
instead of a hard hang.

| | Before | Now |
|---|---|---|
| Fault under load | whole machine hangs, power cycle required | link drops, recovers itself |
| SDIO interrupt storm | ~684,000/s, starves every interrupt on CPU0 | none |
| Driver after a fault | tx/rx threads stuck in `D`, module unloadable | errors out, recovery runs |
| Firmware recovery | never completed | 31 downloads, 0 failures |
| MAC / DHCP lease | new random MAC every module load | stable, from vendor storage |

**Not fixed:** the chip stops responding after roughly 10–80 requests of
concurrent traffic. Everything below documents what that is, what it is not, and
how to reproduce it.

## Reproducer

Sequential requests never trigger it. **Concurrency is the trigger** — a browser
does this naturally, which is why clicking a directory in the built-in web server
reproduces it instantly:

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
meaningful for PIO. `dw_mci_submit_data()` enables them on the PIO path and the
DMA path does not — but the initial `INTMASK` enables them unconditionally and
nothing turns them off, so they also fire throughout every DMA transfer where
`host->sg` is NULL and the handler can only clear the latch. Harmless while DMA
drains the FIFO; lethal when the card dies, because the condition then persists
and the level-triggered line storms:

```
IRQTRACE 344 dwmci: 56:164736147  vop=11531 adc=24734 ser=418 gpio=10946
IRQTRACE 345 dwmci: 56:165433415  vop=11531 adc=24734 ser=418 gpio=10946
```

~684,000 interrupts/second on `mmc@ff380000`, with every other interrupt frozen.
All device interrupts on this board are affine to CPU0, so the VOP stops (drm
vblank timeouts), the SARADC stops (joypad error spam) and the network dies.
Fixed by masking them for the duration of a DMA transfer.

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

Also included: `dw_mci_wait_while_busy()` would burn its full 500 ms atomic poll
on an all-ones `SDMMC_STATUS`, and `dw_mci_interrupt()` would service all 32 bits
of an all-ones `MINTSTS`. Neither value is data.

### Driver

- **`rk915-0003-clear-sdio-reset-latch-on-power-cycle.patch`** — the root reason
  recovery never worked. `_sdio_reset()` latches a file-static flag on the first
  io error, after which every accessor returns success *without doing any i/o*.
  Only `sdio_probe()` cleared it, which is why a module reload was the one thing
  that ever helped. Per-block timing made it unambiguous: a failing download
  "wrote" 4096 bytes in **2 µs** (2 GB/s) against 269 µs for the same block on a
  working one. Cleared in `rk915_sdio_power_cycle()`.
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
1e 28 78 e8 94 15   22 28 78 e8 94 15     wifi, then the derived P2P address
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
| Chip LMAC sleeping | `lpw_no_sleep=1`, wired to `rpu_sleep_type = LMAC_NO_SLEEP` |
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

This is a firmware/protocol-level fault in a WIP mainline port of a vendor
driver, and chasing it further needs the chip documentation the porter has and
this investigation does not. The evidence worth handing upstream is in
`RK915-UPSTREAM-REPORT.md`.

## Method note

Four hypotheses about the interrupt storm were wrong before the register dump
settled it in one cycle: an all-ones `MINTSTS`, the SDIO in-band bit, abnormal
IDMAC bits, and masking on first occurrence. The measurements that actually moved
this forward were `/proc/interrupts` traced to the console once a second,
`sysrq-w` for blocked-task stacks, a register dump every 200000th interrupt, and
an in-driver transfer ring. Reading the code suggested plausible answers; only
measuring distinguished them.
