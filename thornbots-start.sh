#!/bin/bash
# /usr/local/bin/thornbots-start.sh: run the robot stack in a container.
# Called by thornbots.service: systemd -> this script -> docker run ->
# workspace-entrypoint.sh (creates admin) -> gosu admin thornbots-launch.sh.
# Config: /etc/thornbots/launch.env. Blank ISAAC_ROS_WS_HOST, HOST_USER_UID/GID
# and THORNBOTS_IMAGE are auto-detected. Prints [boot] lines with
# /proc/uptime so each stage's boot time is in the journal.
# see README.md for design rationale
set -euo pipefail

boot() { echo "[boot] $(cut -d' ' -f1 /proc/uptime)s $*"; }
boot "thornbots-start.sh"

ENV_FILE=/etc/thornbots/launch.env
LIB_DIR=/usr/local/lib/thornbots
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
# Exported, so the bare `-e VAR` flags below pass them into the container.
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# ── Workspace: first ~/workspaces/isaac_ros-dev, else ISAAC_ROS_WS in dotfiles
if [[ -z "${ISAAC_ROS_WS_HOST:-}" ]]; then
    for c in /home/*/workspaces/isaac_ros-dev; do
        [[ -d "$c" ]] && { ISAAC_ROS_WS_HOST="$c"; break; }
    done
fi
if [[ -z "${ISAAC_ROS_WS_HOST:-}" ]]; then
    while IFS= read -r cfg; do
        ws=$(grep -E '^\s*(export\s+)?ISAAC_ROS_WS=' "$cfg" 2>/dev/null | head -1 |
             sed "s|.*ISAAC_ROS_WS=[\"']*||; s|[\"' \t].*||; s|\${ISAAC_ROS_WS:-||; s|}\$||")
        [[ -z "$ws" ]] && continue
        home=$(getent passwd "$(stat -c %U "$cfg")" | cut -d: -f6)
        ws="${ws/\$\{HOME\}/$home}"; ws="${ws/\$HOME/$home}"; ws="${ws/\~/$home}"
        [[ -d "$ws" ]] && { ISAAC_ROS_WS_HOST="$ws"; break; }
    done < <(find /home -maxdepth 2 \( -name .bashrc -o -name .profile \) 2>/dev/null | sort)
fi
[[ -d "${ISAAC_ROS_WS_HOST:-}" ]] || {
    echo "ERROR: no workspace found; set ISAAC_ROS_WS_HOST in $ENV_FILE" >&2; exit 1; }
ISAAC_ROS_WS_HOST="${ISAAC_ROS_WS_HOST%/}"
HOST_USER_UID="${HOST_USER_UID:-$(stat -c %u "$ISAAC_ROS_WS_HOST")}"
HOST_USER_GID="${HOST_USER_GID:-$(stat -c %g "$ISAAC_ROS_WS_HOST")}"

# ── Image: newest isaac-ros-cli build of our chain, unless pinned
if [[ -z "${THORNBOTS_IMAGE:-}" ]]; then
    THORNBOTS_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' nvcr.io/nvidia/isaac/ros |
                      grep -m1 -E ':isaac_ros-realsense-thornbots_[0-9a-f]+-arm64-jetpack$' || true)
fi
[[ -n "$THORNBOTS_IMAGE" ]] && docker image inspect "$THORNBOTS_IMAGE" >/dev/null 2>&1 || {
    echo "ERROR: image '${THORNBOTS_IMAGE:-}' not found." >&2
    echo "       Build it once: isaac-ros activate --build-local" >&2; exit 1; }

# ── Model: the engine, or the ONNX TensorRT builds it from on first start
ENGINE_HOST="${ISAAC_ROS_WS_HOST}/${ENGINE_REL_PATH}"
ONNX_HOST="${ISAAC_ROS_WS_HOST}/${ONNX_REL_PATH}"
if [[ ! -f "$ENGINE_HOST" && ! -f "$ONNX_HOST" ]]; then
    echo "ERROR: neither $ENGINE_HOST nor $ONNX_HOST exists" >&2; exit 1
fi
[[ -f "$ENGINE_HOST" ]] || echo "No engine yet: TensorRT builds it from the ONNX (minutes)."

# ── Log: named by a run counter, never the date: the wall clock can be
# wrong until NTP syncs (README.md, "Logs survive a bad clock").
LOG_DIR="${LOG_DIR:-/var/log/thornbots}"
mkdir -p "$LOG_DIR" "$SNAPSHOT_OUTPUT_HOST" /var/lib/thornbots
RUN=$(( $(cat /var/lib/thornbots/run-count 2>/dev/null || echo 0) + 1 ))
echo "$RUN" > /var/lib/thornbots/run-count
RUN_NAME="thornbots-run$(printf %05d "$RUN")"
LOG_FILE="${LOG_DIR}/${RUN_NAME}.log"
ln -sfn "$(basename "$LOG_FILE")" "${LOG_DIR}/latest.log"
# The run's bag and ROS node logs, written in the container as the WS owner.
install -d -o "$HOST_USER_UID" -g "$HOST_USER_GID" "${LOG_DIR}/${RUN_NAME}"
ln -sfn "$RUN_NAME" "${LOG_DIR}/latest"

# ── Prune: oldest runs first while the disk has under LOG_MIN_FREE_GB free,
# always keeping the newest LOG_KEEP_RUNS.
pruned=()
mapfile -t old < <(cd "$LOG_DIR" && ls -d thornbots-run[0-9]*.log 2>/dev/null |
                   sed 's/\.log$//' | sort | head -n "-${LOG_KEEP_RUNS:-5}")
for r in "${old[@]}"; do
    (( $(df --output=avail -BG "$LOG_DIR" | tail -1 | tr -dc 0-9) < ${LOG_MIN_FREE_GB:-20} )) || break
    rm -rf "${LOG_DIR:?}/${r}" "${LOG_DIR:?}/${r}.log"
    pruned+=("$r")
done

# Flags follow isaac-ros-cli's run_dev.py for aarch64, minus X11 and the TTY.
# /dev stays the one --privileged gives; the host's is at /host-dev for the
# hotplugging lidar (README.md, "Why /host-dev").
{
    echo "Run     : ${RUN}, boot $(cut -c1-8 /proc/sys/kernel/random/boot_id), uptime $(cut -d' ' -f1 /proc/uptime)s"
    echo "Image   : ${THORNBOTS_IMAGE}"
    echo "WS host : ${ISAAC_ROS_WS_HOST} (uid/gid ${HOST_USER_UID}/${HOST_USER_GID}), src at $(git -c safe.directory='*' -C "${ISAAC_ROS_WS_HOST}/src" describe --always --dirty 2>/dev/null || echo '?')"
    echo "Log     : ${LOG_FILE}, bag and ROS logs in ${LOG_DIR}/${RUN_NAME}/"
    if (( ${#pruned[@]} )); then
        echo "Pruned  : ${pruned[*]} (under ${LOG_MIN_FREE_GB:-20} GB free)"
    fi
    # nvidia-cdi-refresh can run before udev gives the GPU nodes group video,
    # and that spec makes them root-only in the container: CUDA err=100 for
    # admin (sentry, 2026-10-01). Regenerate it if it disagrees with /dev.
    cdi=/var/run/cdi/nvidia.yaml
    if [[ -f "$cdi" ]] && ! grep -A5 'path: /dev/nvhost-gpu$' "$cdi" |
            grep -q "gid: $(stat -c %g /dev/nvhost-gpu)$"; then
        echo "CDI spec stale (GPU node group differs); regenerating $cdi"
        nvidia-ctk cdi generate --output="$cdi" >/dev/null 2>&1 ||
            echo "WARNING: nvidia-ctk cdi generate failed"
        boot "CDI spec regenerated"
    fi
    boot "docker run"
    set +e
    docker run --rm \
        --name thornbots-runtime \
        --privileged --network host --ipc=host --pid=host \
        --gpus all \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -e USERNAME=admin \
        -e HOST_USER_UID="${HOST_USER_UID}" \
        -e HOST_USER_GID="${HOST_USER_GID}" \
        -e ISAAC_ROS_WS=/workspaces/isaac_ros-dev \
        -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-1}" \
        -e USE_WS_OVERLAY="${USE_WS_OVERLAY:-false}" \
        -e ENGINE_PATH="/workspaces/isaac_ros-dev/${ENGINE_REL_PATH}" \
        -e ONNX_PATH="/workspaces/isaac_ros-dev/${ONNX_REL_PATH}" \
        -e CONFIDENCE_THRESHOLD -e NMS_THRESHOLD -e NUM_CLASSES \
        -e CENTER_WEIGHT -e PRIORITY_CLASS_BONUS -e PRIORITY_CLASS_IDS \
        -e LIDAR_SERIAL_DEVICE \
        -e LOCALIZATION_MODE -e ENABLE_SNAPSHOT \
        -e AUTO_LAUNCH_ARGS -e YOLO_LAUNCH_ARGS -e ENABLE_BAG \
        -e ENABLE_VIDEO -e VIDEO_JPEG_QUALITY \
        -e THORNBOTS_RUN_DIR="/data/thornbots-logs/${RUN_NAME}" \
        -v "${ISAAC_ROS_WS_HOST}:/workspaces/isaac_ros-dev" \
        -v "${LOG_DIR}:/data/thornbots-logs" \
        -v "${SNAPSHOT_OUTPUT_HOST}:/data/realsense-captures" \
        -v "${LIB_DIR}:/opt/thornbots-startup:ro" \
        -v /etc/localtime:/etc/localtime:ro \
        -v /usr/bin/tegrastats:/usr/bin/tegrastats \
        -v /sys/kernel/debug:/sys/kernel/debug:ro \
        -v /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra \
        -v /usr/src/jetson_multimedia_api:/usr/src/jetson_multimedia_api \
        -v /usr/share/vpi3:/usr/share/vpi3 \
        -v /dev/bus/usb:/dev/bus/usb \
        -v /dev:/host-dev \
        --workdir /workspaces/isaac_ros-dev \
        --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
        "${THORNBOTS_IMAGE}" \
        /opt/thornbots-startup/thornbots-launch.sh
    rc=$?
    set -e
    boot "container exited with code ${rc}"
    exit "$rc"
} 2>&1 | python3 "${LIB_DIR}/log-stamp.py" "$LOG_FILE"
exit "${PIPESTATUS[0]}"
