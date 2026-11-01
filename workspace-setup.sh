#!/usr/bin/env bash
# Source only this overlay, rejecting accidental resolution to the baked tree.
thornbots_source_overlay() {
    local workspace="$1" package prefix
    [[ -f "$workspace/install/local_setup.bash" ]] || {
        echo "ERROR: robot overlay missing at $workspace/install" >&2; return 1; }
    # local_setup avoids replaying an underlay captured by an earlier build.
    # shellcheck source=/dev/null
    source "$workspace/install/local_setup.bash" || return 1
    for package in sllidar_ros2 dji_serial_bridge roi_depth_query rf2o_laser_odometry \
        sentry_localization thornbots_pkg realsense_yolov8_nitros_bridge; do
        prefix=$(ros2 pkg prefix "$package") || return 1
        case "$prefix" in
            "$workspace/install/"*) ;;
            *) echo "ERROR: $package resolves outside robot overlay: $prefix" >&2; return 1 ;;
        esac
    done
}
