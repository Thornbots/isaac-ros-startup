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
LAUNCH_CMD="source /opt/ros/humble/setup.bash \
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
