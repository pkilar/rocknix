# RK915 WiFi on the Gusgu H7 — investigation and outcome

*Session of 2026-08-26 / 27. Device: Gusgu H7 (Rockchip RK3326), ROCKNIX port on
branch `gusgu-h7-port`, kernel 7.1.2, serial console `/dev/ttyUSB0` @ 1500000 8N1.*

## Summary

The WiFi driver comes up, associates and gets a DHCP lease, then the link dies a
few seconds later. The trigger is a race that the driver loses **while the system
is still booting** — roughly two boots in three. Once the system has settled,
the driver is stable: reloading it after boot produced 300/300 and 396/400 pings
with zero faults.

The shipped fix is therefore a recovery unit, not a driver patch: if there is no
default route 30 s after boot, reload `rk915` and restart `iwd`. Validated over
three consecutive boots — all three ended with working networking, two of them
after the unit logged `recovered`.

A driver-level patch was written, built and tested, and is documented below as a
**disproven hypothesis**. It is not shipped.

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

## Reproducing the fault

Fastest reproducer is simply a cold boot with the recovery unit masked:

```
systemctl mask rk915-recover.service && reboot
# then, from the serial debug shell:
dmesg | grep -E 'too long|fw error recovery'
ip route | grep default || echo "link is down"
```
