#!/bin/bash
# /usr/local/bin/thornbots-start.sh
#
# Production launcher for the Thornbots Isaac ROS vision pipeline.
# Intended to be called by thornbots.service, NOT run_dev.sh.
#
# What run_dev.sh does that we deliberately skip here:
#   - Image rebuild (handled separately when code changes)
#   - Interactive terminal (-it)
#   - git-lfs checks
#
# Execution chain:
#   systemd → this script → docker run
#     → workspace-entrypoint.sh  (patches admin user, adds dialout, restarts udev)
#     → exec gosu admin /bin/bash (non-interactive, sources ROS, runs ros2 launch)
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
# Runs only when the field is blank in launch.env.
if [[ -z "${ISAAC_ROS_WS_HOST:-}" ]]; then
    echo "ISAAC_ROS_WS_HOST not set — auto-discovering..."
    _discovered=""

    # Strategy 1: standard Isaac ROS default location under any home directory
    #   Matches: /home/<any-user>/workspaces/isaac_ros-dev
    for _candidate in /home/*/workspaces/isaac_ros-dev /root/workspaces/isaac_ros-dev; do
        if [[ -d "$_candidate" ]]; then
            _discovered="$_candidate"
            break
        fi
    done

    # Strategy 2: parse ISAAC_ROS_WS= from each user's shell config files.
    # Handles non-standard workspace locations and all common config names.
    if [[ -z "$_discovered" ]]; then
        while IFS= read -r _cfg; do
            [[ -f "$_cfg" ]] || continue

            # Extract the assigned value, stripping quotes and 'export' prefix.
            _ws=$(grep -E '^\s*(export\s+)?ISAAC_ROS_WS=' "$_cfg" 2>/dev/null \
                  | head -1 \
                  | sed "s|.*ISAAC_ROS_WS=[\"']*||; s|[\"' \t].*||")
            [[ -z "$_ws" ]] && continue

            # Expand $HOME / ~ using the actual home dir of the file's owner.
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

# ── Create snapshot output dir if needed ────────────────────────────────────
mkdir -p "$SNAPSHOT_OUTPUT_HOST"

# ── CUDA readiness probe ─────────────────────────────────────────────────────
# workspace-entrypoint.sh always restarts udev inside the container before
# handing off to our LAUNCH_CMD. On Jetson that restart temporarily disrupts
# the CUDA subsystem. If the ROS pipeline starts immediately afterwards (as it
# does under systemd — no user "think time"), NitrosContext calls
# cudaMemPoolCreate before the driver has re-stabilized, which produces:
#
#   [NitrosContext]: cudaErrorNotSupported (operation not supported)
#   [NitrosContext]: setCUDAMemoryPoolSize Error: GXF_FAILURE
#
# GXF then dereferences the invalid pool handle → SIGSEGV (exit code -11).
# The crash never appeared in interactive runs because the user waited minutes
# after boot before typing the command, giving CUDA time to recover.
#
# Fix: write a small probe script to /tmp/ on the host before the container
# starts. The existing -v /tmp/:/tmp/ bind-mount makes it visible inside the
# container at the same path, so LAUNCH_CMD can call it without any quoting
# complications. The probe polls nvidia-smi (available on JetPack 5+/6) until
# the driver reports healthy, then sleeps 3 s for memory-pool settling.
cat > /tmp/thornbots-cuda-probe.sh << 'PROBE'
#!/bin/bash
# Called from LAUNCH_CMD before sourcing ROS.
# Waits for the CUDA driver to stabilize after workspace-entrypoint.sh
# restarts udev, then adds a short settle pause for memory-pool init.
_n=0
until nvidia-smi > /dev/null 2>&1; do
    _n=$((_n + 2))
    if (( _n >= 60 )); then
        echo "[thornbots] ERROR: GPU did not become ready within 60 s — aborting." >&2
        exit 1
    fi
    echo "[thornbots] Waiting for GPU to stabilize after udev restart (${_n}s elapsed)..."
    sleep 2
done
echo "[thornbots] GPU ready — settling 3 s for CUDA memory-pool initialisation..."
sleep 3
PROBE
chmod +x /tmp/thornbots-cuda-probe.sh

# ── Container-side paths ────────────────────────────────────────────────────
# The host workspace is always mounted at /workspaces/isaac_ros-dev inside
# the container, matching what run_dev.sh does.
CONTAINER_WS=/workspaces/isaac_ros-dev
CONTAINER_MODEL="${CONTAINER_WS}/${MODEL_REL_PATH}"
CONTAINER_SNAPSHOT=/data/realsense-captures

# The Thornbots packages are built into the image at build time (not in the
# mounted host workspace), so we source from the image's own ROS workspace.
CONTAINER_ROS_WS=/workspaces/ros2_ws

# ── Build the ros2 launch command that runs inside the container ─────────────
# This runs as 'admin' (via gosu in workspace-entrypoint.sh).
# We source ROS explicitly because bash runs non-interactively here
# (/etc/bash.bashrc is only sourced for interactive shells).
# The probe script runs first to ensure CUDA is stable (see comment above).
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

# ── docker run ──────────────────────────────────────────────────────────────
# Notes on flags:
#   --privileged        Full device access (RealSense USB, /dev/ttyTHS1, GPU).
#                       Mirrors what run_dev.sh does on aarch64.
#   --network host      ROS2 DDS discovery needs host networking.
#   --ipc=host          Shared memory for zero-copy NITROS transfers.
#   --pid=host          Required for tegrastats and some Jetson power APIs.
#   --runtime nvidia    Enables GPU/CUDA access via the NVIDIA container runtime.
#   -e NVIDIA_VISIBLE_DEVICES / NVIDIA_DRIVER_CAPABILITIES
#                       Exposes GPU and all hardware accelerators (PVA etc.).
#   workspace-entrypoint.sh
#                       Isaac ROS's own entrypoint: creates the 'admin' user
#                       matching HOST_USER_UID/GID, adds it to dialout
#                       (so /dev/ttyTHS1 is accessible), and restarts udev.
#                       It then calls: exec gosu admin <our /bin/bash -c cmd>
#
# We use 'exec' so docker becomes the direct child of systemd — clean SIGTERM
# propagation and accurate "is it running" tracking.

exec docker run \
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