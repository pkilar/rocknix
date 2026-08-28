# Gusgu H7 — ROCKNIX port

Adds an `h7` subdevice to the RK3326 target for the **Gusgu H7**, an unbranded
Rockchip RK3326 handheld that ships a vendor EmuELEC 4.7 build. Everything here was
derived from the device's own stock DTB and verified on hardware — nothing guessed.

**Status:** boots to EmulationStation; display, audio, all 17 buttons, volume keys
and the analog stick verified on hardware. **WiFi works** — but only via a timing
workaround, not a real fix; see §8.

---

## 1. Hardware

| | |
|---|---|
| SoC | Rockchip RK3326 (`chip_id 524b3326`), 1 GiB LPDDR3 |
| Stock DT | `rk3326-evb-lp3-v12-linux.dtb` — a *generic Rockchip EVB* tree |
| Panel | Sitronix **ST7703** MIPI DSI, **1024×768 @ 60.8 Hz**, 4 lanes, RGB888 |
| Debug UART | **UART5** @ `0xff178000`, 1500000 8N1 |
| Buttons | 19 GPIO lines (17 on gpio3, 2 on gpio2) |
| Stick | one (left): **X on SARADC ch1, Y on ch2**, direct, no analog mux (ch0/ch3 unconnected) |
| Stock bootloader | **U-Boot 2017.09** vendor fork on eMMC |

A copy of the stock DTB lives in `packages/u-boot/config/stock/` for the
`generic-dsi` on-device wizard.

---

## 2. What this adds

| File | Purpose |
|---|---|
| `linux/dts/rockchip/rk3326-gusgu-h7.dts` | the device tree — includes the eeclone base and overrides it |
| `packages/u-boot/config/extlinux/extlinux.conf.sub-h7` | H7-only extlinux.conf (see §4) |
| `packages/u-boot/config/h7_boot.ini` | pins the DTB; no ADC autodetect |
| `packages/u-boot/config/stock/…dtb` | stock DTB for the on-device wizard |
| `projects/ROCKNIX/config.xml` → `<h7>` | registers the subdevice |
| `projects/ROCKNIX/bootloader/mkimage` | per-subdevice extlinux hook (2 lines + comment) |
| `patches/linux/035-rk915-mmc-quirks.patch` | MMC card quirks for the RK915 WiFi chip (§8) |
| `projects/ROCKNIX/packages/linux-drivers/rk915/` | RK915 driver + firmware package |
| `devices/RK3326/options` | `ADDITIONAL_DRIVERS += rk915` |

Nothing shared is overwritten — the `-a` and `-b` images build exactly as they do
upstream. `mkimage_extlinux()` now prefers `extlinux/extlinux.conf.sub-${SUBDEVICE}`
when present and otherwise falls back to the existing shared-conf and generated-conf
paths, so the H7's incompatible bootloader is accommodated without touching any other
device.

## 3. Why the eeclone base

`rk3326-gusgu-h7.dts` does `#include "rk3326-gameconsole-eeclone.dts"` and overrides
it. dtc accepts a `.dts` including another `.dts` (repeated `/dts-v1/;` is legal), so
the kernel compiles it natively — no `fdtoverlay`, no post-processing, and the build
container ships no `device-tree-compiler` anyway.

eeclone was chosen for two independent reasons:

1. It is the only RK3326 tree here defining every node the H7 must override —
   `internal_display` (a `rocknix,generic-dsi` panel), `joypad`, `adc_keys`,
   `btn_pins`.
2. It aliases `serial2 = &uart5` with `uart2` disabled, so Linux enumerates the H7's
   UART5 as `ttyS2` — meaning the stock `console=ttyS2,1500000` lands on the real
   debug port with no cmdline change.

Its *own* panel is a 720×720 HX8394 (24 init commands); the H7's is 1024×768 ST7703
(160). `&internal_display` replaces the description wholesale.

---

## 4. The stock bootloader constrains everything

