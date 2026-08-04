#!/usr/bin/env bash

if ! [ -e /run/camera/ov02c10-uf_VIDEO.aiqd ]; then
  sudo mkdir -p /run/camera
  sudo chmod -R 777 /run/camera
fi

gst-launch-1.0 icamerasrc device-name=2 ! queue ! videoconvert ! video/x-raw,format=NV12 ! videoflip method=rotate-180 ! videoconvert ! v4l2sink name='v4l2sink-0' device=/dev/video48
