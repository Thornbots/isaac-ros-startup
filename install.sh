#!/bin/bash
# install.sh: install and enable thornbots.service on this robot.
#   sudo bash install.sh [--ws /path/to/isaac_ros-dev]
# Writes /etc/thornbots/launch.env from launch.env with the workspace, UID
# and GID filled in, keeping an existing one (it may hold tuned values)
# unless --reset-config. Installs the scripts to /usr/local/lib/thornbots.
set -euo pipefail

WS="" RESET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ws) WS="$2"; shift 2 ;;
        --reset-config) RESET=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ "$(id -u)" == 0 ]] || { echo "run with sudo" >&2; exit 1; }
SRC="$(dirname "$(readlink -f "$0")")"

if [[ -z "$WS" ]]; then
    ws=(/home/*/workspaces/isaac_ros-dev)
    [[ -d "${ws[0]}" ]] || { echo "no /home/*/workspaces/isaac_ros-dev; pass --ws" >&2; exit 1; }
    (( ${#ws[@]} == 1 )) || { echo "several workspaces (${ws[*]}); pass --ws" >&2; exit 1; }
    WS="${ws[0]}"
fi
WS="$(readlink -f "$WS")"
OWNER=$(stat -c %U "$WS")
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
echo "workspace $WS, owner $OWNER ($(stat -c %u:%g "$WS"))"

install -d /etc/thornbots /usr/local/lib/thornbots
install -m 755 "$SRC/thornbots-launch.sh" "$SRC/cuda-probe.py" "$SRC/log-stamp.py" /usr/local/lib/thornbots/
install -m 755 "$SRC/thornbots-start.sh" /usr/local/bin/thornbots-start.sh
install -m 644 "$SRC/thornbots.service" /etc/systemd/system/thornbots.service
# Keep logind from deleting the stack's Fast DDS segments on logout.
install -D -m 644 "$SRC/logind-thornbots.conf" /etc/systemd/logind.conf.d/thornbots.conf
systemctl restart systemd-logind

CFG=/etc/thornbots/launch.env
if [[ -f "$CFG" && "$RESET" == 0 ]]; then
    echo "kept $CFG (--reset-config rewrites it)"
else
    sed -e "s|^ISAAC_ROS_WS_HOST=.*|ISAAC_ROS_WS_HOST=$WS|" \
        -e "s|^HOST_USER_UID=.*|HOST_USER_UID=$(stat -c %u "$WS")|" \
        -e "s|^HOST_USER_GID=.*|HOST_USER_GID=$(stat -c %g "$WS")|" \
        -e "s|^LOG_DIR=.*|LOG_DIR=$HOME_DIR/logs|" \
        "$SRC/launch.env" > "$CFG"
    chmod 644 "$CFG"
    echo "wrote $CFG"
fi
install -d -o "$OWNER" -g "$(stat -c %g "$WS")" "$HOME_DIR/logs"

systemctl daemon-reload
systemctl enable thornbots.service
echo "enabled. start now: sudo systemctl start thornbots; logs: journalctl -u thornbots -f"