**ROCKNIX's RK3326 images contain no bootloader** — LBA 64, 8192 and 16384 are all
zero. They are designed to be chainloaded by a modern U-Boot already on the device.
The H7 has **U-Boot 2017.09**, which cannot do the job:

| Symptom | Cause |
|---|---|
| `Ignoring unknown command: FDTOVERLAYS` | overlay support landed ~2019 — **DT overlays can never be applied** |
| `Unable to read file /rockchip-evb_px30.dtb` | `FDTDIR /` plus the vendor's own default `${fdtfile}` |
| `Unknown command '␦␦␦'` from `/boot.scr` | mkimage format its `source` cannot consume |

There is also a structural trap: the vendor environment runs `scan_dev_for_extlinux`
**before** `scan_dev_for_scripts`, so `boot.scr` — which would pin `fdtfile` — can
never run in time. **`h7_boot.ini` is effectively dead on this device**; it is kept
only for the case where a modern U-Boot is ever installed.

Hence the H7's `extlinux.conf` must be self-contained, and shaped like the EmuELEC
file this U-Boot already parses. It ships as `extlinux.conf.sub-h7` and is selected
by the per-subdevice hook in §2, leaving the shared conf untouched — `LABEL`/`LINUX`/`FDT`/`APPEND`, no comments, no `FDTDIR`, no
`FDTOVERLAYS`, and no `${vars}` (nothing expands them):

```
LABEL ROCKNIX
  LINUX /KERNEL
  FDT /rk3326-gusgu-h7.dtb
  APPEND boot=LABEL=ROCKNIX disk=LABEL=STORAGE console=tty0 console=ttyS2,1500000 systemd.debug_shell=ttyS2
```

`boot=`/`disk=` use `LABEL=` because `boot.scr` never sets `${partition_boot}`.
Labels verified from the image: FAT `ROCKNIX`, ext4 `STORAGE`.

### `console=` ordering — the trap that cost two boots

**The last `console=` wins for `/dev/console`.** Upstream ships
`console=ttyS2,1500000 console=tty0`, which puts *userspace* — systemd, ES, every
error — on the handheld's screen, leaving the serial line silent after the kernel's
own messages. `tty0` must come **first** and `ttyS2` last for serial debugging.

The stock EmuELEC cmdline has the same shape (`console=ttyFIQ0 console=tty0`), which
is why a `debugging` shell there also appears on the screen and not on serial.

---

## 5. `adc-keys` sends the device into recovery on every boot

ROCKNIX's initramfs:

```bash
KEY_VOLUMEDOWN=114
recovery_mode() {
  if [ "${FORCE_RECOVERY}" != "yes" ] && ! is_key_pressed $KEY_VOLUMEDOWN; then
    return
```

eeclone's `adc-keys` samples **SARADC channel 2** with `keyup-threshold = 1.8 V`,
`vol-down` at 0.3 V, `vol-up` at 0.015 V. On the H7 that channel is **the stick's Y axis** (measured: 536 raw =
536/1024 x 1.8 V = 0.94 V at rest) — below the "no key"
threshold, and far closer to vol-down than vol-up. Result: `KEY_VOLUMEDOWN` reads as
permanently held, init drops into USB-MSC export mode, and `Press VOLUMEUP to
reboot` can never be satisfied because vol-up would need ~0.015 V.

`&adc_keys { status = "disabled"; }` fixes it. The H7's real volume buttons are
GPIOs and are handled by the `volume-keys` `gpio-keys` node instead — which also
keeps `KEY_VOLUMEDOWN` on a real button, so holding Volume Down at power-on now
*deliberately* enters recovery, as intended.

---

## 6. Button map — verified against physical presses

Recorded with `evtest` while pressing each control in a known order, with every `sw`
temporarily assigned a unique `BTN_TRIGGER_HAPPY<N>` so the log named the exact line.

