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

### Why nothing recovers it

| Attempt | Result |
|---|---|
| `rk915-recover.service` | runs once, 30 s after boot; this happens much later |
| `ip link set wlan0 down` | deauthenticates, does not stop the TX thread |
| `modprobe -r rk915` | **hangs** — the refcount cannot drop while `tx_thread` spins |
| power cycle | the only way out |

### What is and is not affected

Measured stable: association, DHCP, browsing, and RX-dominated traffic — a
10 pps / 1400-byte soak moved 3.24 MB with 1991/2000 pings, 0 driver faults,
0 vblank timeouts, load average 0.71.

Triggering: sustained **transmit**. Every soak run during the investigation was
RX-dominated, which is why this was not caught earlier.

This is **not** a panel or DTS bug. The display recovers completely on power
cycle and normal boots show zero vblank timeouts.

### Candidate fixes — none tried

1. **Fail fast on a dead bus.** Treat an all-ones read in the rk915 SDIO path as
   fatal: fail the transfer and let the driver's existing firmware-recovery run
   instead of queueing more doomed commands. This would convert a freeze into a
   link drop, which is recoverable. Most promising.
2. **Re-evaluate `035-rk915-mmc-quirks.patch`.** It widens where
   `SDMMC_CMD_PRV_DAT_WAIT` is set, and that flag is what arms the atomic spin.
   It comes from a WIP upstream PR. Whether it contributes here is untested.
3. `dw_mci_wait_while_busy()` has no notion of a removed or dead card. Any real
   fix probably belongs there, but that is a core MMC change.

Both (1) and (2) need a rebuild and reflash to evaluate, and two earlier
driver-level hypotheses in this investigation were disproven on hardware — treat
these as leads, not solutions.

### Reproducing

Upload a large file through the web server with the serial console attached.
The freeze follows within seconds of sustained TX.

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
