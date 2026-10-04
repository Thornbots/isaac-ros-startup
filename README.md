# isaac-ros-startup

Starts the robot stack at boot: a systemd service that runs our Isaac ROS
image (ROS 2 Jazzy, JetPack 7.2.1) with `thornbots_pkg`'s `auto.launch.py`
and the YOLO launch from `realsense-yolov8-nitros-bridge`. The Humble
version is on the `humble` branch.

## Install

Build the image once, on wall power, with
`isaac_ros_common/scripts/build_robot_image.sh` (see
`isaac_ros_common/docker/README.md`), then:

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
| Watch live | `ENABLE_FOXGLOVE=true` in `launch.env`, then Foxglove → `ws://<robot IP>:8765` (read-only) |
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

The first start after boot skips the RealSense USB reset (about 5 s,
`camera_initial_reset:=False`); a restart in the same boot does the reset,
in case the camera is what failed. `/run/thornbots-started` marks it.

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
restarts the whole stack. Stopping signals every background job's process
group (SIGINT, then SIGKILL after `STOP_TIMEOUT_S`, default 8 s), so a node
that ignores SIGINT can't keep the container, and the restart, hanging.

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

**Clock steps restart the stack.** A wall-clock step mid-run breaks every
node's stamps: on the sentry (2026-10-03) the camera's
`component_container_mt` aborted (`cannot store a negative time point in
rclcpp::Time`), and on 2026-10-01 a 50 s step took amcl down without
crashing anything. Two steps happen at boot. The sentry's `rtc0`
(`nvvrs-pseq-rtc`) has no battery and loads as a module ~10 s in; as the
kernel's hctosys RTC it then sets the clock to 1970, undoing timesyncd's
restore of its saved time. So `thornbots-start.sh` waits for that (up to
20 s uptime) and restores the saved time itself before `docker run`. The
second is NTP's first sync once Wi-Fi is up, at boot or mid-match, by
however stale the clock is. So the script stops `systemd-timesyncd` for
the run, and the unit's `ExecStopPost` starts it again: the clock syncs
between runs, never under one. A run started air-gapped keeps the
restored time, off by however long the robot was off. The script saves
the time every 60 s as timesyncd would (`touch` on its clock file), so
the next boot restores it. A watcher compares wall time to
`/proc/uptime` every second; on a step over 1 s anyway it stops the
container and exits 75, so systemd restarts the stack. Run by hand, the
script leaves timesyncd stopped: `sudo systemctl start systemd-timesyncd`.

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
opens the `.mcap` files without it). The recorder is stopped with SIGINT
(`env --default-signal=INT` undoes the ignore a background job of a
non-interactive shell starts with). It isn't watched: if it dies, the stack keeps running.
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