| Button | sw | GPIO | code |
|---|---|---|---|
| D-pad Up / Down / Left / Right | sw11 / sw12 / sw9 / sw10 | gpio3 PC6 / PC7 / PC4 / PC5 | `BTN_DPAD_*` |
| A / B / X / Y | sw5 / sw6 / sw7 / sw8 | gpio3 PC0 / PC1 / PC2 / PC3 | `BTN_EAST` / `BTN_SOUTH` / `BTN_NORTH` / `BTN_WEST` |
| L1 / R1 | sw3 / sw1 | gpio3 PB5 / PB3 | `BTN_TL` / `BTN_TR` |
| L2 / R2 | sw4 / sw2 | gpio3 PA6 / PA0 | `BTN_TL2` / `BTN_TR2` |
| Select / Start / Function | sw13 / sw14 / sw15 | gpio3 PD0 / PD1 / PD2 | `BTN_SELECT` / `BTN_START` / `BTN_MODE` |
| Left stick click | sw17 | gpio2 PB5 | `BTN_THUMBL` |
| (right stick click — absent) | sw18 | gpio2 PB6 | `BTN_THUMBR` |
| Volume Up / Down | — | gpio3 PB0 / PB1 | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN` |

Note ROCKNIX uses the **Nintendo-style** convention: A = `BTN_EAST` (0x131),
B = `BTN_SOUTH` (0x130).

Two independent cross-checks: the user pressed the left stick twice and both landed
on `sw17`; and the pins form contiguous runs (PC0–PC7 = A,B,X,Y,LEFT,RIGHT,UP,DOWN;
PD0–PD2 = SELECT,START,FN), which no mis-sequencing would produce.

`btn_pins` is overridden with pull-ups for all 19 H7 lines — five were not in
eeclone's list and would otherwise have floated.

---

## 7. The analog stick

**Solved — no driver work needed.** The H7 has *one* stick on two direct SARADC
channels, which is exactly the Odroid Go Advance v11 topology, and
`rocknix-joypad` already handles it.

Measured with the stick at rest and through full travel
(`/sys/bus/iio/devices/iio:device0/in_voltage*_raw`):

| channel | min | max | span | verdict |
|---|---|---|---|---|
| ch0 | 512 | 513 | 1 | unconnected |
| **ch1** | 91 | 873 | 782 | **X** — left 92, centre 460, right 873 |
| **ch2** | 155 | 922 | 767 | **Y** — up 155, centre 536, down 921 |
| ch3 | 444 | 455 | 11 | unconnected (noise) |

The stock DT names its channels `button0..3 = left-x, left-y, right-x, right-y`.
That is EVB boilerplate and **does not match the wiring** — trust the measurement.

Two driver facts settled from `004-input-drivers.patch`:

- `rocknix-singleadc-joypad` calls `devm_iio_channel_get(dev, "amux_adc")` — a single
  muxed channel only. It **cannot** read two direct channels, whatever `amux-count` says.
- `rocknix-joypad` calls `devm_iio_channel_get(dev, "joy_x")` / `"joy_y"`. Both drivers
  emit the same button set, and each reads `linux,code` per child node regardless of the
  node's name — so the `sw<N>` nodes carry over unchanged when switching `compatible`.

### `abs-left-first` is required

`rocknix-joypad` assigns axes **positionally**, and defaults to right-stick-first:

```c
const char* mapping_r_l[] = {"rx", "ry", "x", "y", "rz", "z"};   /* default */
const char* mapping_l_r[] = {"x", "y", "rx", "ry", "z", "rz"};
if (device_property_read_bool(dev, "abs-left-first")) mapping = mapping_l_r;
```

With only two channels the single stick lands on indices 0,1 = `ABS_RX`/`ABS_RY`, and
the driver logs `axis rx` / `axis ry`. Games and EmulationStation expect the left stick
on `ABS_X`/`ABS_Y`, so **`abs-left-first;`** is required. With it the driver logs
`axis x` / `axis y`.

⚠️ **`invert-abs*` are presence checks.** Setting one to `<0>` still inverts — the
property must be **absent**. Note also that the driver builds the property name from
the axis it chose (`snprintf(buf, 16, "invert-abs%s", axis)`), so before
`abs-left-first` it was looking for `invert-absrx`/`invert-absry`.

The H7 needs no inversion. Verified on hardware: stick full **left** reports
`ABS_X = -900`, full **up** reports `ABS_Y = -900` — the standard convention.

### Driver location

`rocknix-joypad` is **not** in `004-input-drivers.patch` (which supplies
`odroidgo2-joypad` and friends). It is a separate out-of-tree package:
`projects/ROCKNIX/packages/linux-drivers/rocknix-joypad/`, source cached under
`sources/rocknix-joypad/`. Read that source, not the in-tree patch, when debugging
axis or button behaviour.

`retrogame_joypad_s2_f1.dtsi` is a ready-made skeleton for "2 sticks and FN, fits
devices with 1 stick too", supplying all 17 `linux,code` values and a stable joystick
GUID. It cannot be included here because it declares the `joypad:` label that eeclone
already defines, but it is the reference for the button-name set.

## 8. WiFi — Rockchip RK915

The H7 has a **Rockchip RK915** SDIO WiFi chip (`wifi_chip_type = "rk915"` in the
stock DT). ROCKNIX ships no driver for it, and eeclone's `&sdio` is configured as an
SD card slot, so out of the box `mmc2` initialises, nothing enumerates and there is
no `wlan0`.

Three pieces are needed, all present in this tree:

| Piece | Where |
|---|---|
| MMC card quirks | `patches/linux/035-rk915-mmc-quirks.patch` |
| Driver + firmware | `packages/linux-drivers/rk915/`, pulled in via `ADDITIONAL_DRIVERS` |
| SDIO reconfiguration | `&sdio` / `sdio_pwrseq` / `&pinctrl` in the DTS |

### The driver

An out-of-tree mainline port originally by Danil Zagoskin, a ROCKNIX developer
(<https://github.com/stolen/rk915>). We pin to the head of **PR #2**
(`sunshineinabox`, branch `WIP-RK915_7.1`), which is a substantial rework:

- **targets Linux 7.1** — upstream `main` still targets 6.12.29
- moves the kernel-side changes onto the **standard MMC card-quirks framework**
  instead of vendor hacks in the MMC core
- loads firmware via `request_firmware` as `rockchip/rk915_{fw,patch}.bin`
- drops driver globals, rooting device state in `drvdata` and the HAL lifecycle in
  probe (relevant to the unload-stall defect)
- several genuine bug fixes: missing braces on basic-rate/txq params, gating
  `RX_FLAG_DECRYPTED` on the protected bit, one SDIO claim per TX descriptor with
  full TX status reporting, and reporting all disconnect reasons

The firmware blobs are **byte-identical** to those in the stock EmuELEC image
(md5 `a0e5ed75…` / `6c1f8ec6…`), confirming the driver targets this exact chip
revision.

⚠️ **PR #2 is a draft.** Its author wrote *"I may not get to look at this again for
awhile"*, and its README still carries the original status — chip disconnects soon
after association, unloading may stall the system.

Both of those defects are **real and reproduced here, and both are now fixed** —
the first by keeping the LMAC awake, the second by arming the dw_mmc data timeout
for writes. Three further bugs were found on the way. All five fixes, plus a
write-up of one fault that remains unsolved, are filed back upstream as
<https://github.com/sunshineinabox/rk915/pull/1>.

### The kernel quirks

`035-rk915-mmc-quirks.patch` registers three named card quirks via
`SDIO_FIXUP_COMPATIBLE("rockchip,rk915", ...)` in `drivers/mmc/core/quirks.h` —
the same mechanism upstream already uses for `ti,wl1251` and `silabs,wf200`:

| Quirk | Effect |
|---|---|
| `MMC_QUIRK_BROKEN_SDIO_FUNCE` | tolerate a short `CISTPL_FUNCE` (still requires ≥14 bytes), fall back to SDIO 1.0 defaults |
| `MMC_QUIRK_SDIO_CONT_CLOCK` | never enable dw_mmc low-power clock gating |
| `MMC_QUIRK_SDIO_CMD52_WAIT_DATA` | assert `PRV_DAT_WAIT` on `SD_IO_RW_DIRECT`, except on the abort path |

Because the match is on the card's `compatible`, no other device is affected —
which is why this needs `compatible = "rockchip,rk915"` on the `wifi@1` node.

Verified against pristine 7.1.2: applies with no fuzz, `SDIO_FIXUP_COMPATIBLE`
exists, `struct mmc_card` has `.quirks`, and bits 21–23 are unused.


### The sleep regression (found by diffing against the BSP)

First hardware test got as far as **associating** (`status=0 aid=9`), then ~4 s later:

```
rk915: rk915_serias_read: length(61680) too long error.
rk915: 30550/48056 bytes differ, first at 0x0 (wrote 0x81 read 0x00)
```

61680 = **0xF0F0** — both CMD52 byte reads in `rk915_read_data_len()` returning
0xF0. Firmware recovery then fails because SDIO is already incoherent, and every
mac80211 WARNING after that is just teardown of a device that is already gone.

Verified *not* to be an integration fault: the card node's
`compatible = "rockchip,rk915"` is bound (`/sys/bus/sdio/devices/mmc2:0001:1/
of_node/compatible`), `mmc_fixup_of_compatible_match()` scans exactly that set of
nodes, and `CLKENA = 0x1` shows the clock ungated. Bus is 50 MHz / 4-bit /
SD-high-speed / 3.3 V, matching the stock tree.

Diffing the port against the BSP driver in `docs/0001-rk915.patch` found the
cause. `hal.c` went from 1971 to 883 lines, and among the deletions:

```
trigger_wakeup   check_and_wakeup_rpu_nonblocking   get_rpu_sleep_status
trigger_timed_sleep
```

Those deletions look decisive, but they are not: in the BSP all four are **empty
stubs** (`trigger_wakeup()` is `{ return; }`), `RPU_SLEEP_ENABLE` is defined so
they compile and do nothing, and the one site in `hal.c` that would wake the chip
before a transfer sits inside `#if 0//def RPU_SLEEP_ENABLE` there too. There is no
host-side wake path in either tree.

