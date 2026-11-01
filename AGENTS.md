# isaac-ros-startup

Follow [workspace rules](../AGENTS.md) and [CI](../docs/CI.md).
Read [installation](README.md#install) and [design](README.md#design-notes)
before changing the boot service. Acceptance: [ROADMAP](../docs/ROADMAP.md#later-needs-a-robot).

## Rules

- Host helpers are C++17; keep CUDA loading dynamic so installation needs no SDK.
- Keep `thornbots-start.sh` container flags aligned with aarch64
  isaac-ros-cli `run_dev.py`. Testing the service starts a container;
  [lifecycle permissions](../AGENTS.md#containers-and-runs) apply.
- Use the [registry base and robot overlay](../isaac_ros_common/docker/README.md#building-the-robots-image);
  local image builds are a recovery fallback.

## Open

- Hardware acceptance still needs a real GPU-failure recovery, log pruning,
  and Wi-Fi coming up during a run without a clock step/restart.
- Stop timesyncd before a manual clock-step watcher test; it otherwise restores
  synced time immediately.
- Processes attached to an already-running stack can miss DDS nodes; read the
  bag when discovery is incomplete. Investigation is still open.
- Do not disable `nv-tee-supplicant`: GPU firmware loading depends on it.
