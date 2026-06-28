# isaac-ros-startup

Scripts to configure Isaac ROS launch for systemd autostart.

Per-machine values — workspace path, UID, GID — are **auto-detected** so the
same repo works across Jetsons with different usernames and workspace locations.

## Install

### Automatic (recommended)

Run `install.sh` as root. It scans the system for Isaac ROS workspaces,
detects the owner's UID/GID, and writes a fully populated config for this machine.

```bash
sudo bash install.sh
```

If it finds multiple workspaces it will prompt you to choose one.
You can also target a specific user or path directly:

```bash
sudo bash install.sh --user alice
sudo bash install.sh --ws /data/isaac_ros-dev
```

Then start the service:

```bash
sudo systemctl start thornbots
```

### Manual

If you prefer to set values by hand:

```bash
# 1. Write config
sudo mkdir -p /etc/thornbots
sudo cp launch.env /etc/thornbots/launch.env
sudo nano /etc/thornbots/launch.env   # set ISAAC_ROS_WS_HOST (and optionally HOST_USER_UID/GID)

# 2. Install the start script
sudo cp thornbots-start.sh /usr/local/bin/thornbots-start.sh
sudo chmod +x /usr/local/bin/thornbots-start.sh

# 3. Install and enable the service
sudo cp thornbots.service /etc/systemd/system/thornbots.service
sudo systemctl daemon-reload
sudo systemctl enable thornbots
sudo systemctl start thornbots
```

> **Tip:** leaving `ISAAC_ROS_WS_HOST`, `HOST_USER_UID`, and `HOST_USER_GID`
> blank in `launch.env` tells `thornbots-start.sh` to auto-detect them at
> boot — so even the manual path can be zero-config.

## Re-configure a machine

Just re-run the installer:

```bash
sudo bash install.sh
sudo systemctl restart thornbots
```

## Usage

#### Watch logs live
```bash
journalctl -u thornbots -f
```

#### Any time docker is updated
```bash
sudo systemctl restart thornbots
```

#### After editing launch.env
```bash
sudo systemctl daemon-reload && sudo systemctl restart thornbots
```

## How auto-detection works

`thornbots-start.sh` runs this logic at boot when `ISAAC_ROS_WS_HOST` is blank:

1. **Glob scan** — checks `~/workspaces/isaac_ros-dev` under every home directory (covers the Isaac ROS default location regardless of username).
2. **Shell config parse** — if nothing is found, reads `ISAAC_ROS_WS=` from each user's `.bashrc` / `.bash_profile` / `.profile` / `.zshrc`, expanding `$HOME` correctly per owner.

`HOST_USER_UID` and `HOST_USER_GID` are auto-detected from `stat` on the
discovered workspace directory, so the container's `admin` user always matches
the file owner regardless of which UID the Jetson was set up with.