What the port actually lost is the ability to stop the chip sleeping in the first
place — it kept telling the firmware it may sleep, and dropped the `module_param`
that could have turned that off:

| | BSP | port |
|---|---|---|
| | `unsigned int lpw_no_sleep = 0;`<br>`module_param(lpw_no_sleep, int, 0);` | `unsigned int lpw_no_sleep;` |

So the chip sleeps during the first idle moment after association and, with no
wake path anywhere, never wakes. `patches/rk915-0001-keep-lmac-awake.patch`
defaults it to 1 and restores the parameter. Costs idle power, and it is the only
lever that exists for this chip — it is also what the vendor's own
`rk915_rftest.sh` passes. The link then held for **13 h 44 m** continuously.

The loss looks accidental: the BSP declared nine `module_param`s and the port
declares two, yet the port still ships `rk915_rftest.sh`, which insmods with
`down_fw_in_probe=1 default_phy_threshold=180 lpw_no_sleep=1` — three parameters
the module no longer accepts.


### WiFi works, via a recovery unit

> **WiFi works, with one known limit.** It associates, holds a lease and keeps a
> stable MAC. Sustained transfer above roughly **15–29 KB/s** still faults the
> chip — in either direction, one connection is enough — but a fault is now a
> self-healing blip rather than a hard hang: several dw_mmc and driver bugs that
> turned it into a machine-wide lockup are fixed, and the driver's own firmware
> recovery now completes. Below that rate the link is stable indefinitely: 383 MB
> over 13 h 44 m with zero faults, and a 24 MB `rsync --bwlimit=15` with none
> either. Full record in **`RK915-WIFI.md`**; the outstanding chip-level fault is
> written up in **`RK915-UPSTREAM-REPORT.md`** and filed as
> <https://github.com/sunshineinabox/rk915/pull/1>.

