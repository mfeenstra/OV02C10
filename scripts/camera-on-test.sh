#!/usr/bin/env bash
# Test video capture pipeline displaying output in a window (requires GUI and root)
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo."
    exit 1
fi

gst-launch-1.0 icamerasrc device-name=2 ! video/x-raw,format=NV12 ! videoflip method=rotate-180 ! videoconvert ! autovideosink
