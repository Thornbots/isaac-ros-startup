# isaac-ros-startup

Boot service for the robot stack, a submodule of `thornbots_workspace` on
`main` (Jazzy). `humble` is the frozen Humble version.

## Current state

- Jazzy port written 2026-09-30, not yet run on hardware. First target:
  `ts-nano-sentry`.
- Boot-time goal: power-on to a running stack under 1 min (ROADMAP track C).

## Rules

- Testing the service starts a container. Agents may start, stop and
  reboot-test it on `ts-nano-sentry` only (the user, 2026-09-30).
- Keep the `docker run` flags in `thornbots-start.sh` in step with
  isaac-ros-cli's `run_dev.py` for aarch64.
- Commit here and push, then bump the gitlink in `../`.