The driver loses a race against boot-time system load and comes up with a dead
link roughly **two boots in three**: it associates and usually gets a DHCP lease,
then a few seconds later dies with

```
rk915: rk915_serias_read: length(61680) too long error.
rk915: -------- fw error recovery (0) start --------
```

Firmware recovery then fails (`30550/48056 bytes differ`) and mac80211 tears the
device down. 61680 is 0xF0F0 — a chained-RX header in `rk915_serias_read()` read
back as `0xF0F0____`, so `rx_next_len = mac_hdr->length >> 16` is garbage and the
bounds check kills the chip. Management frames always worked; the failure needs
data traffic. Time-to-failure was load-dependent (4.1 s, 13.2 s, 29.4 s).

The first-load failure has more than one face; `RPUWIFI-UMAC: No reset complete
after 900 ticks` is the same race showing up earlier, during chip reset.

Once the system is idle the driver is stable, so the fix is to reload it after
boot rather than to patch it. `system.d/rk915-recover.service`, installed and
enabled by the rk915 package, waits 30 s and — **only if the driver actually
logged a fault** — reloads `rk915` and restarts `iwd`. A healthy boot pays
nothing but the check.

The trigger is deliberately the kernel log, not connectivity. Keying on "no
default route" is wrong: with WiFi unconfigured, out of range, or simply unused
there is no route and no fault, and reloading would churn the driver and restart
`iwd` underneath the user — including renaming `wlan0` to `wlan1`, which is
visible in the UI. Validated over three consecutive boots: all three ended with working
networking, two after the unit logged `recovered`. Post-reload soaks: 300/300,
396/400 and — on a boot the unit recovered by itself — **400/400 pings, 0% loss,
3.19 MB RX**, zero driver faults throughout.

