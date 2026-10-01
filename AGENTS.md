# isaac-ros-startup

Boot service for the robot stack, a submodule of `thornbots_workspace` on
`main` (Jazzy). `humble` is the frozen Humble version.

## Current state

- Running on `ts-nano-sentry` since 2026-10-01: kernel start to both
  launches up in 17.6 s, engine loaded about 4 s later. Not yet run on
  hero or standard. Goal: power-on to a running stack under 1 min
  (ROADMAP track C).
- The first start after a new ONNX builds the TensorRT engine (141 s on
  the sentry) and starves `map_server`'s heartbeat, so the lifecycle
  manager takes amcl down. Restart the service once the `.plan` exists.
- Open: the robot can't build its image on one battery. isaac-ros-cli
  checks layers with `docker manifest inspect` (registry only), so it
  recompiles librealsense over a base loaded with `docker load`. What
  worked: copy the realsense base to an arm64 Mac, build
  `Dockerfile.thornbots` there with `BASE_IMAGE` set to it, push to a
  `registry:2` on the Mac and `docker pull` it over an `ssh -R` tunnel
  (only new layers cross), then tag it
  `nvcr.io/nvidia/isaac/ros:isaac_ros-realsense-thornbots_<hash>-arm64-jetpack`.

## Rules

- Testing the service starts a container. Agents may start, stop and
  reboot-test it on `ts-nano-sentry` only (the user, 2026-09-30).
- Keep the `docker run` flags in `thornbots-start.sh` in step with
  isaac-ros-cli's `run_dev.py` for aarch64.
- Commit here and push, then bump the gitlink in `../`.
