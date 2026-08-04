# OVTI02C1 — Dell XPS 14 built-in webcam bring-up

This directory documents (and mirrors the live system config for) getting the
built-in MIPI camera working on a **Dell XPS 14 DA14250** running Arch Linux.
The sensor is an OmniVision OV02C10 (ACPI ID `OVTI02C1`, hence the directory
name) behind an Intel IPU6 image processor — not a normal UVC USB webcam, so
it needs a custom capture pipeline. Full background, hardware topology, and
step-by-step setup are in `HOWTO.md`.

Collaborator **Jacob** sent fixes for issues found after the original HOWTO
was written (see git-less history below — there is no git repo here, this
directory itself is the working notes). His fixes have now been folded into
`HOWTO.md`/scripts/`pkglist.txt`/`72-camera-hide-ipu6-isys.rules` directly;
the `jacob_updates/` extraction and `OVTI02C1-JACOB.tgz` tarball were removed
once merged.

## Architecture (current, working)

```
OV02C10 sensor → IPU6 (ISYS raw capture nodes /dev/video0-47, root-only)
               → icamerasrc/libcamera (system service, root)
               → v4l2-relayd@intel-ipu.service
               → v4l2loopback virtual device /dev/video48 "Virtual_WebCam_0"
               → apps (browsers, Zoom, OBS, etc.) open this one device
```

WirePlumber is configured to disable its own `libcamera` monitor (which would
otherwise contend with the relay for the hardware) and to hide the 48 dead
ISYS nodes, so `wpctl status` / the PipeWire camera portal also see only one
camera: `Virtual_WebCam_0`, tagged "Built-in Webcam".

## Current state (as of 2026-07-16, this session)

Starting symptom: `wpctl status` / apps showed ~64 duplicate video devices
(the 48 dead IPU6 ISYS nodes + `Virtual_WebCam_0` + a redundant raw libcamera
`ov02c10` source) instead of one usable camera.

Root causes found and fixed:

1. **Relay config bug** — `/etc/v4l2-relayd.d/intel-ipu.conf` had
   `FRAMERATE=30` (not a GStreamer fraction) and no trailing `videoconvert`,
   causing the relay to crash-loop and leaving `/dev/video48` stuck on
   v4l2loopback's fallback 640x480 BGR4 test format instead of real video.
   **Fixed**: `FORMAT=I420`, `FRAMERATE=30/1`, `VIDEOSRC=".. ! videoconvert"`.
   Confirmed live: relay now streams real 1920x1080 I420, 0 restarts.

