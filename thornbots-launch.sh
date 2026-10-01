#!/bin/bash
# thornbots-launch.sh: runs inside the container as admin (thornbots-start.sh
# mounts it at /opt/thornbots-startup). Waits for CUDA, sources ROS, then runs
# thornbots_pkg's auto.launch.py and the YOLO launch side by side. If either
# exits, the other is stopped and the container exits, so systemd restarts it.
# The YOLO launch's serial bridge is off: auto.launch.py owns /dev/ttyTHS1.
set -uo pipefail

boot() { echo "[boot] $(cut -d' ' -f1 /proc/uptime)s $*"; }
boot "container up"

n=0
until out=$(python3 /opt/thornbots-startup/cuda-probe.py 2>&1); do
    n=$((n + 1))
    if (( n > 10 )); then
        echo "[thornbots] ERROR: CUDA not usable ($out)." >&2
        echo "[thornbots] err=801 usually means /dev shadowed the CDI GPU devices." >&2
        exit 1
    fi
    echo "[thornbots] CUDA not ready ($out); retry $n"
    sleep 2
done
boot "CUDA ready ($out)"

# /etc/bash.bashrc sets these for interactive shells only.
export FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/profile.xml
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
# Readable node-side times and no ANSI colour in the logs. These times step
# with the clock; log-stamp.py's uptime prefix doesn't.
export RCUTILS_CONSOLE_OUTPUT_FORMAT='[{severity}] [{date_time_with_ms}] [{name}]: {message}'
export RCUTILS_COLORIZED_OUTPUT=0
# ROS setup scripts read unset variables, so -u is off while they run.
set +u
source /opt/ros/jazzy/setup.bash
source /workspaces/ros2_ws/install/setup.bash
if [[ "${USE_WS_OVERLAY:-false}" == true && -f "$ISAAC_ROS_WS/install/setup.bash" ]]; then
    source "$ISAAC_ROS_WS/install/setup.bash"
fi
set -u
echo "[thornbots] thornbots_pkg from $(ros2 pkg prefix thornbots_pkg)"

model_args=(engine_file_path:="$ENGINE_PATH")
[[ -f "$ENGINE_PATH" ]] || model_args+=(model_file_path:="$ONNX_PATH")

# shellcheck disable=SC2086  # *_LAUNCH_ARGS are space-separated name:=value lists
ros2 launch thornbots_pkg auto.launch.py \
    lidar_serial_port:="${LIDAR_SERIAL_DEVICE:-/host-dev/rplidar}" \
    localization_mode:="${LOCALIZATION_MODE:-amcl}" \
    center_weight:="${CENTER_WEIGHT:-1.0}" \
    priority_class_bonus:="${PRIORITY_CLASS_BONUS:-0.5}" \
    priority_class_ids:="${PRIORITY_CLASS_IDS:-[2,6]}" \
    ${AUTO_LAUNCH_ARGS:-} &
auto_pid=$!

# shellcheck disable=SC2086
ros2 launch realsense_yolov8_nitros_bridge isaac_ros_yolov8_realsense.launch.py \
    "${model_args[@]}" \
    num_classes:="${NUM_CLASSES:-8}" \
    confidence_threshold:="${CONFIDENCE_THRESHOLD:-0.25}" \
    nms_threshold:="${NMS_THRESHOLD:-0.45}" \
    enable_serial_bridge:=False \
    enable_snapshot:="${ENABLE_SNAPSHOT:-False}" \
    snapshot_output_dir:=/data/realsense-captures \
    ${YOLO_LAUNCH_ARGS:-} &
yolo_pid=$!
boot "launches started (auto $auto_pid, yolo $yolo_pid)"

# docker stop sends SIGTERM here; ros2 launch shuts down cleanly on SIGINT.
stop() { kill -INT "$auto_pid" "$yolo_pid" 2>/dev/null; wait; }
trap 'stop; exit 0' TERM INT
wait -n "$auto_pid" "$yolo_pid"
rc=$?
echo "[thornbots] a launch exited ($rc); stopping the other"
stop
exit $(( rc == 0 ? 1 : rc ))
