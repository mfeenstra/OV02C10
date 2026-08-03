#!/usr/bin/env bash
# Runs the GStreamer pipeline manually to stream from the camera sensor to the loopback device.
# Use for testing the pipeline directly without v4l2-relayd.
gst-launch-1.0 icamerasrc device-name=2 ! queue ! videoconvert ! video/x-raw,format=I420 ! videoflip method=rotate-180 ! videoconvert ! v4l2sink name='v4l2sink-0' device=/dev/video48
