# Upstream report — draft for `sunshineinabox/rk915`, branch `WIP-RK915_7.1`

Filed against the branch I build from, following `docs/` as written: the 7.1
quirks patch, the DTS example, and `firmware/rockchip`. Hardware is a Gusgu H7
(RK3326/PX30), mainline 7.1.2, driver at `86f0d0e0`.

My device tree matches `docs/mainline-linux-dts-example.dtsi` property for
property, differing only in the host-wake pin (`RK_PA1` on this board rather than
`RK_PA5`), and my copy of the quirks patch is byte-identical to yours.

The README lists two known issues. **The second one has a fix below.** The first
one I could not solve, but I can offer a deterministic reproducer, a list of what
it is not — and a correction to how it is described: the chip does not drift off
the network after association, it dies on the first few hundred KB of sustained
traffic.

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

```diff
--- a/drivers/mmc/host/dw_mmc.c	2026-08-28 09:46:06.481799386 -0400
+++ b/drivers/mmc/host/dw_mmc.c	2026-08-28 09:46:06.482882724 -0400
@@ -2025,10 +2065,13 @@
 						&host->pending_events)) {
 				/*
 				 * If all data-related interrupts don't come
-				 * within the given time in reading data state.
+				 * within the given time. Armed for writes too:
+				 * the hardware data timeout does not cover the
+				 * write data phase, so a write to a card that
+				 * has stopped responding otherwise leaves
+				 * mmc_wait_for_req() waiting forever.
 				 */
-				if (host->dir_status == MMC_DATA_READ)
-					dw_mci_set_drto(host);
+				dw_mci_set_drto(host);
 				break;
 			}
 
@@ -2063,12 +2106,11 @@
 		case STATE_DATA_BUSY:
 			if (!dw_mci_clear_pending_data_complete(host)) {
 				/*
-				 * If data error interrupt comes but data over
-				 * interrupt doesn't come within the given time.
-				 * in reading data state.
+				 * If a data error interrupt comes but data over
+				 * does not follow within the given time. Armed
+				 * for writes as well, for the reason above.
 				 */
-				if (host->dir_status == MMC_DATA_READ)
-					dw_mci_set_drto(host);
+				dw_mci_set_drto(host);
 				break;
 			}
 
```

I also hit a `dw_mmc` interrupt storm worth knowing about: `TXDR`/`RXDR` are
enabled unconditionally by the initial `INTMASK` and never masked for DMA
transfers, where `host->sg` is NULL and the handler can only clear the latch.
Harmless while DMA drains the FIFO — but when the card dies the condition
persists and the level-triggered line storms at ~684,000/s, which on RK3326
(where all device interrupts are affine to CPU0) takes the whole machine down.
Masking them for the duration of a DMA transfer fixes it:

