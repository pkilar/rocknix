#!/bin/sh
# Reload rk915 when the driver lost the boot-time RX race (see RK915-WIFI.md).
#
# The test is "did the driver actually fault", NOT "is there a default route".
# With WiFi unconfigured, out of range, or simply unused there is no route and
# no fault, and reloading would churn the driver and restart iwd underneath the
# user - including renaming wlan0 to wlan1, which is visible in the UI.
#
# "rx_thread: error datalen" is deliberately not in this list: it is also seen
# once on a healthy interface bring-up, so it is not decisive on its own.
FAULTS='rk915: .*(too long error|fw error recovery|No reset complete|check downloaded fw failed|rk915_download_firmware failed)'

sleep 30

if ! dmesg | grep -qE "$FAULTS"; then
  logger -t rk915-recover "no driver fault logged, leaving it alone"
  exit 0
fi

mark=$(dmesg | wc -l)
logger -t rk915-recover "driver fault detected, reloading rk915"
modprobe -r rk915
sleep 3
modprobe rk915
sleep 10
systemctl restart iwd
sleep 20

if dmesg | tail -n +$((mark + 1)) | grep -qE "$FAULTS"; then
  logger -t rk915-recover "still faulting after reload"
else
  logger -t rk915-recover "recovered"
fi
