#!/usr/bin/env bash
#
# Fix for: WirePlumber's PipeWire v4l2 source node for the virtual webcam
# (Virtual_WebCam_0 / "Built-in Webcam") gets stuck in an already-streaming
# state, so any new client (Cheese, browsers, etc.) that links to it fails
# with a kernel-level format negotiation error, e.g. in
# `journalctl --user -u wireplumber`:
#
#   pipewire[...]: spa.v4l2: '/dev/videoNN' VIDIOC_S_FMT: Device or resource busy
#
# This happens because the node's underlying V4L2 handle is already
# streaming, and PipeWire re-issues VIDIOC_S_FMT on it for every new link
# (even to identical format params) -- which the kernel correctly refuses,
# since you can't reformat a device mid-stream. qv4l2/ffmpeg avoid this
# because they open their own fresh handle instead of reusing the stuck one.
#
# Fix: destroy the stuck PipeWire node, then cycle a udev remove/add event
# for the underlying device so WirePlumber's v4l2 monitor recreates the node
# fresh (a plain `--action=change` event is NOT sufficient to trigger this).
#
# It also cleans up a related cause of the same symptom: leftover processes
# (a crashed/killed guvcview, a stray ffmpeg test, etc.) that still hold the
# device open -- these can block the buffer/format reset just as effectively
# as the stuck PipeWire node itself, so they're killed off first.
#
# See CLAUDE.md, "Follow-up bug -- stuck PipeWire v4l2 node" for the full
# writeup of how this was diagnosed.
#
# Usage: ./fix-stuck-webcam-node.sh [/dev/videoNN] [wait-seconds]
#   /dev/videoNN   the v4l2loopback device (default: /dev/video48)
#   wait-seconds   how long to wait for the node to reappear (default: 5)

set -uo pipefail

DEVICE="${1:-/dev/video48}"
WAIT_SECONDS="${2:-5}"
DEVICE_BASENAME="$(basename "$DEVICE")"
SYSFS_PATH="/sys/devices/virtual/video4linux/${DEVICE_BASENAME}"
RELAY_SERVICE="v4l2-relayd@intel-ipu.service"

if [ ! -e "$DEVICE" ]; then
    echo "ERROR: $DEVICE does not exist." >&2
    exit 1
fi
if [ ! -e "$SYSFS_PATH" ]; then
    echo "ERROR: $SYSFS_PATH does not exist (unexpected sysfs layout for $DEVICE)." >&2
    exit 1
fi

find_node_ids() {
    pw-dump 2>/dev/null | jq -r --arg dev "$DEVICE" '
        .[] | select(.type == "PipeWire:Interface:Node")
        | select(.info.props["api.v4l2.path"] == $dev or .info.props["object.path"] == ("v4l2:" + $dev))
        | .id
    '
}

kill_stale_holders() {
    # Processes that are legitimately allowed to hold $DEVICE open --
    # everything else found still holding it is treated as a stale/zombied
    # leftover and killed, since that's exactly what this script is for.
    local protected_pids=""
    protected_pids+=" $(systemctl --user show pipewire.service -p MainPID --value 2>/dev/null)"
    protected_pids+=" $(systemctl show "$RELAY_SERVICE" -p MainPID --value 2>/dev/null)"

    local holder_pids
    holder_pids="$(sudo lsof -t "$DEVICE" 2>/dev/null | sort -u)"

    if [ -z "$holder_pids" ]; then
        echo "    No processes currently have $DEVICE open."
        return
    fi

    local pid cmd state owner killed_any
    killed_any=0
    for pid in $holder_pids; do
        case " $protected_pids " in
            *" $pid "*)
                continue
                ;;
        esac

        cmd="$(ps -o comm= -p "$pid" 2>/dev/null)"
        if [ -z "$cmd" ]; then
            continue # already gone
        fi
        state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
        owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"

        echo "    Killing stale holder: PID $pid ($cmd, user=$owner, state=$state)"
        if [ "$owner" = "$(whoami)" ]; then
            kill -9 "$pid" 2>/dev/null
        else
            sudo kill -9 "$pid" 2>/dev/null
        fi
        killed_any=1
    done

    if [ "$killed_any" -eq 0 ]; then
        echo "    Only protected processes (pipewire, $RELAY_SERVICE) hold $DEVICE open -- nothing to kill."
    fi
}

echo "==> Checking for stale/zombied processes still holding $DEVICE open ..."
kill_stale_holders

echo "==> Looking for a PipeWire node bound to $DEVICE ..."
node_ids="$(find_node_ids)"

if [ -z "$node_ids" ]; then
    echo "    No matching node found (already gone, or never created). Proceeding anyway."
else
    echo "$node_ids" | while read -r id; do
        echo "    Found node id=$id, destroying it..."
        pw-cli destroy "$id" >/dev/null 2>&1
    done
fi

echo "==> Cycling udev remove/add for $SYSFS_PATH (requires sudo) ..."
sudo udevadm trigger --action=remove "$SYSFS_PATH"
sleep 1
sudo udevadm trigger --action=add "$SYSFS_PATH"

echo "==> Waiting up to ${WAIT_SECONDS}s for WirePlumber to recreate the node ..."
new_id=""
for _ in $(seq 1 "$WAIT_SECONDS"); do
    new_id="$(find_node_ids)"
    if [ -n "$new_id" ]; then
        break
    fi
    sleep 1
done

if [ -z "$new_id" ]; then
    echo "FAILED: no PipeWire node for $DEVICE reappeared within ${WAIT_SECONDS}s." >&2
    echo "Check: systemctl --user status wireplumber, journalctl --user -u wireplumber" >&2
    exit 1
fi

echo "==> Success: new node id=$new_id"
echo
wpctl status | sed -n '/^Video$/,/^$/p'
