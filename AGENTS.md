# isaac-ros-startup

Boot service for the robot stack, a submodule of `thornbots_workspace` on
`main` (Jazzy). `humble` is the frozen Humble version.

## Current state

- Running on `ts-nano-sentry` since 2026-10-01: kernel start to both
  launches up in 17.6 s, engine loaded about 4 s later. Not yet run on
  hero or standard. Goal: power-on to a running stack under 1 min
  (ROADMAP track C).
- Per-run MCAP bag and ROS node logs run on the sentry (2026-10-03),
  JPEG colour video included (~8.5 GB/h). Pruning is untested on a robot.
- The sentry's `/etc/thornbots/launch.env` has `LOCALIZATION_MODE=none`
  (2026-10-03) to dodge the `/pose` type clash (ROADMAP T26) until it's
  fixed, and `AUTO_LAUNCH_ARGS=use_rf2o:=false` (rf2o ran away to 265 m
  at boot while the robot stood still). Old files: `launch.env.bak-*`.
- Clock fixes (ROADMAP T27) untested on a robot: restore of timesyncd's
  saved time after `rtc0` hctosys, and a restart on any wall-clock step
  over 1 s. Check on the next sentry boot with Wi-Fi: one `[clock] wall
  clock stepped` line, one restart, no `negative time point` abort.
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
- The robot can't build its image on one battery: isaac-ros-cli checks
  layers with `docker manifest inspect` (registry only), so it recompiles
  librealsense over a base loaded with `docker load`. Build it on the Mac
  with `isaac_ros_common/scripts/build_robot_image.sh <robot>`, which
  pushes to a registry on the Mac and pulls over `ssh -R` (only new layers
  cross). `thornbots-start.sh` picks the newest
  `isaac_ros-realsense-thornbots_<hash>-arm64-jetpack` tag.

## Rules

- Testing the service starts a container. Agents test it on
  `ts-nano-sentry` only, and ask before each start, stop or reboot
  (`../CLAUDE.md` § Containers, the user, 2026-10-01).
- Keep the `docker run` flags in `thornbots-start.sh` in step with
  isaac-ros-cli's `run_dev.py` for aarch64.
- Commit here and push, then bump the gitlink in `../`.
