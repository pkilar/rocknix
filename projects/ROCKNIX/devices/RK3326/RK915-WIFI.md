# RK915 WiFi on the Gusgu H7 — investigation and outcome

*Session of 2026-08-26 / 27. Device: Gusgu H7 (Rockchip RK3326), ROCKNIX port on
branch `gusgu-h7-port`, kernel 7.1.2, serial console `/dev/ttyUSB0` @ 1500000 8N1.*

## Summary

The WiFi driver comes up, associates and gets a DHCP lease, then the link dies a
few seconds later. The trigger is a race that the driver loses **while the system
is still booting** — roughly two boots in three. Once the system has settled,
the driver is stable: reloading it after boot produced 300/300 and 396/400 pings
with zero faults.

The shipped fix is therefore a recovery unit, not a driver patch: 30 s after boot,
**if the driver logged a fault**, reload `rk915` and restart `iwd`. Validated over
three consecutive boots — all three ended with working networking, two of them
after the unit logged `recovered`, and a later boot confirmed it correctly does
nothing when the driver came up clean.

A driver-level patch was written, built and tested, and is documented below as a
**disproven hypothesis**. It is not shipped.

⚠️ **There is a serious remaining limitation: a sustained transmit workload
hard-freezes the device and needs a power cycle.** See the next section before
relying on WiFi for anything more than light traffic.

## Known limitation: sustained TX freezes the device

**Do not use WiFi for large uploads on this device.** A sustained transmit
workload — uploading a file through the built-in web server is the reproducer —
locks the handheld up hard. It cannot be recovered from software; it needs a
power cycle.

### Symptom

```
rockchip-vop ff460000.vop: [drm:vop_crtc_atomic_flush] *ERROR* VOP vblank IRQ stuck for 10 ms
[CRTC:39:crtc-0] vblank wait timed out
WARNING: drivers/gpu/drm/drm_atomic_helper.c:1921 at drm_atomic_helper_wait_for_vblanks...
rcu: INFO: rcu_sched self-detected stall on CPU
rcu:     0-....: (6303 ticks this GP) ...
CPU: 0 UID: 0 PID: 502 Comm: rk915_tx
```

The display warning is the loudest part of the log and it is **a symptom, not the
cause**. The stalled task is `rk915_tx`, and the display is simply being starved.

### Mechanism

The stalled thread sits here, unchanged across two RCU reports 63 s apart:

```
dw_mci_start_command+0x58/0x120
dw_mci_start_request / dw_mci_request / __mmc_start_request
mmc_wait_for_req / mmc_io_rw_extended / sdio_io_rw_ext_helper
sdio_memcpy_toio
sdio_send_data [rk915] / rk915_data_write [rk915]
rpu_send_cmd_datas [rk915] / tx_thread [rk915]
```

Two facts explain the freeze:

1. **The chip has fallen off the SDIO bus.** The register dump carries
   `x19: 00000000ffffffff` — the dw_mmc status register reading all-ones, which
   is what a dead or unclocked bus returns. `SDMMC_STATUS_BUSY` can therefore
   never clear.

2. **The busy-wait is atomic.** `dw_mci_wait_while_busy()` polls for up to
   **500 ms without sleeping**, on every data command:

   ```c
   if ((cmd_flags & SDMMC_CMD_PRV_DAT_WAIT) && !(cmd_flags & SDMMC_CMD_VOLT_SWITCH)) {
           if (readl_poll_timeout_atomic(host->regs + SDMMC_STATUS, status,
                                         !(status & SDMMC_STATUS_BUSY),
                                         10, 500 * USEC_PER_MSEC))
                   dev_err(host->dev, "Busy; trying anyway\n");
   }
   ```

So once the chip dies, `rk915_tx` burns half a second of un-preemptible CPU per
command and keeps submitting them. A CPU is pinned indefinitely — the stall
counter went from 6303 to 25202 ticks (~250 s) across two reports. RCU stalls,
the VOP's vblank IRQ misses its deadline, and DRM's commit worker times out
waiting for it. **Nothing anywhere in the path ever concludes "the card is gone,
stop trying".**

### The failure chain

Traced with the driver's own logging (safe once `console_loglevel` is 1, which
keeps printk in the ring buffer and off the 1.5 Mbaud console):

