#!/bin/bash
# /usr/local/bin/thornbots-start.sh
#
# Production launcher for the Thornbots Isaac ROS vision pipeline.
# Intended to be called by thornbots.service, NOT run_dev.sh.
#
# Execution chain:
#   systemd → this script → docker run
#     → workspace-entrypoint.sh  (creates admin user, adds dialout, restarts udev)
#     → exec gosu admin /bin/bash (sources ROS, runs cuda probe, runs ros2 launch)
#
set -euo pipefail

# ── Load configuration ──────────────────────────────────────────────────────
ENV_FILE="/etc/thornbots/launch.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Config file not found: $ENV_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Auto-discover ISAAC_ROS_WS_HOST if not set ─────────────────────────────
if [[ -z "${ISAAC_ROS_WS_HOST:-}" ]]; then
    echo "ISAAC_ROS_WS_HOST not set — auto-discovering..."
    _discovered=""

    for _candidate in /home/*/workspaces/isaac_ros-dev /root/workspaces/isaac_ros-dev; do
        if [[ -d "$_candidate" ]]; then
            _discovered="$_candidate"
            break
        fi
    done

    if [[ -z "$_discovered" ]]; then
        while IFS= read -r _cfg; do
            [[ -f "$_cfg" ]] || continue
            _ws=$(grep -E '^\s*(export\s+)?ISAAC_ROS_WS=' "$_cfg" 2>/dev/null \
                  | head -1 \
                  | sed "s|.*ISAAC_ROS_WS=[\"']*||; s|[\"' \t].*||")
            [[ -z "$_ws" ]] && continue
            _owner=$(stat -c '%U' "$_cfg" 2>/dev/null) || continue
            _owner_home=$(getent passwd "$_owner" | cut -d: -f6) || continue
            _ws="${_ws/\$HOME/$_owner_home}"
            _ws="${_ws/\~/$_owner_home}"
            if [[ -d "$_ws" ]]; then
                _discovered="$_ws"
                break
            fi
        done < <(find /home /root -maxdepth 2 \
                      \( -name '.bashrc' -o -name '.bash_profile' \
                         -o -name '.profile' -o -name '.zshrc' \) \
                      2>/dev/null | sort)
    fi

    if [[ -z "$_discovered" ]]; then
        echo "ERROR: Could not auto-discover ISAAC_ROS_WS_HOST." >&2
        echo "       Set ISAAC_ROS_WS_HOST in $ENV_FILE and restart." >&2
        exit 1
    fi

    ISAAC_ROS_WS_HOST="$_discovered"
    echo "  Discovered workspace: $ISAAC_ROS_WS_HOST"
fi

# ── Auto-detect UID/GID from workspace owner if not set ────────────────────
if [[ -z "${HOST_USER_UID:-}" ]]; then
    HOST_USER_UID=$(stat -c '%u' "$ISAAC_ROS_WS_HOST")
    echo "Auto-detected HOST_USER_UID: $HOST_USER_UID"
fi
if [[ -z "${HOST_USER_GID:-}" ]]; then
    HOST_USER_GID=$(stat -c '%g' "$ISAAC_ROS_WS_HOST")
    echo "Auto-detected HOST_USER_GID: $HOST_USER_GID"
fi

# ── Validate ────────────────────────────────────────────────────────────────
if [[ ! -d "$ISAAC_ROS_WS_HOST" ]]; then
    echo "ERROR: ISAAC_ROS_WS_HOST does not exist: $ISAAC_ROS_WS_HOST" >&2
    exit 1
fi

MODEL_HOST_PATH="${ISAAC_ROS_WS_HOST}/${MODEL_REL_PATH}"
if [[ ! -f "$MODEL_HOST_PATH" ]]; then
    echo "ERROR: TensorRT engine not found: $MODEL_HOST_PATH" >&2
    exit 1
fi

if [[ -z "$(docker image ls --quiet "$THORNBOTS_IMAGE" 2>/dev/null)" ]]; then
    echo "ERROR: Docker image not found: $THORNBOTS_IMAGE" >&2
    echo "       Run run_dev.sh once on this machine to build it, then re-enable the service." >&2
    exit 1
fi

# ── Create output directories ───────────────────────────────────────────────
mkdir -p "$SNAPSHOT_OUTPUT_HOST"

# ── Log file setup ──────────────────────────────────────────────────────────
# Each service run gets a timestamped log file so runs never overwrite each other.
# Old files beyond the LOG_KEEP_COUNT most recent are pruned automatically.
LOG_DIR="${LOG_DIR:-/var/log/thornbots}"
LOG_KEEP_COUNT="${LOG_KEEP_COUNT:-20}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/thornbots-$(date +%Y%m%d-%H%M%S).log"

# Prune old logs before starting so disk usage stays bounded.
# IMPORTANT: wrap ls in a subgroup + || true so that when no *.log files
# exist yet (first run), ls exits 2 ("no such file") without triggering
# set -euo pipefail.  The 2>/dev/null suppresses the error message but NOT
# the exit code — the || true is what actually prevents the crash.
{ ls -t "${LOG_DIR}"/thornbots-*.log 2>/dev/null || true; } \
    | tail -n +"$((LOG_KEEP_COUNT + 1))" \
    | xargs -r rm -f

echo "Logging to: $LOG_FILE"

# ── CUDA readiness probe ─────────────────────────────────────────────────────
# workspace-entrypoint.sh always runs 'service udev restart' before handing
# off to LAUNCH_CMD. On Jetson Orin this transiently disrupts /dev/nvhost-gpu
# (the CUDA compute engine device node) and leaves the CUDA driver in an
# inconsistent state for a few seconds. If the ROS pipeline starts immediately
# afterwards, NitrosContext's cudaMemPoolCreate returns cudaErrorNotSupported,
# GXF dereferences the null pool handle, and the process SIGSEGV (exit -11).
#
# The original probe used nvidia-smi, which does NOT exist inside Isaac ROS
# containers on aarch64/JetPack — the Tegra GPU stack has no nvidia-smi.
# That caused the probe to loop until its 60-second hard timeout on every run,
# preventing the pipeline from ever launching.
#
# Fix: two-stage Jetson-native check written to /tmp (which is bind-mounted
# into the container at the same path so LAUNCH_CMD can call it directly):
#
#   Stage 1 — device node:  poll /dev/nvhost-gpu until udev re-enumerates it.
#   Stage 2 — driver init:  call cuInit(0) via python3+ctypes against the
#             tegra libcuda bind-mount, which is the only reliable test that
#             the CUDA driver's internal state is fully consistent.
#   Stage 3 — settle:       3-second pause for GXF/NITROS memory-pool alloc.
#
# Write the Python CUDA check to its own file so the probe script can call
# it with a plain command rather than using eval+heredoc (which is fragile
# across bash versions and hard to debug).  Both files land in /tmp, which
# is bind-mounted into the container at the same path via -v /tmp/:/tmp/.
cat > /tmp/thornbots-check-cuda.py << 'PYEOF'
import ctypes, sys
# Try the Jetson Tegra path first (bind-mounted from the host), then fall
# back to the linker search path in case the layout differs across JetPack.
for path in ['/usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1', 'libcuda.so.1']:
    try:
        lib = ctypes.CDLL(path)
        # cuInit(0) == 0 means CUDA_SUCCESS — driver fully ready.
        sys.exit(0 if lib.cuInit(0) == 0 else 1)
    except OSError:
        pass
sys.exit(1)
PYEOF

cat > /tmp/thornbots-cuda-probe.sh << 'PROBE'
#!/bin/bash
# Called from LAUNCH_CMD (inside the container) before sourcing ROS.
# workspace-entrypoint.sh restarts udev, which transiently removes
# /dev/nvhost-gpu and leaves the CUDA driver inconsistent.  If NITROS
# starts before CUDA recovers it calls cudaMemPoolCreate on a null handle
# → SIGSEGV (exit -11).  This probe gates launch until CUDA is ready.

_wait() {
    local desc="$1" check="$2" n=0 timeout=90
    until eval "$check" 2>/dev/null; do
        n=$((n + 2))
        if (( n > timeout )); then
            echo "[thornbots] ERROR: timed out waiting for ${desc} (${timeout}s)." >&2
            exit 1
        fi
        echo "[thornbots] Waiting for ${desc} (${n}s elapsed)..."
        sleep 2
    done
    echo "[thornbots] ${desc} OK."
}

# Stage 1: device node — udev must re-enumerate /dev/nvhost-gpu before
# the CUDA driver can be contacted at all.
_wait "/dev/nvhost-gpu" "[ -e /dev/nvhost-gpu ]"

# Stage 2: driver init — even once the node exists the driver needs a moment
# to reach a consistent state.  python3 + /tmp/thornbots-check-cuda.py
# (written by thornbots-start.sh and visible here via -v /tmp/:/tmp/)
# calls cuInit(0) and exits 0 only on CUDA_SUCCESS.
_wait "CUDA driver (cuInit)" "python3 /tmp/thornbots-check-cuda.py"

# Stage 3: settle — GXF/NITROS allocates memory pools immediately after
# cuInit; give the driver 3 s to finish internal initialisation.
echo "[thornbots] CUDA ready — settling 3s for NITROS memory-pool init..."
sleep 3
PROBE
chmod +x /tmp/thornbots-cuda-probe.sh

# ── Container-side paths ────────────────────────────────────────────────────
CONTAINER_WS=/workspaces/isaac_ros-dev
CONTAINER_MODEL="${CONTAINER_WS}/${MODEL_REL_PATH}"
CONTAINER_SNAPSHOT=/data/realsense-captures
CONTAINER_ROS_WS=/workspaces/ros2_ws   # packages baked into the image at build time

# ── Build the command that runs inside the container as 'admin' ─────────────
# Source ROS explicitly: bash is non-interactive here so /etc/bash.bashrc
# is not sourced automatically.
LAUNCH_CMD="bash /tmp/thornbots-cuda-probe.sh \
  && source /opt/ros/humble/setup.bash \
  && source ${CONTAINER_ROS_WS}/install/setup.bash \
  && exec ros2 launch realsense_yolov8_nitros_bridge isaac_ros_yolov8_realsense.launch.py \
       engine_file_path:=${CONTAINER_MODEL} \
       confidence_threshold:=${CONFIDENCE_THRESHOLD} \
       nms_threshold:=${NMS_THRESHOLD} \
       center_sample_fraction:=${CENTER_SAMPLE_FRACTION} \
       serial_device:=${SERIAL_DEVICE} \
       serial_baudrate:=${SERIAL_BAUDRATE} \
       enable_snapshot:=${ENABLE_SNAPSHOT} \
       snapshot_output_dir:=${CONTAINER_SNAPSHOT}"

echo "Starting Thornbots runtime container..."
echo "  Image   : ${THORNBOTS_IMAGE}"
echo "  WS host : ${ISAAC_ROS_WS_HOST}"
echo "  UID/GID : ${HOST_USER_UID}/${HOST_USER_GID}"
echo "  Model   : ${MODEL_HOST_PATH}"
echo "  Log     : ${LOG_FILE}"

# ── docker run ──────────────────────────────────────────────────────────────
# Output is piped through 'tee' so it goes to both the journal (via systemd's
# stdout capture) AND the persistent log file simultaneously.
# We cannot use 'exec docker run' with a pipe, so instead we capture
# docker's exit code from PIPESTATUS and exit with it explicitly so that
# systemd's Restart=on-failure triggers correctly.
#
# Flag notes:
#   --privileged        Full device access (RealSense USB, /dev/ttyTHS1, GPU).
#   --network host      ROS2 DDS discovery needs host networking.
#   --ipc=host          Shared memory for zero-copy NITROS transfers.
#   --pid=host          Required for tegrastats and Jetson power APIs.
#   --runtime nvidia    Enables GPU/CUDA via the NVIDIA container runtime.
#   -v /dev/:/dev/      All host devices (replaces the per-device -v flags).
#   workspace-entrypoint.sh
#                       Upstream Isaac ROS entrypoint: creates 'admin' user
#                       matching HOST_USER_UID/GID, adds it to dialout
#                       (patched by Dockerfile.thornbots), restarts udev.
#                       Ends with: exec gosu admin <LAUNCH_CMD>

{
    echo "[thornbots] Service started at $(date)"
    set +e
    docker run \
        --name thornbots-runtime \
        --privileged \
        --network host \
        --ipc=host \
        --pid=host \
        --runtime nvidia \
        -e NVIDIA_VISIBLE_DEVICES="nvidia.com/gpu=all,nvidia.com/pva=all" \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -e ISAAC_ROS_WS="${CONTAINER_WS}" \
        -e USERNAME=admin \
        -e HOST_USER_UID="${HOST_USER_UID}" \
        -e HOST_USER_GID="${HOST_USER_GID}" \
        -v "${ISAAC_ROS_WS_HOST}:${CONTAINER_WS}" \
        -v "${SNAPSHOT_OUTPUT_HOST}:${CONTAINER_SNAPSHOT}" \
        -v /tmp/:/tmp/ \
        -v /etc/localtime:/etc/localtime:ro \
        -v /usr/bin/tegrastats:/usr/bin/tegrastats \
        -v /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra \
        -v /usr/src/jetson_multimedia_api:/usr/src/jetson_multimedia_api \
        -v /usr/share/vpi3:/usr/share/vpi3 \
        -v /dev/:/dev/ \
        --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
        "${THORNBOTS_IMAGE}" \
        /bin/bash -c "${LAUNCH_CMD}"
    _exit="${PIPESTATUS[0]}"
    set -e
    echo "[thornbots] Container exited with code ${_exit} at $(date)"
    exit "$_exit"
} 2>&1 | tee -a "$LOG_FILE"