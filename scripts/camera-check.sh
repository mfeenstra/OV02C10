#!/usr/bin/env bash
# Post-reboot camera verification script for OVTI02C1 on Dell XPS 14 DA14250
# Run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo."
    exit 1
fi

echo "=========================================="
echo "  OVTI02C1 Camera Diagnostics"
echo "=========================================="

echo ""
echo "=== 1. Module versions (should show /updates/ path) ==="
modinfo ov02c10 2>/dev/null | grep -i filename || echo "ov02c10 module not loaded or not found"
modinfo intel_skl_int3472_discrete 2>/dev/null | grep -i filename || echo "intel_skl_int3472_discrete module not loaded or not found"

echo ""
echo "=== 2. Kernel messages (camera probe) ==="
dmesg | grep -iE 'ipu6|ovti|ov02' | tail -n 20

echo ""
echo "=== 3. Camera probe result ==="
if dmesg | grep -q "ov02c10.*EPROBE_DEFER\|probe.*deferred"; then
    echo "STATUS: DEFERRED (waiting for CVS)"
elif dmesg | grep -q "ov02c10.*failed\|failed.*ov02c10"; then
    echo "STATUS: FAILED"
    dmesg | grep -E "ov02c10.*fail|fail.*ov02c10" | tail -n 5
else
    echo "STATUS: Normal (please review dmesg output above)"
fi

echo ""
echo "=== 4. V4L2 subdev (sensor) ==="
v4l2-ctl --list-devices 2>/dev/null | head -n 10 || echo "v4l-utils (v4l2-ctl) not installed"

echo ""
echo "=== 5. Sensor in media topology ==="
if command -v media-ctl >/dev/null 2>&1; then
    media-ctl -p | grep -A3 -iE "ov02c10\|OVTI02C1" || echo "Sensor not found in media controller topology"
else
    echo "media-ctl not available (install v4l-utils)"
fi

echo ""
echo "=== 6. Test frame capture (requires gstreamer + icamerasrc) ==="
echo "   Run: gst-launch-1.0 icamerasrc device-name=2 ! video/x-raw,format=NV12 ! videoconvert ! autovideosink"
echo "   OR:  gst-launch-1.0 icamerasrc device-name=2 ! video/x-raw,format=NV12 ! filesink location=/tmp/frame.raw"