```
rk915: rk915_serias_read: length(61680) too long error.   ← the 0xF0F0 header bug
rk915: fw error (0): requesting mac80211 restart          ← driver DOES detect it
ieee80211 phy4: Hardware restart was requested
mmc_host mmc2: Bus speed = 400000Hz  →  50000000Hz        ← card really is power-cycled
rk915: rk915_download: start download firmware size: 48056
rk915: rk915_download: check downloaded fw failed         ← 0.6 ms later
rk915: fw_bring_up: rk915_download_firmware failed
WARNING: net/mac80211/util.c:1956 at ieee80211_reconfig    → every interface shut down
```

So the driver detects the fault and tries to recover; the **firmware re-download
is what fails**, and mac80211 then gives up. The entry point varies — sometimes
the 0xF0F0 RX header, sometimes a TX write returning `-16` — but the recovery
failure is always identical.

Two details pin it down:

- `30550/48056 bytes differ` is the **same count every time**: that is simply how
  many non-zero bytes the image has, i.e. *every* byte reads back as 0.
- Download to verify-failed takes **0.6 ms**. 48 KB over SDIO at 50 MHz cannot
  take less than ~8 ms, so the transfers are not reaching the bus at all.

The card *is* genuinely power-cycled first (the 400 kHz → 50 MHz re-negotiation
is in the log), so this is not a missing reset.

### Two variants

| Variant | Symptom | Recovers? |
|---|---|---|
| link death (common) | interface stops passing traffic, mac80211 shuts it down | **yes** — reloading the module restores it every time |
| tx spin (seen once) | `rk915_tx` pins a CPU in the SDIO busy-wait; RCU stalls; display starves | **no** — `modprobe -r` hangs on the spinning thread; power cycle only |

### What was tried and eliminated

All on hardware, against the reproducer below:

| Change | Result |
|---|---|
| redo the fresh-probe chip/state setup in the recovery path | download still fails identically |
| drop the stale `clk_claimed` so the SDIO irq is re-claimed after `mmc_hw_reset` | no change (it is already false by then) |
| longer power-off — ruled out by reasoning: a module reload uses the *same* `rk915_sdio_power_cycle()` and succeeds | not attempted |

### What was fixed

`patches/rk915-0002-atomic-fw-error-claim.patch`. `rk915_signal_io_error()`
guarded recovery with a plain test-then-set, and the rx and tx threads both got
through it — two recoveries 163 µs apart, `ieee80211_restart_hw()` called twice
with the second landing mid-restart. Now claimed with `cmpxchg()`; verified on
hardware, the same reproducer logs a single recovery. It does **not** make
recovery succeed on its own.

### The mitigation that works

`system.d/rk915-recover.sh`, shipped and enabled by the package as a watchdog
service. It polls the ring buffer for `fw_bring_up: rk915_download_firmware
failed` and reloads the module, which restores the link reliably. It also does
the same check 30 s after boot, since the driver can lose the same race while the
system is starting.

Validated end to end: two induced failures, two automatic recoveries, back on the
network in well under two minutes each time.

Caveats worth knowing:

- Each reload renames the interface (`wlan5` → `wlan6` → …) and takes a new DHCP
  lease, because udev keeps allocating fresh names.
- It cannot help the tx-spin variant, where `modprobe -r` hangs.
- It is a mitigation. The fault still happens; the link still drops for ~30-60 s.

### Where a real fix should start

The download writes are not reaching the bus — 0.6 ms and all-zero readback. The
next step is to instrument `rk915_download()` itself and find whether `io_send`
is returning an error that the download path swallows, or whether it is being
short-circuited before the SDIO layer. Everything upstream of that (the reset,
the bus re-init, the recovery bookkeeping) has been checked and is working.

### Reproducing

About 0.1-0.5 MB of inbound TCP kills it in ~10 seconds:

```sh
# on the device
nc -l -p 9999 > /dev/null
# from another machine
python3 -c "import socket;s=socket.create_connection(('<device-ip>',9999));\
[s.sendall(b'\0'*65536) for _ in range(4000)]"
```

## The fault

