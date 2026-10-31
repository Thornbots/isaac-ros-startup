#!/bin/bash
# camera-power-cycle.sh HUB...: if no RealSense (USB vendor 8086) is on the
# bus, switch off every port of each listed hub (sysfs names, e.g. 2-1 1-2),
# switch them back on and wait for the camera. Exit 0 once it is present.
# A USB3 port's power drops only with its USB2 companion's, so list both hubs.
# see README.md, "Camera power cycle"
set -uo pipefail

sysfs="${THORNBOTS_USB_SYSFS:-/sys/bus/usb/devices}"
off_s="${CAMERA_POWER_OFF_S:-5}"
wait_s="${CAMERA_POWER_WAIT_S:-15}"
present() { grep -qx 8086 "$sysfs"/*/idVendor 2>/dev/null; }

present && exit 0
ports=()
for hub in "$@"; do
    for p in "$sysfs/$hub/$hub:1.0/$hub"-port*/disable; do
        [[ -w "$p" ]] && ports+=("$p")
    done
done
(( ${#ports[@]} )) || { echo "camera-power-cycle: no switchable ports on: $*" >&2; exit 1; }
for p in "${ports[@]}"; do echo 1 > "$p"; done
sleep "$off_s"
for p in "${ports[@]}"; do echo 0 > "$p"; done
for (( i = 0; i < wait_s; i++ )); do present && exit 0; sleep 1; done
present || exit 1
