# isaac-ros-startup

Boot service for the robot stack, a submodule of `thornbots_workspace` on
`main` (Jazzy). `humble` is the frozen Humble version.

## Current state

- Running on `ts-nano-sentry` since 2026-10-01: kernel start to both
  launches up in 17.6 s, engine loaded about 4 s later. Not yet run on
  hero or standard. Goal: power-on to a running stack under 1 min
  (ROADMAP track C).
- Per-run MCAP bag, ROS node logs and pruning (README.md "Per-run
  bag") are tested only in the Mac dev container, not yet on a robot.
  Open: does the robot image ship `rosbag2_storage_mcap`? A missing
  recorder only logs an error; the stack runs on.
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