```
rk915: rk915_serias_read: length(61680) too long error.
rk915: -------- fw error recovery (0) start --------
rk915: rx_thread: error datalen: 0.
```

Firmware recovery then fails, because by that point the chip is incoherent:

```
rk915: 30550/48056 bytes differ, first at 0x0 (wrote 0x81 read 0x00)
rk915: rk915_download: check downloaded fw failed
rk915: fw_bring_up: rk915_download_firmware failed
```

mac80211 tears the device down and the interface is left with no route. Management
frames always worked — association and DHCP usually succeeded; the failure needed
data traffic.

61680 is **0xF0F0**. In `rk915_serias_read()` (`src/hal_io.c`) the length of the
next packet in a chained RX burst is taken straight from the burst buffer:

```c
host->rx_serias_buf_curr += host->rx_serias_len[host->rx_serias_idx];
++host->rx_serias_idx;
mac_hdr = (struct host_rpu_msg_hdr *)host->rx_serias_buf_curr;
host->rx_next_len = mac_hdr->length >> 16;      /* 0xF0F0____ >> 16 == 61680 */
mac_hdr->length = mac_hdr->length & 0x0000FFFF;
length = mac_hdr->length + mac_hdr->payload_length;
```

so a header that reads back as `0xF0F0____` yields exactly the observed value, and
the bounds check a few lines later rejects it and takes the chip down.

Failure timing was load-dependent, not a fixed timer: 4.15 s, 13.17 s and 29.4 s
across runs, settling at a very repeatable ~29.4 s once the test conditions were
stable.

## What was ruled out

Each of these was applied to hardware and observed, not reasoned about:

| Hypothesis | Test | Result |
|---|---|---|
| LMAC sleeping mid-RX | `lpw_no_sleep=1` (patch 0001, verified applied via `modinfo`) | no effect |
| Firmware feature bits | `rk915.patch_features=12`, verified via `/sys/module` and `/proc/cmdline` | no effect |
| Missing settle before the chained header read | `rx_settle_us=200`, then `2000` (patch, built and loaded) | no effect — faulted at 29.39 s and 29.41 s |

## The debug_mask lead, and why it did not survive

The driver is a mainline port of a vendor BSP. Where the BSP logged
unconditionally (`RPU_INFO_SDIO(...)`), the port gates the same calls on
`debug_mask`, which defaults to 0. Booting with `rk915.debug_mask` set made the
fault disappear, which suggested the port had silently removed delays the shipped
code always carried.

A bisect over the mask pointed at a single call site — `RK915_DBG_HALIO` is
`BIT(18)` = `0x40000`, and it has **exactly one** occurrence in the whole driver,
at `src/hal_io.c:228`, immediately after the reads above:

- `0x150000` (HALIO|SDIO|RECOVERY) → 600/600 pings, 0% loss
- `0x40000` (HALIO alone) → 600/600 pings, 0% loss
- `0x10000` (SDIO alone) → failed

That looked conclusive. **It did not replicate.** Re-tested this session, both
`0x40000` and `0x150000` faulted, and with `0x150000` only 1 of 3 boots came up
with a route. The original bisect was one run per arm against an intermittent
fault, which is not enough evidence to support the conclusion it was given.

The delay patch was built on that lead: an explicit, runtime-tunable `udelay()`
in place of the incidental printk delay. It failed at both 200 µs and 2000 µs,
which also rules out "the printk is just burning time" as the mechanism.

A positive control — the same module with `debug_mask=0x40000` — *also* faulted,
which showed the test harness itself was confounded: loading the driver late from
a systemd unit (with `modprobe.blacklist=rk915` on the cmdline) changes boot
concurrency enough to fire the fault regardless of logging. Nothing loaded that
way can validate or invalidate a driver change, so that avenue was abandoned.

## What actually holds

The driver is stable once the system is idle. On a boot that had failed:

```
modprobe -r rk915 && modprobe rk915 && systemctl restart iwd
```

restored a working link, and it stayed up:

| Test | Result |
|---|---|
| post-reload soak, `debug_mask=0` | 300/300 pings, 0% loss, `rx_errors=0`, 0 faults |
| same with the delay patch disabled (`rx_settle_us=0`) | 300/300 pings, 0 faults |
| post-reload soak, stock module | 396/400 pings (1% loss), 0 faults, 2.5 MB RX, route intact |
| soak on a boot the recovery unit fixed by itself | **400/400 pings, 0% loss**, 0 faults, 3.19 MB RX, route intact |

