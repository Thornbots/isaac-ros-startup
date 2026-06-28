#!/bin/bash
# install.sh — Thornbots Isaac ROS Startup installer.
#
# Detects per-machine settings (workspace path, UID, GID) automatically
# and writes a fully populated /etc/thornbots/launch.env so the service
# works without any manual editing.
#
# Usage (run as root or with sudo):
#   sudo bash install.sh
#
# To target a specific user's workspace instead of auto-detecting:
#   sudo bash install.sh --user alice
#   sudo bash install.sh --ws /path/to/isaac_ros-dev

set -euo pipefail

# ── Parse arguments ─────────────────────────────────────────────────────────
TARGET_USER=""
TARGET_WS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --ws)   TARGET_WS="$2";   shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Require root ─────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo bash install.sh)." >&2
    exit 1
fi

echo "=== Thornbots Isaac ROS Startup Installer ==="
echo ""

# ── Discover the Isaac ROS workspace ────────────────────────────────────────
discover_workspace() {
    # If --ws was supplied, trust it.
    if [[ -n "$TARGET_WS" ]]; then
        echo "$TARGET_WS"
        return
    fi

    # If --user was supplied, check that user's standard location first.
    if [[ -n "$TARGET_USER" ]]; then
        local user_home
        user_home=$(getent passwd "$TARGET_USER" | cut -d: -f6) || {
            echo "ERROR: User '$TARGET_USER' not found." >&2; exit 1
        }
        local std="${user_home}/workspaces/isaac_ros-dev"
        if [[ -d "$std" ]]; then
            echo "$std"
            return
        fi
        echo "ERROR: Standard workspace not found for '$TARGET_USER': $std" >&2
        echo "       Use --ws /path/to/workspace to specify it manually." >&2
        exit 1
    fi

    # Auto-scan: collect all candidate workspaces on the system.
    local candidates=()
    for _candidate in /home/*/workspaces/isaac_ros-dev /root/workspaces/isaac_ros-dev; do
        [[ -d "$_candidate" ]] && candidates+=("$_candidate")
    done

    # Fall back to shell-config parsing for non-standard paths.
    if [[ ${#candidates[@]} -eq 0 ]]; then
        while IFS= read -r _cfg; do
            [[ -f "$_cfg" ]] || continue
            local _ws
            _ws=$(grep -E '^\s*(export\s+)?ISAAC_ROS_WS=' "$_cfg" 2>/dev/null \
                  | head -1 \
                  | sed "s|.*ISAAC_ROS_WS=[\"']*||; s|[\"' \t].*||")
            [[ -z "$_ws" ]] && continue
            local _owner _owner_home
            _owner=$(stat -c '%U' "$_cfg" 2>/dev/null) || continue
            _owner_home=$(getent passwd "$_owner" | cut -d: -f6) || continue
            _ws="${_ws/\$HOME/$_owner_home}"
            _ws="${_ws/\~/$_owner_home}"
            [[ -d "$_ws" ]] && candidates+=("$_ws")
        done < <(find /home /root -maxdepth 2 \
                      \( -name '.bashrc' -o -name '.bash_profile' \
                         -o -name '.profile' -o -name '.zshrc' \) \
                      2>/dev/null | sort)
    fi

    # Deduplicate
    local seen=()
    local unique=()
    for c in "${candidates[@]+"${candidates[@]}"}"; do
        local found=0
        for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$c" ]] && found=1 && break; done
        [[ "$found" -eq 0 ]] && unique+=("$c") && seen+=("$c")
    done
    candidates=("${unique[@]+"${unique[@]}"}")

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "ERROR: No Isaac ROS workspace found on this system." >&2
        echo "       Use --ws /path/to/workspace to specify it manually." >&2
        exit 1
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]}"
        return
    fi

    # Multiple candidates found — prompt the user to choose.
    echo "" >&2
    echo "Multiple Isaac ROS workspaces found:" >&2
    local i=1
    for c in "${candidates[@]}"; do
        echo "  $i) $c" >&2
        ((i++))
    done
    local choice
    read -r -p "Which workspace should the service use? [1]: " choice </dev/tty
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#candidates[@]} )); then
        echo "ERROR: Invalid selection." >&2; exit 1
    fi
    echo "${candidates[$((choice - 1))]}"
}

WS_HOST=$(discover_workspace)

if [[ ! -d "$WS_HOST" ]]; then
    echo "ERROR: Workspace path does not exist: $WS_HOST" >&2
    exit 1
fi

echo "Workspace : $WS_HOST"

# ── Derive UID/GID from workspace owner ────────────────────────────────────
WS_UID=$(stat -c '%u' "$WS_HOST")
WS_GID=$(stat -c '%g' "$WS_HOST")
WS_OWNER=$(stat -c '%U' "$WS_HOST")
echo "Owner     : $WS_OWNER (uid=$WS_UID gid=$WS_GID)"

# ── Install config ──────────────────────────────────────────────────────────
CONFIG_DIR="/etc/thornbots"
CONFIG_FILE="${CONFIG_DIR}/launch.env"
SCRIPT_SRC="$(dirname "$0")/thornbots-start.sh"
SCRIPT_DST="/usr/local/bin/thornbots-start.sh"
SERVICE_SRC="$(dirname "$0")/thornbots.service"
SERVICE_DST="/etc/systemd/system/thornbots.service"

echo ""
echo "Installing config to $CONFIG_FILE ..."
mkdir -p "$CONFIG_DIR"

# Write a fully populated launch.env for this machine.
# We preserve all the tunable defaults from the template and bake in
# the discovered machine-specific values.
cat > "$CONFIG_FILE" << EOF
# /etc/thornbots/launch.env  — generated by install.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Machine: $(hostname)
# Re-run install.sh to regenerate, or edit manually.
# After changes: sudo systemctl daemon-reload && sudo systemctl restart thornbots

# ── Host workspace ────────────────────────────────────────────────────────
ISAAC_ROS_WS_HOST=${WS_HOST}

# ── Snapshot output ───────────────────────────────────────────────────────
SNAPSHOT_OUTPUT_HOST=/data/realsense-captures

# ── Model ─────────────────────────────────────────────────────────────────
MODEL_REL_PATH=isaac_ros_assets/models/yolo11/yolo11s_fp16.plan

# ── Inference thresholds ──────────────────────────────────────────────────
CONFIDENCE_THRESHOLD=0.25
NMS_THRESHOLD=0.45
CENTER_SAMPLE_FRACTION=0.25

# ── DJI serial bridge ─────────────────────────────────────────────────────
SERIAL_DEVICE=/dev/ttyTHS1
SERIAL_BAUDRATE=115200

# ── Snapshot capture ──────────────────────────────────────────────────────
ENABLE_SNAPSHOT=False

# ── Docker image ──────────────────────────────────────────────────────────
THORNBOTS_IMAGE=isaac_ros_dev-aarch64

# ── Container user (auto-detected from workspace owner) ───────────────────
HOST_USER_UID=${WS_UID}
HOST_USER_GID=${WS_GID}
EOF

chmod 640 "$CONFIG_FILE"
echo "  Written."

# ── Install start script ────────────────────────────────────────────────────
echo "Installing start script to $SCRIPT_DST ..."
if [[ ! -f "$SCRIPT_SRC" ]]; then
    echo "ERROR: thornbots-start.sh not found next to install.sh." >&2
    exit 1
fi
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod 755 "$SCRIPT_DST"
echo "  Installed."

# ── Install systemd service ─────────────────────────────────────────────────
echo "Installing systemd service to $SERVICE_DST ..."
if [[ ! -f "$SERVICE_SRC" ]]; then
    echo "ERROR: thornbots.service not found next to install.sh." >&2
    exit 1
fi
cp "$SERVICE_SRC" "$SERVICE_DST"
systemctl daemon-reload
echo "  Installed."

# ── Enable and optionally start ─────────────────────────────────────────────
systemctl enable thornbots
echo ""
echo "=== Installation complete ==="
echo ""
echo "  Config  : $CONFIG_FILE"
echo "  Script  : $SCRIPT_DST"
echo "  Service : $SERVICE_DST"
echo ""
echo "Start now:"
echo "  sudo systemctl start thornbots"
echo ""
echo "Follow logs:"
echo "  journalctl -u thornbots -f"
echo ""
echo "To reconfigure this machine, re-run:  sudo bash install.sh"