2. **WirePlumber enumerating everything unfiltered** — fix was already
   prepared but inactive (gzipped) at
   `/etc/wireplumber/wireplumber.conf.d/50-hide-ipu6-isys.conf.gz`.
   **Activated**: decompressed into `.conf` in place (content verified
   identical to Jacob's fix, no edits needed). Disables `monitor.libcamera`,
   disables all `driver="isys"` v4l2 nodes, tags `Virtual_WebCam_0` as
   `media.role=Camera` / "Built-in Webcam".

3. **Apps enumerating raw `/dev/video0-47` directly** (Chrome, Electron
   apps) — fix was prepared but inactive (`.old` suffix, rule commented out)
   at `/etc/udev/rules.d/72-camera-hide-ipu6-isys.rules.old`. The live
   version was in `jacob_updates/OVTI02C1/72-camera-hide-ipu6-isys.rules`.
   **Activated**: installed as `/etc/udev/rules.d/72-camera-hide-ipu6-isys.rules`,
   old `.old` file removed, udev reloaded/triggered, stale ACLs cleared.
   Confirmed: `/dev/video0`/`video47` now `root:root 0600`; `/dev/video48`
   unaffected.

4. **Docs/cleanup** — Jacob's updated `HOWTO.md`, scripts, `pkglist.txt`,
   and the udev rule were copied into the project root as canonical. Stale
   scratch config directories removed: `/etc/v4l2-relayd.d/{old,old.0,new}`,
   `/etc/default/{old,old.0}`.

## Resolved — verified post-reboot (2026-07-16)

The kernel bug described below (hot-reloading `v4l2loopback`/`ov02c10` racing
WirePlumber's already-running libcamera monitor, `RIP: subdev_close+0x2a/0xb0
[videodev]`, "Fixing recursive fault but reboot is needed!") required a
reboot before the three fixes above could be verified end-to-end. As
expected, the reboot cleared it: on a normal boot, camera kernel modules load
via `modules-load.d` before WirePlumber ever starts, so there's no race.

Post-reboot checks, all passing:

- `wpctl status` Video section: exactly **one** device/source —
  `Virtual_WebCam_0` / "Built-in Webcam" (default). No duplicate ISYS nodes.
- `v4l2-ctl --list-devices` (normal user): only `ipu6` and `Virtual_WebCam_0`
  visible/openable.
- `v4l2-ctl -d /dev/video48 --all`: 1920x1080 YU12 @ 30fps (not the old stuck
  640x480 test format).
- `/dev/video0` / `/dev/video47`: `root:root 0600`. `/dev/video48`:
  `root:video` with ACL, group-accessible.
- `v4l2-relayd@intel-ipu.service` and `wireplumber` (user): both active,
  clean start, no errors; no trace of the panic in the current boot's kernel
  log.
- Captured a live frame from `/dev/video48` via `ffmpeg` + `signalstats`:
  per-pixel luminance varies across the frame (not a flat/frozen value),
  confirming real sensor data is flowing — frame was very dark because the
  room was dark (pre-dawn) when captured, not because the pipeline is stuck.

## Follow-up bug — stuck PipeWire v4l2 node (found + fixed, 2026-07-16)

App-level testing (per the "still needs a human" item above) surfaced a real
bug, separate from everything above: `qv4l2` opening `/dev/video48` worked
fine, but **Cheese** failed to stream, and `journalctl --user -u wireplumber`
showed the actual cause:

```
pipewire[4519]: spa.v4l2: '/dev/video48' VIDIOC_S_FMT: Device or resource busy
```

WirePlumber's PipeWire v4l2 source node for `/dev/video48` had been sitting
since boot with an already-streaming handle. Every time a *new* client
(Cheese) linked to it, PipeWire's v4l2 plugin re-issued `VIDIOC_S_FMT` on
that handle — even requesting the exact same format already active — and the
kernel correctly rejects reformatting a device mid-stream. `qv4l2` never hit
this because it opens its own fresh handle instead of reusing the node.

**Fixed**: destroyed the stuck node (`pw-cli destroy 58`) and cycled a udev
`remove`/`add` event (`sudo udevadm trigger --action=remove` then `--action=add`
on `/sys/devices/virtual/video4linux/video48`) to make WirePlumber recreate
it — a plain `--action=change` event was not sufficient to trigger recreation.
The fresh node (new id) had a never-streamed handle, so Cheese's first
negotiation succeeded. **Confirmed working**: `wpctl status` showed an active
`cheese → Virtual_WebCam_0:capture_1 [active]` link, and Cheese captured real
frames.

If this recurs after a future boot/restart (unconfirmed whether it's
boot-order-dependent or triggered by something specific), the fix is those
same two commands: `pw-cli destroy <node-id>` (get the id from `pw-dump` or
`wpctl status`), then `sudo udevadm trigger --action=remove` +
`--action=add` on `/sys/devices/virtual/video4linux/video48`.

### Known non-goals — guvcview and qcam are not expected to work

Testing also tried `guvcview` and `qcam`; neither works, but neither is a bug
in this setup — both are structurally incompatible with the always-on relay
architecture, not part of the target app list (browsers/Zoom/OBS via
PipeWire, per the architecture diagram above):

- **qcam** links `libcamera.so` directly — it's libcamera's own native
  viewer and talks to the OV02C10 sensor directly, bypassing
  `/dev/video48` entirely. `icamerasrc` (inside the relay) already holds an
  exclusive libcamera acquisition on the sensor 24/7, so qcam can't acquire
  it. Only one libcamera client can hold a camera at a time — expected to
  fail as long as the relay is running.
- **guvcview** opens `/dev/video48` fine (confirmed via `lsof`, no busy
  error on open) but fails during buffer allocation:
  `VIDIOC_REQBUFS`/`VIDIOC_S_FORMAT: Device or resource busy`. PipeWire
  permanently holds an mmap buffer allocation on the loopback the moment
  WirePlumber creates the source node (independent of whether any PipeWire
  client is actively streaming), and `v4l2loopback` here (`max_buffers: 2`)
  doesn't support two independent mmap buffer owners on the capture side at
  once. guvcview's `libv4l2` wrapper wants its own buffer set via mmap and
  collides with PipeWire's existing allocation. `qv4l2` and `ffmpeg` avoid
  this because they default to the simpler `read()` capture method instead
  of mmap.

## Boot-time sensor race — ov02c10 probe failure (found + fixed, 2026-07-22)

After a clean reboot, the relay started fine but crashed on the first client
connection (about 1 hour into the boot, when Discord tried to open the camera)
with `std::invalid_argument: stoi` in `CameraParser::parseLinkElement` inside
`libcamhal.so` / `ipu6epmtl.so`.

Root cause: on kernel 6.18 LTS, the `ov02c10` sensor driver and
`usbio-bridge` (the Lattice AI USB 2.0 IVSC chip at `3-9`, `idVendor=2ac1
idProduct=20c9`, which provides the I2C proxy for the sensor) are both
auto-loaded by udev at approximately the same moment (~second 96 after boot).
The I2C bridge isn't ready in those first milliseconds, so the probe fails
with `EREMOTEIO` (not `EPROBE_DEFER`). The kernel never auto-retries
EREMOTEIO, so `ov02c10` stays unbound indefinitely. Without the sensor entity
(`ov02c10 17-0036`) in the media topology, `CameraParser::parseLinkElement`
crashes when it can't resolve the `ov02c10 $I2CBUS` entity reference.

Additionally, each crash leaves a stale SysV SHM segment (key `0x43414d` =
`"CAM"`, 8192 bytes) with `nattch=0`. On the next systemd-triggered restart,
CamHAL finds the partially-initialised segment and crashes again. After 6
restarts, systemd hits the start-limit-hit timeout.

**Fixed**: added
`/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/prestart.conf`
(copied to project root as `prestart.conf`) with two `ExecStartPre` steps:

1. Clear any stale CamHAL SHM segments with `nattch=0` via `ipcrm`
2. Retry-bind `i2c-OVTI02C1:00` to the `ov02c10` driver (the relay starts
   at multi-user.target, well after the USB bridge has settled, so the bind
   succeeds on the first or second attempt)

Manual recovery (if relay is in start-limit-hit state):
```bash
sudo ipcrm -m $(ipcs -m | awk '/0x0043414d/ && $6==0 {print $2}')
sudo systemctl reset-failed v4l2-relayd@intel-ipu.service
sudo systemctl start v4l2-relayd@intel-ipu.service
```

Note: this HOWTO's dmesg sequence (`-517` EPROBE_DEFER → CVS transfer →
success) was written for a different kernel/driver version. On kernel 6.18
LTS the sequence is two `-121` EREMOTEIO failures with no auto-retry; the
prestart.conf drop-in handles it.

> **Superseded 2026-07-24 — see the next section.** The `prestart.conf` *bind*
> step described here never actually executed: it runs as an `ExecStartPre` of
> `v4l2-relayd@intel-ipu.service`, whose base unit ships
> `ReadOnlyDirectories=/etc /sys`, so writing `/sys/.../ov02c10/bind` fails with
> `EROFS` every time (the `2>/dev/null` hid it). It only *appeared* to work
> because udev usually wins the probe race on its own. The bind now lives in a
> dedicated un-sandboxed service; the SHM-cleanup step here was always fine and
> is retained.

## The real regression cause — sandboxed bind + kernel roulette (found + fixed, 2026-07-24)

Jacob reported the camera *kept* breaking after reboots despite everything
above. Root-caused to a single structural problem, not N separate bugs: **the
boot pipeline is a chain of timing races, and the one fix meant to make the
critical race (sensor bind) deterministic never actually ran.**

The 2026-07-22 `prestart.conf` bind step is a silent no-op. The base unit
`/usr/lib/systemd/system/v4l2-relayd@.service` ships
`ReadOnlyDirectories=/etc /sys` (→ `ReadOnlyPaths=/etc /sys`), which mounts
`/sys` read-only *inside the service's mount namespace* — and every
`ExecStartPre` runs in that namespace. So
`echo i2c-OVTI02C1:00 > /sys/bus/i2c/drivers/ov02c10/bind` fails with
`Read-only file system` on all 10 attempts. Confirmed in the 2026-07-24 boot
log: ten consecutive `.../ov02c10/bind: Read-only file system` lines, and the
relay still crashed once (`code=dumped, status=6/ABRT`) before recovering.
Every "successful" boot since 07-22 succeeded *in spite of* prestart.conf —
purely because udev happened to win the probe race that boot. Every reboot
re-rolled the dice; the interactive fixes just won that one boot's toss.

Aggravating variable: the machine dual-boots `linux-lts` (6.18.38-3-lts, what
all these fixes target) and mainline `linux` (7.1.3-arch1-3, which even logged
a `crash` on Jul 22). Different kernel → different race timing. DKMS is built
for both (`ipu6-drivers`, `v4l2loopback`, `vision-drivers`), so it's not a
missing-module failure — just extra non-determinism.

**Fixed (2026-07-24):**

1. **Moved the sensor bind out of the sandbox** into a dedicated, un-sandboxed
   oneshot `/etc/systemd/system/ov02c10-bind.service` (mirrored to project root
   as `ov02c10-bind.service`), ordered `Before=v4l2-relayd@intel-ipu.service`,
   `enable`d. It runs in the host mount namespace where `/sys` is writable,
   polls up to 30s for the USB I2C bridge, then binds `i2c-OVTI02C1:00`.
   Idempotent (`Type=oneshot`, `RemainAfterExit=yes`, exits 0 once bound). The
   relay's `prestart.conf` drop-in now only `Wants=`/`After=` this service and
   keeps just the SHM-cleanup `ExecStartPre` — that one always worked (SysV IPC
   is not mount-namespaced, and `icamerasrc.conf` sets `PrivateIPC=no`), and it
   still needs to run on every relay restart, not once at boot.
   Verified end-to-end: manually unbound the sensor (simulating a lost boot
   race → sensor absent from the media graph), started the service, it re-bound
   the sensor (`ov02c10 17-0036` back in the graph) and the relay came up clean
   (`NRestarts=0`, live 1920×1080 frames, YAVG≈102 with real per-frame
   variance).

2. **Pinned the default boot to LTS.** `GRUB_DEFAULT` was positional `0`; set it
   to the explicit LTS entry-id
   `gnulinux-advanced-…>gnulinux-linux-lts-advanced-…` (stable across
   `grub-mkconfig` regeneration, unlike a positional index) and regenerated
   `/boot/grub/grub.cfg` (backup at `/etc/default/grub.bak.*`). Unattended boots
   now always land on 6.18-LTS; mainline `linux` stays available under "Advanced
   options" for manual selection.

Still not persistent: the stuck-PipeWire-node recovery (2026-07-16,
`pw-cli destroy` + udev cycle) remains a manual runtime fix if it recurs. The
sensor-bind race — the actual reboot-regression cause — is now deterministic.

## Verified end state

- Exactly one camera visible everywhere: `Virtual_WebCam_0` / "Built-in
  Webcam", 1920x1080 @ 30fps.
- **Deterministic across reboots**: `ov02c10-bind.service` (enabled,
  un-sandboxed) binds the sensor before the relay regardless of the udev probe
  race, and GRUB defaults to the 6.18-LTS kernel the pipeline is tuned for. No
  longer a coin-flip.
- Raw IPU6 nodes (`/dev/video0-47`) locked to root, invisible to apps.
- PipeWire/portal-based apps (Cheese confirmed; browsers, Zoom, OBS expected
  to behave the same way) stream successfully.
- Direct-libcamera (qcam) and concurrent-mmap (guvcview) tools are known,
  expected non-goals — not a regression, not worth chasing further.
- Firefox uses PipeWire portal backend (`media.webrtc.camera.backend=1` in
  `~/.mozilla/firefox/*/user.js`) to bypass the single-format v4l2loopback
  constraint; Google Meet, Webex, etc. work via this path.
