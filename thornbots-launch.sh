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
until out=$(/opt/thornbots-startup/cuda-probe 2>&1); do
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
# with the clock; log-stamp's uptime prefix doesn't.
export RCUTILS_CONSOLE_OUTPUT_FORMAT='[{severity}] [{date_time_with_ms}] [{name}]: {message}'
export RCUTILS_COLORIZED_OUTPUT=0
# Node log files and launch.log beside the run's text log, not in the
# container's ~/.ros, which --rm deletes.
RUN_DIR="${THORNBOTS_RUN_DIR:-/tmp/thornbots-run}"
export ROS_LOG_DIR="$RUN_DIR/ros"
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

# Background jobs of this non-interactive shell start with SIGINT ignored,
# and ros2 launch keeps it that way, so stop()'s SIGINT would never land.
# env restores the default before exec. setsid gives each job its own process
# group (pgid == the job's pid) so stop() can signal ros2 run's wrapper and the
# real binary under it together.
# shellcheck disable=SC2086  # *_LAUNCH_ARGS are space-separated name:=value lists
setsid env --default-signal=INT ros2 launch thornbots_pkg auto.launch.py \
    lidar_serial_port:="${LIDAR_SERIAL_DEVICE:-/host-dev/rplidar}" \
    localization_mode:="${LOCALIZATION_MODE:-mapping}" \
    center_weight:="${CENTER_WEIGHT:-1.0}" \
    priority_class_bonus:="${PRIORITY_CLASS_BONUS:-0.5}" \
    priority_class_ids:="${PRIORITY_CLASS_IDS:-[2,6]}" \
    ${AUTO_LAUNCH_ARGS:-} &
auto_pid=$!

# shellcheck disable=SC2086
setsid env --default-signal=INT ros2 launch realsense_yolov8_nitros_bridge isaac_ros_yolov8_realsense.launch.py \
    "${model_args[@]}" \
    num_classes:="${NUM_CLASSES:-8}" \
    confidence_threshold:="${CONFIDENCE_THRESHOLD:-0.25}" \
    nms_threshold:="${NMS_THRESHOLD:-0.45}" \
    enable_serial_bridge:=False \
    camera_initial_reset:="${CAMERA_INITIAL_RESET:-True}" \
    enable_snapshot:="${ENABLE_SNAPSHOT:-False}" \
    snapshot_output_dir:=/data/realsense-captures \
    ${YOLO_LAUNCH_ARGS:-} &
yolo_pid=$!
boot "launches started (auto $auto_pid, yolo $yolo_pid)"

# Every colour frame as JPEG on /color/image_raw/compressed, for the bag.
# The RealSense node publishes raw only (55 MB/s at 640x480x60).
video_pid=
if [[ "${ENABLE_BAG:-true}" == true && "${ENABLE_VIDEO:-true}" == true ]]; then
    setsid env --default-signal=INT ros2 run image_transport republish --ros-args \
        -r __node:=video_republisher \
        -p in_transport:=raw -p out_transport:=compressed \
        -p out.compressed.jpeg_quality:="${VIDEO_JPEG_QUALITY:-80}" \
        -r in:=/color/image_raw -r out/compressed:=/color/image_raw/compressed &
    video_pid=$!
fi

# Read-only Foxglove websocket on FOXGLOVE_PORT: viewers can't publish, call
# services or set parameters. Started with the stack, so it sees every node.
foxglove_pid=
if [[ "${ENABLE_FOXGLOVE:-false}" == true ]]; then
    if ros2 pkg prefix foxglove_bridge >/dev/null 2>&1; then
        setsid env --default-signal=INT ros2 run foxglove_bridge foxglove_bridge --ros-args \
            -p port:="${FOXGLOVE_PORT:-8765}" -p address:=0.0.0.0 \
            -p "capabilities:=[connectionGraph, assets]" &
        foxglove_pid=$!
        boot "foxglove bridge on :${FOXGLOVE_PORT:-8765} (pid $foxglove_pid)"
    else
        echo "[thornbots] ENABLE_FOXGLOVE=true but foxglove_bridge isn't in this image" >&2
    fi
fi

# One MCAP bag per run: /rosout, the colour video (above) and what judging
# localization and CV after a match needs. No cache and small chunks
# (mcap-storage.yaml), so a battery pull loses about a second. Not watched
# below: a recorder failure must not stop the robot.
bag_topics=(
    /rosout /diagnostics /tf /tf_static /map
    /scan /scan_odom /scan_odom/quality /odom /pose /amcl_pose
    /localization/odom /localization/map_odom
    /dji_serial_bridge/pose /dji_serial_bridge/ref_sys /dji_serial_bridge/relocalize
    /dji_serial_bridge/cv_target
    /detections_output /cv/panel_detections /cv/panel_detection
    /cv/robot_panels /cv/panel_polygon /cv/target_state /cv/target
    /cv/tracker/measurement
)
[[ -n "$video_pid" ]] && bag_topics+=(/color/image_raw/compressed /color/camera_info)
bag_pid=
if [[ "${ENABLE_BAG:-true}" == true ]]; then
    setsid env --default-signal=INT ros2 bag record -s mcap \
        --storage-config-file /opt/thornbots-startup/mcap-storage.yaml \
        --max-bag-duration 60 --max-cache-size 0 \
        -o "$RUN_DIR/bag" --topics "${bag_topics[@]}" &
    bag_pid=$!
    boot "bag recording to $RUN_DIR/bag (pid $bag_pid)"
fi

# docker stop sends SIGTERM here; ros2 launch and the recorder shut down
# cleanly on SIGINT. Each job's whole group gets SIGINT, then SIGKILL after
# STOP_TIMEOUT_S: a node ignoring SIGINT must not keep the container alive,
# or systemd never restarts it. Group signals go to the pgid, not the pid.
STOP_TIMEOUT_S="${STOP_TIMEOUT_S:-8}"
stop() {
    local pids=() p i
    for p in "$auto_pid" "$yolo_pid" "$bag_pid" "$video_pid" "$foxglove_pid"; do
        [[ -n "$p" ]] && pids+=("$p")
    done
    for p in "${pids[@]}"; do kill -INT -- "-$p" 2>/dev/null; done
    for (( i = 0; i < STOP_TIMEOUT_S * 10; i++ )); do
        sleep 0.1
        for p in "${pids[@]}"; do
            kill -0 -- "-$p" 2>/dev/null && continue 2
        done
        break
    done
    for p in "${pids[@]}"; do
        if kill -0 -- "-$p" 2>/dev/null; then
            echo "[thornbots] group $p ignored SIGINT for ${STOP_TIMEOUT_S}s; SIGKILL" >&2
            kill -KILL -- "-$p" 2>/dev/null
        fi
    done
    wait
}
trap 'trap "" TERM INT; stop; exit 0' TERM INT
wait -n "$auto_pid" "$yolo_pid"
rc=$?
echo "[thornbots] a launch exited ($rc); stopping the other"
stop
exit $(( rc == 0 ? 1 : rc ))
