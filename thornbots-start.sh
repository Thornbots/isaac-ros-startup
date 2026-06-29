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
# workspace-entrypoint.sh restarts udev before handing off to LAUNCH_CMD.
# On Jetson Orin this can leave the CUDA subsystem in an inconsistent state.
# If NITROS starts too soon, cudaMemPoolCreate returns cudaErrorNotSupported
# → GXF dereferences a null pool handle → SIGSEGV.
#
# We originally tried calling cuInit(0) via python3+ctypes, but libcuda.so.1
# depends on Tegra-specific libraries (libnvrm_gpu.so, libnvos.so, etc.) that
# are bind-mounted at container runtime AFTER the image's ldconfig cache was
# built, so ctypes can never resolve them regardless of the path given.
#
# The reliable alternative: check for the three device nodes that together
# mean the full CUDA subsystem is enumerated and memory allocation will work,
# without needing to load any library at all:
#
#   /dev/nvhost-gpu       — CUDA compute engine
#   /dev/nvmap            — Tegra memory manager  (needed for cudaMalloc)
#   /dev/nvhost-ctrl-gpu  — GPU control channel   (needed for context mgmt)
#
# All three are visible inside the container via -v /dev/:/dev/.
cat > /tmp/thornbots-cuda-probe.sh << 'PROBE'
#!/bin/bash
# Called from LAUNCH_CMD inside the container, before sourcing ROS.

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

# Stage 1: CUDA compute engine (usually instant after udev restart)
_wait "/dev/nvhost-gpu" "[ -e /dev/nvhost-gpu ]"

# Stage 2: memory manager + GPU control channel — these lag slightly behind
# nvhost-gpu and are the specific devices used by cudaMalloc / cudaMemPoolCreate.
# Waiting for all three gives a stronger guarantee than nvhost-gpu alone, and
# avoids the library-loading issues of the cuInit/ctypes approach.
_wait "CUDA memory devices" "[ -e /dev/nvmap ] && [ -e /dev/nvhost-ctrl-gpu ]"

# Stage 3: fast-fail guard.  Verify the exact runtime-API calls NITROS makes
# (cudaGetDeviceCount -> cudaFree(0) -> cudaDeviceGetDefaultMemPool ->
# cudaMemPoolSetAttribute) actually succeed AS THIS USER before launching.  If
# they don't, NITROS would otherwise segfault on a null CUDA mem-pool handle
# (exit -11) with no usable error; here we surface the real cudaError instead.
#
# The classic failure this catches: the GPU device nodes are present but CUDA
# returns cudaErrorNotSupported (801) on the first call — which on this stack
# means the container's /dev shadowed the NVIDIA runtime's CDI GPU injection
# (e.g. someone re-added `-v /dev:/dev`), leaving nvgpu nodes only root can use.
# A short retry covers a genuine cold-boot readiness race; a persistent failure
# is a misconfiguration, so we exit fast and let systemd restart/log it.
sudo ldconfig 2>/dev/null || true
_n=0; _timeout=20
until _out="$(python3 /tmp/thornbots-mempool-probe.py 2>&1)"; do
    _rc=$?
    _n=$((_n + 2))
    if (( _n > _timeout )); then
        echo "[thornbots] ERROR: CUDA not usable after ${_timeout}s (${_out}, rc=${_rc})." >&2
        echo "[thornbots]        err=801 here usually means /dev shadowed the CDI GPU injection." >&2
        exit 1
    fi
    echo "[thornbots] CUDA not ready yet (${_out}, rc=${_rc}); retrying (${_n}s elapsed)..."
    sleep 2
done
echo "[thornbots] CUDA ready (${_out}) — launching."
PROBE
chmod +x /tmp/thornbots-cuda-probe.sh

# ── CUDA memory-pool probe (mirrors NITROS setCUDAMemoryPoolSize) ────────────
# Uses the CUDA *runtime* API via libcudart, which is baked into the image and
# resolves cleanly — unlike libcuda.so.1 (driver API), whose Tegra deps are
# bind-mounted after the image's ldconfig cache was built and defeated the
# earlier cuInit/ctypes approach.  Exit codes identify which call failed.
cat > /tmp/thornbots-mempool-probe.py << 'PYEOF'
import ctypes, sys

