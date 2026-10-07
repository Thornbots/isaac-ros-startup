# isaac-ros-startup

Boot service for the robot stack, a submodule of `thornbots_workspace` on
`main` (Jazzy). `humble` is the frozen Humble version.

## Deployment and validation

Current machine state and robot acceptance checks live in
[Hardware status](../JAZZY_FLASH.md#hardware-status). The dated observations
below are historical; a service starting does not validate the robot stack.

## Service observations and open checks

- Running on `ts-nano-sentry` since 2026-10-01: kernel start to both
  launches up in 17.6 s, engine loaded about 4 s later. Goal:
  power-on to a running stack under 1 min
  (ROADMAP track C).
- Per-run MCAP bag and ROS node logs run on the sentry (2026-10-03),
  JPEG colour video included (~8.5 GB/h). Pruning is untested on a robot.
- Sentry run00051 used `LOCALIZATION_MODE=mapping`, `USE_WS_OVERLAY=false`,
  `use_rf2o:=true` on image `8880173c` (2026-10-04). Old files:
  `launch.env.bak-*`.
- Clock (ROADMAP T27): saved time restored after `rtc0` hctosys,
  timesyncd stopped for each run (synced between runs), a restart on any
  step over 1 s anyway. Host side passes on `ts-nano-dev` with `docker`
  stubbed (2026-10-03). On the sentry, the RTC reset is caught and the
  saved time restored at 14.25 s (run00050, 2026-10-04). Left: no `[clock]` line and no restart when Wi-Fi
  comes up mid-run, `systemctl is-active systemd-timesyncd` inactive.
- A manual `date -s` on a synced robot lasts under 1 s: timesyncd sees
  the change and steps it back. Stop timesyncd to test the watcher.
- Open: a ROS process started in the running container after the stack
  (`docker exec`) discovers few or none of its nodes (2026-10-03).
  Read the bag instead.
- `thornbots-start.sh` regenerates `/var/run/cdi/nvidia.yaml` when its
  `/dev/nvhost-gpu` gid differs from the node's (CUDA err=100 for admin on
  the sentry, 2026-10-01). Untested: not yet run on a robot.
- Needs `RemoveIPC=no` (install.sh, README.md "RemoveIPC"). Without it an
  ssh logout breaks Fast DDS shared memory and the localization lifecycle.
- The first start after a new ONNX builds the TensorRT engine (141 s on
  the sentry). amcl dropped during that build too, put down to CPU at the
  time; RemoveIPC fits it better. Unretested with RemoveIPC=no.
- Each robot builds its own image (the user, 2026-10-03), on wall power:
  `isaac_ros_common/scripts/build_robot_image.sh` with no host args. 29 min
  on `ts-nano-dev` with its lower layers cached; ROADMAP T29 is cutting
  that. With no BuildKit cache (image pulled, not built) it recompiles
  librealsense once. The Mac's `build_robot_image.sh <robot>` (push, pull
  over `ssh -R`) is a stopgap. `thornbots-start.sh` picks the newest
  `isaac_ros-realsense-thornbots_<hash>-arm64-jetpack` tag.

## Rules

- Testing the service starts a container. Agents start or stop its
  container on a robot when the user asks, with no separate confirmation
  (`../CLAUDE.md` § Containers, the user, 2026-10-04).
- Keep the `docker run` flags in `thornbots-start.sh` in step with
  isaac-ros-cli's `run_dev.py` for aarch64.
- Commit here and push, then bump the gitlink in `../`.