```diff
--- a/drivers/mmc/host/dw_mmc.c	2026-08-28 09:46:06.481799386 -0400
+++ b/drivers/mmc/host/dw_mmc.c	2026-08-28 09:46:06.482882724 -0400
@@ -1109,6 +1109,23 @@
 		host->prev_blksz = 0;
 	} else {
 		/*
+		 * DMA services the FIFO, so TXDR/RXDR are not used here. They
+		 * are nevertheless left enabled by the INTMASK written at probe
+		 * and never turned off again, so they fire throughout every DMA
+		 * transfer with host->sg == NULL. That is normally harmless -
+		 * the DMA drains the FIFO and the condition clears - but if the
+		 * card stops responding mid-transfer the condition persists and
+		 * the level-triggered line storms: ~684,000 interrupts/second
+		 * measured on an RK3326, which starves every other interrupt on
+		 * that CPU and hangs the machine.
+		 */
+		spin_lock_irqsave(&host->irq_lock, irqflags);
+		temp = mci_readl(host, INTMASK);
+		temp &= ~(SDMMC_INT_TXDR | SDMMC_INT_RXDR);
+		mci_writel(host, INTMASK, temp);
+		spin_unlock_irqrestore(&host->irq_lock, irqflags);
+
+		/*
 		 * Keep the current block size.
 		 * It will be used to decide whether to update
 		 * fifoth register next time.
@@ -1554,6 +1571,29 @@
 	}
 }
 
+/*
+ * TXDR/RXDR ask for the FIFO to be serviced by the CPU. If there is no transfer
+ * left to service - host->sg is NULL - the handler can only clear the latch, the
+ * underlying FIFO condition persists, and the level-triggered line is re-raised
+ * immediately. Mask the bit; dw_mci_submit_data() re-enables it for the next PIO
+ * transfer.
+ */
+static void dw_mci_mask_stuck_fifo_irq(struct dw_mci *host, u32 bit)
+{
+	unsigned long irqflags;
+	u32 int_mask;
+
+	spin_lock_irqsave(&host->irq_lock, irqflags);
+	int_mask = mci_readl(host, INTMASK);
+	if (int_mask & bit) {
+		mci_writel(host, INTMASK, int_mask & ~bit);
+		dev_err_ratelimited(host->dev,
+				    "FIFO irq %#x with no transfer to service; masking\n",
+				    bit);
+	}
+	spin_unlock_irqrestore(&host->irq_lock, irqflags);
+}
+
 static void __dw_mci_enable_sdio_irq(struct dw_mci *host, int enb)
 {
 	unsigned long irqflags;
@@ -2749,12 +2791,16 @@
 			mci_writel(host, RINTSTS, SDMMC_INT_RXDR);
 			if (host->dir_status == MMC_DATA_READ && host->sg)
 				dw_mci_read_data_pio(host, false);
+			else
+				dw_mci_mask_stuck_fifo_irq(host, SDMMC_INT_RXDR);
 		}
 
 		if (pending & SDMMC_INT_TXDR) {
 			mci_writel(host, RINTSTS, SDMMC_INT_TXDR);
 			if (host->dir_status == MMC_DATA_WRITE && host->sg)
 				dw_mci_write_data_pio(host);
+			else
+				dw_mci_mask_stuck_fifo_irq(host, SDMMC_INT_TXDR);
 		}
 
 		if (pending & SDMMC_INT_CMD_DONE) {
```

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

```diff
--- a/src/sdio.c	2026-08-27 13:24:01.819863640 -0400
+++ b/src/sdio.c	2026-08-27 13:24:01.820603502 -0400
@@ -542,6 +542,22 @@
 		ret = sdio_enable_func(func);
 	if (!ret)
 		ret = sdio_set_block_size(func, 512);
+	if (!ret) {
+		/*
+		 * _sdio_reset() latches sdio_reset on the first io error, and
+		 * every accessor then returns 0 *without doing any i/o*. The
+		 * latch was only ever cleared by sdio_probe(), so after one
+		 * error the firmware download that error recovery depends on
+		 * writes into nothing while reporting success - 4KB "written"
+		 * in 2us - the readback is all zeroes, the chip never reaches
+		 * WAIT_PATCH, and mac80211 tears the device down. That is why
+		 * only a module reload ever brought the link back.
+		 *
+		 * The card has just been reset, re-enabled and had its block
+		 * size restored, so i/o is valid again: drop the latch.
+		 */
+		sdio_reset = false;
+	}
 	sdio_release_host(func);
 	if (ret)
 		rk915_err("%s: failed (%d)\n", __func__, ret);
```

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

```diff
--- a/src/umac_if.c	2026-08-27 13:24:01.825222478 -0400
+++ b/src/umac_if.c	2026-08-27 13:24:01.826363899 -0400
@@ -607,6 +607,23 @@
 	INIT_DELAYED_WORK(&priv->roc_complete_work, rpu_roc_complete_work);
 
 	priv->state = STARTED;
+
+	/*
+	 * mac80211 re-adds every interface after a hardware restart, but it
+	 * never calls remove_interface() for the ones that were up before, and
+	 * the vif accounting is otherwise only cleared by rpu_init() at module
+	 * load. Without this the second restart trips
+	 *
+	 *   rk915: add_interface: Exceeded Maximum supported VIF's cur:2 max: 2
+	 *
+	 * add_interface() returns -ENOTSUPP, mac80211 tears the interface down
+	 * and the link never comes back even though the firmware reloaded
+	 * cleanly. start() is always called before interfaces are re-added, so
+	 * this is the right place to drop the stale accounting.
+	 */
+	priv->current_vif_count = 0;
+	priv->active_vifs = 0;
+
 	memset(priv->params->pdout_voltage, 0,
 		sizeof(char) * MAX_AUX_ADC_SAMPLES);
 
```

