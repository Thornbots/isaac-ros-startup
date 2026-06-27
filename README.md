# isaac-ros-startup
Scripts to configure isaac ros launch for systemd autostart


# Install
### 1. Edit the config for your paths
``` bash
sudo mkdir -p /etc/thornbots
sudo cp launch.env /etc/thornbots/launch.env
sudo nano /etc/thornbots/launch.env        # set ISAAC_ROS_WS_HOST and HOST_USER_UID/GID
```

### 2. Install the start script
``` bash
sudo cp thornbots-start.sh /usr/local/bin/thornbots-start.sh
sudo chmod +x /usr/local/bin/thornbots-start.sh
```

### 3. Install and enable the service
``` bash
sudo cp thornbots.service /etc/systemd/system/thornbots.service
sudo systemctl daemon-reload
sudo systemctl enable thornbots     # boot autostart
sudo systemctl start thornbots      # start right now
```

# Use
#### Watch logs live
```bash
journalctl -u thornbots -f
```
