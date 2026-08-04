#!/usr/bin/env bash

gst-launch-1.0 icamerasrc device-name=2 ! video/x-raw,format=NV12 ! videoflip method=rotate-180 ! videoconvert ! autovideosink