_loaded = None
rt = None
for _name in ("libcudart.so", "libcudart.so.12", "libcudart.so.11.0",
              "/usr/local/cuda/lib64/libcudart.so"):
    try:
        rt = ctypes.CDLL(_name)
        _loaded = _name
        break
    except OSError:
        continue
if rt is None:
    print("NO_CUDART"); sys.exit(2)

# Decode CUDA error codes into human-readable strings for the journal.
rt.cudaGetErrorString.restype = ctypes.c_char_p
rt.cudaGetErrorString.argtypes = [ctypes.c_int]
def estr(code):
    try:
        return rt.cudaGetErrorString(code).decode()
    except Exception:
        return "?"

def fail(stage, code):
    # cudaGetLastError clears the sticky error so a retry starts clean.
    try: rt.cudaGetLastError()
    except Exception: pass
    print("%s err=%d(%s) lib=%s" % (stage, code, estr(code), _loaded))

# Version / device sanity (does the runtime even see a GPU?).
drv = ctypes.c_int(-1); run = ctypes.c_int(-1); ndev = ctypes.c_int(-1)
rt.cudaDriverGetVersion(ctypes.byref(drv))
rt.cudaRuntimeGetVersion(ctypes.byref(run))
rc = rt.cudaGetDeviceCount(ctypes.byref(ndev))
if rc != 0:
    fail("DEVICE_COUNT_FAIL drv=%d run=%d" % (drv.value, run.value), rc)
    sys.exit(6)

# cudaFree(0) forces primary-context init (the first thing that touches the GPU).
rc = rt.cudaFree(ctypes.c_void_p(0))
if rc != 0:
    fail("CTX_INIT_FAIL drv=%d run=%d ndev=%d" % (drv.value, run.value, ndev.value), rc)
    sys.exit(3)

# cudaDeviceGetDefaultMemPool(&pool, device=0)
pool = ctypes.c_void_p()
rc = rt.cudaDeviceGetDefaultMemPool(ctypes.byref(pool), 0)
if rc != 0:
    fail("GET_POOL_FAIL", rc); sys.exit(4)

# cudaMemPoolSetAttribute(pool, cudaMemPoolAttrReleaseThreshold=4, &threshold)
# This is the exact call that returns cudaErrorNotSupported in NITROS.
val = ctypes.c_uint64(1 << 30)
rc = rt.cudaMemPoolSetAttribute(pool, 4, ctypes.byref(val))
if rc != 0:
    fail("SET_ATTR_FAIL", rc); sys.exit(5)

print("OK drv=%d run=%d ndev=%d lib=%s" % (drv.value, run.value, ndev.value, _loaded))
sys.exit(0)
PYEOF

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
#   -v /dev:/host-dev   Live bind of the host's /dev for USB hotplug recovery
#                       (e.g. CP210x ttyUSB* re-enumerating mid-run).  We do
#                       NOT bind it over /dev: doing so shadows the NVIDIA
#                       runtime's CDI GPU-device injection, and the resulting
#                       host-presented nvgpu nodes are only usable by root —
#                       the non-root 'admin' user then gets cudaErrorNotSupported
#                       (801) on the first CUDA call and NITROS segfaults.
#                       Keeping /dev as the CDI-managed one lets admin use CUDA;
#                       consumers of hotplugging devices read them via /host-dev.
#   --device /dev/ttyTHS1
#                       Pin the on-chip UART at its normal path (it does not
#                       hotplug, so a fixed node is correct and keeps its path
#                       stable for the dji_serial_bridge).
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
        -v /dev:/host-dev \
        --device /dev/ttyTHS1 \
        --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
        "${THORNBOTS_IMAGE}" \
        /bin/bash -c "${LAUNCH_CMD}"
    _exit="${PIPESTATUS[0]}"
    set -e
    echo "[thornbots] Container exited with code ${_exit} at $(date)"
    exit "$_exit"
} 2>&1 | tee -a "$LOG_FILE"