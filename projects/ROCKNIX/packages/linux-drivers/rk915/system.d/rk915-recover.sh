#!/bin/sh
# rk915 watchdog.
#
# The driver detects its own firmware faults and asks mac80211 to restart the
# hardware, but the firmware re-download that follows always fails
# ("N/48056 bytes differ, first at 0x0"), so mac80211 gives up and shuts the
# interface down and the link never comes back. Reloading the module does
# restore it, reliably. Watch for that signature and do exactly that.
#
# See RK915-WIFI.md. This is a mitigation, not a fix: the underlying fault is
# unresolved, and it cannot help the variant where the tx thread spins in the
# SDIO busy-wait, because modprobe -r hangs there.
DEAD='fw_bring_up: rk915_download_firmware failed'
COOLDOWN=60
POLL=5

reload_driver() {
        logger -t rk915-recover "link is dead - reloading rk915"
        modprobe -r rk915
        sleep 3
        modprobe cfg80211 2>/dev/null
        modprobe mac80211 2>/dev/null
        modprobe rk915
        sleep 10
        systemctl restart iwd
        sleep 20
        if ip route | grep -q '^default'; then
                logger -t rk915-recover "recovered"
        else
                logger -t rk915-recover "still down after reload"
        fi
}

# Boot-time check: the driver can lose the same race while the system is busy
# starting up.
sleep 30
seen=$(dmesg | grep -c "$DEAD")
if [ "$seen" -gt 0 ]; then
        reload_driver
        seen=$(dmesg | grep -c "$DEAD")
fi

while true; do
        sleep $POLL
        now=$(dmesg | grep -c "$DEAD")
        if [ "$now" -gt "$seen" ]; then
                reload_driver
                seen=$(dmesg | grep -c "$DEAD")
                sleep $COOLDOWN
        elif [ "$now" -lt "$seen" ]; then
                seen=$now          # ring buffer wrapped
        fi
done
