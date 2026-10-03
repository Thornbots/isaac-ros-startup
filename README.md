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
| Logs, per run | `$LOG_DIR/thornbots-run<N>.log`, newest at `$LOG_DIR/latest.log` |
| Bag and node logs, per run | `$LOG_DIR/thornbots-run<N>/bag/` (MCAP) and `ros/`, newest at `$LOG_DIR/latest/` |
| Read the bag | `ros2 bag info <dir>/bag`, or open its `.mcap` files in Foxglove |
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

**Logs survive a bad clock.** The Jetsons boot on the RTC's time, and NTP
can step it by a minute or more once Wi-Fi is up, after the stack has
started (sentry, 2026-10-01: back once, forward ~80 s the next boot). So
`log-stamp.py` prefixes every line with seconds since boot
(`CLOCK_BOOTTIME`, never stepped) and the wall time, marked `?` until NTP
syncs, and writes a `[clock]` line at the sync and any later step. ROS's own
per-line time (`{date_time_with_ms}`) steps with the clock. Files are named
by a run counter (`/var/lib/thornbots/run-count`), never the date, and sort
in run order; each starts with its boot ID, image and workspace commit. The file is fsynced every second,
because a battery pull is how most runs end.

**Per-run bag.** `thornbots-launch.sh` records one MCAP bag per run:
`/rosout` (every node's log, with severity, node and stamp as fields) and
the localization, lidar, referee and CV topics (`/cv/target` and
`/dji_serial_bridge/cv_target` included), and every colour frame as JPEG on
`/color/image_raw/compressed`. The RealSense node publishes raw only, so an
`image_transport republish` node encodes it (`VIDEO_JPEG_QUALITY`, default
80; `ENABLE_VIDEO=false` drops it). It is split
into 60 s files, written without a cache in 256 KiB zstd chunks
(`mcap-storage.yaml`), so a battery pull loses about a second. That bag has
no `metadata.yaml`; `ros2 bag reindex <dir>/bag -s mcap` rebuilds it (Foxglove
opens the `.mcap` files without it). The recorder is stopped with SIGTERM:
as a background job of a non-interactive shell it starts with SIGINT
ignored. It isn't watched: if it dies, the stack keeps running.
`ENABLE_BAG=false` turns it off.

**Pruning.** At each start, `thornbots-start.sh` deletes the oldest runs
(text log and directory) while the log disk has under `LOG_MIN_FREE_GB`
(20) free, always keeping the newest `LOG_KEEP_RUNS` (5).

**RemoveIPC.** The stack runs as the workspace owner's UID, the same one
you ssh in as. logind's default `RemoveIPC=yes` deletes that UID's
`/dev/shm` files 10 s after its last session ends, Fast DDS's shared-memory
segments included. Mapped segments keep working, but a sender opens a
receiver's port by name, so after the delete it writes to a new segment
nobody reads: nodes on the robot stop hearing each other without an error.
On the sentry (2026-10-01) the lifecycle manager then lost amcl's or
map_server's heartbeat in 6 of 7 runs, and never brought them back. install.sh
installs `logind-thornbots.conf` (`RemoveIPC=no`).

**Environment.** The image exports `ROS_DOMAIN_ID`, the Fast DDS profile
and `RMW_IMPLEMENTATION` from `/etc/bash.bashrc`, which a non-interactive
shell never reads, so `thornbots-launch.sh` sets them itself.