## Minor: racy firmware-error claim

`rk915_signal_io_error()` guards with a plain test-then-set, so the rx and tx
threads both get through and `ieee80211_restart_hw()` is called twice, 163 µs
apart:

```
[2250.486151] rk915: -------- fw error recovery (0) start --------
[2250.486314] rk915: -------- fw error recovery (0) start --------
```

`cmpxchg()` on `fw_error_processing` fixes it.

```diff
--- a/src/umac_if.c	2026-08-27 11:14:36.689792575 -0400
+++ b/src/umac_if.c	2026-08-27 11:14:36.690819895 -0400
@@ -464,10 +464,16 @@
 		return;
 	hal->fw_error = 1;
 	rk915_wake_waiters(hal);
-	if (!hal->fw_error_processing) {
+	/*
+	 * The rx and tx threads both signal io errors, and a plain
+	 * test-then-set lets both through: two recoveries start within
+	 * microseconds of each other and ieee80211_restart_hw() is called
+	 * twice, the second landing while the first restart is still in
+	 * flight. Claim the recovery atomically so exactly one runs.
+	 */
+	if (cmpxchg(&hal->fw_error_processing, 0, 1) == 0) {
 		__pm_stay_awake(hal->fw_err_ws);
 
-		hal->fw_error_processing = 1;
 		hal->fw_error_counter++;
 		hal->fw_error_reason = reason;
 
```

---

## Known issue 1 — the description does not match what I see

The README says *"Soon after association chip disconnects from network"*. That is
not what happens on my hardware, and the difference matters for anyone trying to
reproduce it.

**The association is stable.** This device has held its link for nearly 13 hours
continuously, idle and under light traffic, with no disconnect. Time since
association is not the variable.

**Sustained traffic kills it, in well under a megabyte.** Three runs pushing a
single TCP stream at a `nc` sink died after 0.20 MB, 0.46 MB and 0.79 MB, each
within ~10 s of starting. Eight parallel keep-alive HTTP connections die just as
reliably, after 10–80 requests. By contrast, 35 sequential HTTP bursts of ~49 KB
each with a 12 s idle gap between them ran clean start to finish.

So it is not concurrency as such — one connection is enough — and it is not time
since association. It is the volume of data moved without a pause. Concurrency
only matters because it is the easy way to generate that volume, which is
probably why this reads as "disconnects soon after association": the first thing
anyone does after associating is open a browser, and a directory listing is
enough to cross the threshold.

Minimal form — one stream, no HTTP, no concurrency. On any machine on the same
LAN, then on the device:

```sh
laptop$  nc -l -p 5001 > /dev/null
device$  dd if=/dev/zero bs=64k | nc $LAPTOP_IP 5001
```

It dies inside ~10 s. The browser-shaped version, which is how I first hit it:

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
buffer-credit rule around `num_frames_per_desc`, that is where I would look
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

---

## Note on what is deliberately *not* in these patches

My tree briefly carried three further dw_mmc guards: bailing out of
`dw_mci_wait_while_busy()` and of `dw_mci_interrupt()` on an all-ones register
read, and acknowledging abnormal IDMAC bits. Each came from a hypothesis about
the interrupt storm that turned out to be wrong, and none of them ever fired once
the real cause was found. They have been dropped rather than offered as
speculative hardening.

All patches above are against mainline 7.1.2 and this branch at `86f0d0e0`, and
are running on hardware here.
