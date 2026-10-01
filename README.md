# isaac-ros-startup

Starts the robot stack at boot: a systemd service that runs our Isaac ROS
image (ROS 2 Jazzy, JetPack 7.2.1) with `thornbots_pkg`'s `auto.launch.py`
and the YOLO launch from `realsense-yolov8-nitros-bridge`. The Humble
version is on the `humble` branch.

## Install

Build the image once with `isaac-ros activate --build-local` (see the
workspace README), then:

```bash
sudo bash install.sh            # or: --ws /path/to/isaac_ros-dev
sudo systemctl start thornbots
journalctl -u thornbots -f
```

`install.sh` copies the scripts to `/usr/local/lib/thornbots` and
`/usr/local/bin`, enables the unit, and writes `/etc/thornbots/launch.env`
from `launch.env` with the workspace, UID and GID filled in. It keeps an
existing `launch.env`; `--reset-config` rewrites it. Re-run it after
pulling changes here.

## Use

| | |
|---|---|
| Logs, live | `journalctl -u thornbots -f` |
| Logs, per run | `$LOG_DIR/thornbots-<date>.log`, never pruned |
| Restart after editing `launch.env` | `sudo systemctl restart thornbots` |
| Shell in the running stack | `docker exec -it -u admin thornbots-runtime bash` |
| Stop for development | `sudo systemctl stop thornbots` (and `disable` to keep it off across boots) |

Stop the service before `isaac-ros activate`: both want the camera, the
lidar and `/dev/ttyTHS1`.

The image bakes our packages into `/workspaces/ros2_ws`, and that is what
the service runs. To run a `colcon build` from the workspace instead, set
`USE_WS_OVERLAY=true`.

## Boot time

Each stage prints a `[boot] <uptime>s` line to the journal:

```bash
journalctl -b -u thornbots | grep '\[boot\]'
```

`thornbots-start.sh`, `docker run`, `container up`, `CUDA ready` and
`launches started` mark the stages. The first start without
`yolo11s_fp16.plan` builds the TensorRT engine from the ONNX, which takes
minutes; later starts load the saved engine.

## Design notes

**No `network-online.target`.** The robot runs air-gapped in a match, and
waiting for Wi-Fi costs boot time. Fast DDS picks its interfaces when a
participant starts, so nodes started before Wi-Fi or tailscale are up
aren't reachable from other machines until the service restarts.

**Why /host-dev.** `--privileged` gives the container a copy of `/dev` at
start. The lidar (CP210x) can re-enumerate mid-run, so it is read through
the host's live `/dev` mounted at `/host-dev`. Don't mount the host's
`/dev` over `/dev`: that shadows the NVIDIA runtime's CDI GPU devices, the
container user gets `cudaErrorNotSupported` (801) on its first CUDA call,
and NITROS segfaults. `cuda-probe.py` makes the same CUDA calls NITROS makes
and fails fast with the real error instead.

**Two launches, one container.** The YOLO launch's own serial bridge is off
(`enable_serial_bridge:=False`), because `auto.launch.py` starts
`dji_serial_bridge_node` on `/dev/ttyTHS1`. If either launch exits,
`thornbots-launch.sh` stops the other and the container exits, so systemd
restarts the whole stack.

**Environment.** The image exports `ROS_DOMAIN_ID`, the Fast DDS profile
and `RMW_IMPLEMENTATION` from `/etc/bash.bashrc`, which a non-interactive
shell never reads, so `thornbots-launch.sh` sets them itself.