Hypotheses tested on hardware and **eliminated**:

| Tried | Result |
|---|---|
| `lpw_no_sleep=1` (LMAC sleep, patched default) | verified via `modinfo`; failure unchanged |
| `patch_features=12` (BSP firmware feature bits) | verified via cmdline; failure unchanged |
| explicit `udelay()` before the chained-header read | built and loaded; failed at both 200 µs and 2000 µs |

An earlier `debug_mask` bisect appeared to pin the fault on the single
`RK915_DBG_HALIO` call site (`BIT(18)`, one occurrence, `src/hal_io.c:228`), on the
theory that the port made the BSP's unconditional logging conditional and dropped
its incidental delays. **That did not replicate** — retested, both `0x40000` and
`0x150000` faulted. The original bisect was one run per arm against an intermittent
fault. The delay patch built on it is disproven and is not shipped; elapsed time
alone is not what distinguishes the printk from a busy-wait.

`rk915.patch_features` and `rk915.debug_mask` have been **removed** from the
cmdline. Neither was ever shown to help, and `debug_mask` is actively harmful
under load: the HALIO site logs **once per packet** in every chained RX burst, so
at 1.5 Mbaud a busy link spends ~267 µs of blocking console write per packet.
That starves vblank handling (`[CRTC:39:crtc-0] vblank wait timed out`), stalls
RCU, pins `systemd-journal` eating the flood, and freezes the device. It went
unnoticed because every soak up to that point was pings at 1/s, which never
exercises the logging path. With the parameters gone, a 10 pps / 1400-byte soak
moved 3.24 MB with 0 vblank timeouts, 0 RCU stalls, 0 driver faults and load
average 0.71.

Full account, including the measurements and the dead ends: **`RK915-WIFI.md`**.

### The device tree

eeclone's `&sdio` sets `cd-gpios = <&gpio0 RK_PA2>`. On the H7 that pin is
`WIFI,poweren_gpio` — so the DT holds the power-enable line as a card-detect input
and the chip never powers up. The DTS deletes the SD-card properties, adds an
`mmc-pwrseq-simple` driving `gpio0 RK_PA2`, and sets the values from the stock tree
(50 MHz, `cap-sd-highspeed`, `keep-power-in-suspend`), plus `non-removable`.

Host-wake is `gpio0 RK_PA1`, from the stock `WIFI,host_wake_irq`. The upstream
driver's example dtsi uses `RK_PA5` — that is its author's board, not this one.

---

## 9. Build and flash

```bash
make docker-RK3326        # host GCC 16 vs required GCC 12 — use the container
```