Note the second row: with the system idle the fault does not reproduce *either
way*, which is why the driver patch could not be validated — and why the same
result should not be read as the patch working.

## The shipped fix

`projects/ROCKNIX/packages/linux-drivers/rk915/system.d/rk915-recover.service`,
installed and enabled by the rk915 package:

It waits 30 s, then reloads `rk915` and restarts `iwd` **only if the driver
logged a fault**:

```sh
FAULTS='rk915: .*(too long error|fw error recovery|No reset complete|check downloaded fw failed|rk915_download_firmware failed)'
dmesg | grep -qE "$FAULTS" || exit 0        # healthy - leave it alone
modprobe -r rk915; sleep 3; modprobe rk915; sleep 10; systemctl restart iwd
```

The trigger is the kernel log, **not** connectivity. An earlier version keyed on
"no default route", which is wrong: with WiFi unconfigured, out of range, or
simply unused there is no route and no fault, so it reloaded the driver on every
boot — churning `iwd` while the user was trying to configure WiFi, and renaming
`wlan0` to `wlan1` where the UI can see it.

`rx_thread: error datalen: 0` is deliberately excluded from the trigger: it is
also seen once on a healthy interface bring-up, so it is not decisive alone.
`RPUWIFI-UMAC: No reset complete after 900 ticks` **is** included — it is the
same race failing earlier, during chip reset.

Validation, three consecutive boots:

| Boot | default route | unit log |
|---|---|---|
| 1 | yes | (no action needed) |
| 2 | yes | `recovered` |
| 3 | yes | `recovered` |

### Do not put `debug_mask` on the cmdline

`rk915.patch_features=12 rk915.debug_mask=0x150000` were initially left on the
cmdline because that was the combination the 3/3 validation ran against. That was
a mistake, and it bit on the first boot where WiFi carried real traffic.

The HALIO site logs **once per packet** in every chained RX burst. At 1.5 Mbaud a
~40-character line is ~267 µs of blocking console write, so a busy link saturates
the console: vblank handling misses its deadline
(`[CRTC:39:crtc-0] vblank wait timed out` in `drm_atomic_helper_wait_for_vblanks`),
RCU stalls, `systemd-journal` spins eating the flood, load average hits 6.7 and
the device freezes. Every soak before that point was pings at 1/s, a rate that
never exercises the logging path — the parameter was validated under a traffic
profile that could not reveal its cost.

Both parameters are now removed. Re-measured without them, at 10× the packet rate:

| Metric | Result |
|---|---|
| ping | 1991/2000, 0.45% loss, 3.24 MB RX |
| vblank timeouts / RCU stalls | 0 / 0 |
| driver faults | 0 |
| `rk915:` lines in dmesg | 3 (version + firmware) |
| load average | 0.71 |

WiFi associates and holds a lease with `debug_mask` unset, which is further
evidence the parameter never did anything for the RX race.

## Honest status

- WiFi is **usable**: it comes up on every boot, recovering itself when needed.
- The underlying race in `rk915_serias_read()` is **not fixed**. The corrupt
  `0xF0F0` header read is understood as a symptom; the mechanism that lets a
  stale header be observed is not.
- The one-line delay hypothesis is disproven. Something other than elapsed time
  distinguishes the printk from a busy-wait — a lock, a barrier, preemption, or
  the interrupt window it opens. That is where a future attempt should start.
- The failure rate without the recovery unit was measured at 2 of 3 boots on this
  unit, on this AP, on one night. Treat it as an order of magnitude, not a constant.
- **Sustained TX hard-freezes the device** and needs a power cycle. This is the
  most serious open problem in the port; see the limitation section above. The
  recovery unit does not help — it runs once, at boot.

## Reproducing the fault

Fastest reproducer is simply a cold boot with the recovery unit masked:

```
systemctl mask rk915-recover.service && reboot
# then, from the serial debug shell:
dmesg | grep -E 'too long|fw error recovery'
ip route | grep default || echo "link is down"
```
