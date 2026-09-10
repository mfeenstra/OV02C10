#!/usr/bin/env bash

### Reload configurations and reload the kernel modules in the correct sequence:

# Stop the relay and reload v4l2loopback
sudo systemctl stop v4l2-relayd@intel-ipu.service
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback

# Start the relay
sudo systemctl daemon-reload
sudo systemctl enable --now v4l2-relayd@intel-ipu.service

# Reload udev and clear stale user ACL permissions
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=video4linux
for i in $(seq 0 47); do sudo setfacl -b /dev/video$i 2>/dev/null; done

# Restart WirePlumber
systemctl --user restart wireplumber
