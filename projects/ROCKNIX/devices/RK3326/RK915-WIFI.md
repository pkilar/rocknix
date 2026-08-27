# RK915 WiFi on the Gusgu H7 — investigation and outcome

*Session of 2026-08-26 / 27. Device: Gusgu H7 (Rockchip RK3326), ROCKNIX port on
branch `gusgu-h7-port`, kernel 7.1.2, serial console `/dev/ttyUSB0` @ 1500000 8N1.*

## Summary

The RK915 firmware faults under load — bulk traffic trips it within seconds, and
the driver also loses the same race against boot-time system load. The driver
detects the fault and asks mac80211 to restart the hardware, but **recovery could
never complete**, so every fault killed the link until the module was reloaded by
hand.

The root cause was an `sdio_reset` latch: after the first io error, every SDIO
accessor returned success *without doing any i/o*, so the firmware re-download
that recovery depends on wrote into nothing. It was only ever cleared by
`sdio_probe()` — which is precisely why a module reload was the one thing that
worked. Fixed, along with two further bugs it was masking (vif accounting not
reset across a hardware restart, and a racy fw-error claim).

**The driver now recovers in place**: same interface, same DHCP lease, no module
reload. Measured against a reproducer that kills the link in ~10 s: 23 recoveries,
31 successful firmware downloads, 0 failures.

The underlying fault still occurs; it is simply no longer fatal. A boot-time
watchdog remains as a backstop but should now essentially never fire.

Earlier sections below record hypotheses that were tested on hardware and
**disproven** — a `udelay` in the chained-RX path, and a `debug_mask` bisect that
did not replicate. They are kept because they document what the fault is *not*.

## Root cause: the sdio_reset latch

**Fixed.** `patches/rk915-0003-clear-sdio-reset-latch-on-power-cycle.patch`.

`_sdio_reset()` latches a file-static flag on the first io error:

```c
static bool sdio_reset;
int _sdio_reset(struct host_io_info *host) { sdio_reset = true; return 0; }
```

and every sdio accessor then short-circuits, **returning success without doing
any i/o**:

```c
static int sdio_send_data(struct host_io_info *host, u32 addr, u8 *buf, u32 len)
{
        if (sdio_reset == true)
                return 0;
        return sdio_memcpy_toio(func, addr, buf, len);
}
```

`rk915_io_reset()` calls it from six sites in `hal_io.c`, so *any* io error arms
it, and nothing cleared it except `sdio_probe()` — a module (re)load.

So firmware error recovery could never work. Recovery power-cycles the chip and
re-downloads the firmware, but every write is a silent no-op reporting success.
Per-block timing makes it unambiguous:

| | block 0 | block 1 | total |
|---|---|---|---|
| failing download | `ret=0` in **2 µs** | `ret=0` in **5 µs** | 1649 µs |
| working download | `ret=0` in 269 µs | `ret=0` in 247 µs | 4611 µs |

4096 bytes in 2 µs is 2 GB/s — the bus cannot do that. Nothing was transferred,
so the readback was all zeroes (`30550/48056 bytes differ, first at 0x0`), the
chip never reached `WAIT_PATCH`, and mac80211 shut every interface down.

This also explains the one thing that always worked: reloading the module runs
`sdio_probe()`, which clears the latch.

The fix drops the latch in `rk915_sdio_power_cycle()`, once the card has been
reset, re-enabled and had its block size restored — the point at which i/o is
valid again.

### Two further bugs found on the way

- **`patches/rk915-0004-reset-vif-accounting-on-hw-restart.patch`** — once
  recovery started working, the *second* restart hit
  `add_interface: Exceeded Maximum supported VIF's cur:2 max: 2`. mac80211
  re-adds interfaces after a restart but never calls `remove_interface()` for the
  old ones, and the accounting was only cleared by `rpu_init()` at module load.
  Cleared in `start()` instead.
- **`patches/rk915-0002-atomic-fw-error-claim.patch`** — `rk915_signal_io_error()`
  claimed recovery with a plain test-then-set, so the rx and tx threads both got
  through and `ieee80211_restart_hw()` was called twice, 163 µs apart. Now
  `cmpxchg()`.

### Result

Measured on hardware with a reproducer that kills the link in ~10 s under inbound
TCP (~0.1–0.5 MB):

| Metric | Before | After |
|---|---|---|
| firmware downloads during recovery | always failed | **31 succeeded, 0 failed** |
| recoveries completed | 0 | **23** |
| `Exceeded Maximum VIF` | yes | **0** |
| link after a fault | dead until module reload | **returns by itself** |
| interface name / DHCP lease | changed on every reload | **unchanged** |

The driver now recovers in place: same `phy`, same interface, same lease, no
module reload. Under sustained load the fault re-triggers and the driver simply
recovers again, with the backoff visible in the log (1.7 s → 2.0 → 2.9 → 3.6 →
6.4 → 8.7 → 12.2 → 15.9 s).

### The TX-spin hard hang

**Fixed separately, in the kernel:**
`patches/linux/036-dw_mmc-dont-spin-on-a-dead-bus.patch`.

There is a second, harder failure: instead of the driver noticing the fault and
recovering, `rk915_tx` wedges *inside* the SDIO write and never returns, so
`rk915_signal_io_error()` is never called and the recovery above never runs.

```
CPU: 0 UID: 0 PID: 491 Comm: rk915_tx
pc : dw_mci_start_command+0x58/0x120
x19: 00000000ffffffff
  sdio_memcpy_toio -> sdio_send_data [rk915] -> rk915_data_write
  -> rpu_send_cmd_datas -> tx_thread [rk915]
```

`dw_mci_wait_while_busy()` polls `SDMMC_STATUS` with
`readl_poll_timeout_atomic()` for up to 500 ms before every data command — no
sleeping, `host->lock` held, interrupts disabled. When the chip falls off the bus
the register reads all-ones (`x19`), so `SDMMC_STATUS_BUSY` is permanently set and
every command burns the full 500 ms. The CPU stops servicing interrupts entirely:
the display stalls waiting for vblank, the network dies, the joypad poll stops,
and printk itself stops coming out. Only a power cycle recovers it.

An all-ones read is not a valid status — it means the host is not answering.
Break out of the poll and let the command time out normally so the error reaches
the driver and the recovery path can do its job.

Note this is why bulk transfers over WiFi are impractical *before* the fix: a
24 MB scp to the device managed ~1.7 KB/s, because the link faulted and recovered
roughly every 0.3 MB.

### What is still not fixed

The *underlying* fault still occurs — bulk traffic still trips
`rk915_serias_read: length(61680) too long` or a tx write returning `-16`. What
changed is that it is no longer fatal: recovery works, so it costs a brief blip
instead of the link. Finding why the chip faults under load in the first place is
a separate question, and the 0xF0F0 chained-header analysis below is where it
starts.

`system.d/rk915-recover.sh` is kept as a backstop but should now essentially
never fire, since it triggers on
`fw_bring_up: rk915_download_firmware failed`, which no longer happens.

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