Produces `ROCKNIX-RK3326.aarch64-<date>-h7.img.gz` in `target/`. Write it to SD;
the H7's vendor U-Boot scans **SD before eMMC** (`boot_targets=mmc1 mmc0`), so a bad
image costs nothing — pull the card and the eMMC is untouched.

Watch the boot on serial at 1500000. The first boot runs `fs-resize` and reboots
itself; that is normal.

### Note for Arch hosts

`scripts/checkdeps` has Debian names in its `arch|endeavouros)` branch —
`gcc-12`, `g++-12`, `xfonts-utils`, `xorg-mkfontdir` (the last is not in the Arch
repos at all). `make docker-RK3326` avoids the whole issue.

---

## 10. Iterating without pulling the SD card

`systemd.debug_shell=ttyS2` is in the `APPEND` line, so `debug-shell.service` gives an
unauthenticated root shell on serial at 1500000. `/flash` is the SD's boot partition and
is remountable rw, so files can be replaced in place:

```bash
tio -b 1500000 -d 8 -p none -s 1 /dev/ttyUSB0    # interactive
```

The helper scripts alongside the eMMC backup automate it:

```bash
./push.py <local> /flash/<name>     # base64 over serial, md5-verified (~26 s for a DTB)
./sh.py 'sync; reboot'
```

`push.py` handles the `/flash` remount rw→ro and refuses to reboot on md5 mismatch.

### Over WiFi, now that WiFi works

Serial is fine for a DTB and hopeless for a 24 MB kernel. WiFi is usable for
this, but **only rate-limited** — sustained transfer above ~29 KB/s faults the
chip (see `RK915-WIFI.md`). At 15 KB/s a full kernel copies cleanly:

```bash
rsync -e "ssh" --partial --append-verify --bwlimit=15 \
      target/…/KERNEL root@<device>:/storage/KERNEL.new
```

`--partial --append-verify` matters: if the link does fault, the driver recovers
by itself and the next attempt resumes rather than restarting. 24 MB took ~26 min
and completed on the first attempt.

Then stage it, verify **before** overwriting the boot kernel, and keep a rollback
until the new one has booted:

```bash
mount -o remount,rw /flash
cp /flash/KERNEL /flash/KERNEL.prev
cp /storage/KERNEL.new /flash/KERNEL
md5sum /flash/KERNEL                       # must match target/KERNEL.md5
echo "<md5>  target/KERNEL" > /flash/KERNEL.md5
mount -o remount,ro /flash
```

Replacing only `KERNEL` is safe as long as the module ABI has not moved — a
`dw_mmc.c` change touching no exported symbol leaves the `rk915.ko` already in
`SYSTEM` loadable. Check `uname -r` matches if in doubt.

⚠️ **A soft `reboot` with the charger attached lands in U-Boot's charge-animation loop**
(`type:1-1,vol:...,cur:...` / `Wfi`) rather than booting — the vendor U-Boot only
continues when the charger goes offline. Unplug the charger or press power to boot.
Conversely, the console powers itself off when left idle at the U-Boot *prompt* on
battery, so keep it on the charger for U-Boot work and off it for reboots.

---

## 11. Re-deriving the panel

The panel description came from the stock DTB via `generic-dsi`'s importer, not by
hand:

```bash
python3 -m venv /tmp/v && /tmp/v/bin/pip install fdt
curl -sL https://github.com/stolen/overlay_server/archive/04e5e55b82d30c5c03d060f44cb6d7cd8840f531.zip -o gd.zip
unzip -q gd.zip
/tmp/v/bin/python overlay_server-*/rocknix_dtbo.py /path/to/stock.dtb -o mipi-panel.dtbo
dtc -I dtb -O dts mipi-panel.dtbo | grep default=1
# M clock=62000 horizontal=1024,90,80,80 vertical=768,16,8,8 default=1
```

Its `panel_description` is what `&internal_display` carries. The generated `.dtbo`
is no longer shipped — the DTS supersedes it — but the importer remains the way to
regenerate the values.
