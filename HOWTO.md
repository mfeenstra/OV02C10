# HOWTO: Get the OVTI02C1 (OmniVision OV02C10) Webcam Working on Dell XPS 14 DA14250 (Arch Linux)

This step-by-step guide walks through getting the built-in webcam working on a **Dell XPS 14 DA14250** running Arch Linux and Linux Kernel 7+.

By the end, your camera will work like a normal webcam: the light next to it will turn on only while some app (a browser, Zoom, OBS, etc.) is actually using it, or when you choose to activate it with with the included `run-webcam.sh` script.

If you get stuck, the **Troubleshooting** section near the end covers the most common problems and how to fix them.

## Why this is complicated: how the camera is wired up

Normal USB webcams show up and just work — they speak a standard called UVC (USB Video Class) that Linux understands out of the box. This laptop's camera is not that simple. Here's the hardware involved:

| | |
|---|---|
| Laptop | Dell XPS 14 DA14250 |
| Camera sensor | OmniVision OV02C10 (ACPI ID `OVTI02C1`), 2 megapixels |
| IPU | Intel IPU6, `ipu6epmtl` variant — a special image-processing chip built into the CPU that this camera needs in order to produce usable video (PCI ID `8086:7d19`, "Meteor Lake" is the CPU generation) |
| Bridge | Lattice AI USB 2.0 Bridge (VID `2ac1`, PID `20c9`) on USB port 3-9 — a small chip that sits between the camera and the rest of the system |
| CVS driver | `INTC10E0` (Intel Computer Vision Subsystem) — software that has to "unlock" the camera before Linux can talk to it directly, sharing the same bridge chip |

The camera sensor isn't wired straight to the computer's internal control bus (called I2C — a simple, slow bus used for talking to small chips). Instead, it sits behind that Lattice USB bridge chip, and Linux is only allowed to talk to the sensor directly *after* the Intel CVS software finishes a handshake with the bridge, described in Intel's firmware as a "Transfer of ownership":

```
OV02C10 sensor → MIPI-CSI-2 → Lattice AI USB Bridge → USB port 3-9
                                                       │
                                         ┌─────────────┴─────────────┐
                                         │       usbio-i2c driver    │
                                         │  i2c-INTC10E0:00 (CVS)    │
                                         │  i2c-OVTI02C1:00 (sensor) │
                                         └───────────────────────────┘
```

(MIPI-CSI-2 is just the type of cable/connector the camera uses internally — you don't need to do anything with it, it's just there for context.)

## What's broken, and which step fixes it

| # | Problem | Symptom |
|---|---|---|
| 1 | The Linux kernel (the core of the OS) tries to talk to the camera sensor before the CVS software has finished its handshake with the bridge chip | `ov02c10: failed to find sensor: -121` shows up at boot, camera never works |
| 2 | The camera's driver software (`libcamhal.so.0`) or its config files (`/etc/camera`) are missing or incomplete | Running `gst-inspect-1.0 icamerasrc` says "No such element" |
| 3 | GStreamer's (the video-streaming toolkit this guide uses) internal cache of installed plugins is out of date | `icamerasrc` still isn't found, even after Step 4 |
| 4 | Your Linux user account isn't in the right permission groups | `Permission denied` when opening `/dev/ipu-psys0` |
| 5 | The camera driver needs a form of shared memory (`shmget`) that only the root/admin account can normally use | `CamHAL[ERR] Fail to allocate shared memory` when not running as root |
| 6 | The camera is physically mounted in the laptop rotated 180° | Video appears upside down |
| 7 | The video pipeline is pointed at the wrong internal camera port | Video is completely black — the selected port isn't wired to a real sensor |
| 8 | The video pipeline is set to run all the time instead of only when needed | The camera's LED light stays on permanently |

---

## Step 1 — Install the required software

### My Currently Working Setup

- Arch Linux and Kernel

```bash
Linux mercury 7.1.3-arch1-2 #1 SMP PREEMPT_DYNAMIC Thu, 09 Jul 2026 19:55:55 +0000 x86_64 GNU/Linux
```

- Installed Packages

```bash
gambas3-gb-v4l
gst-plugin-libcamera-ipu6
gst-plugins-bad
gst-plugins-bad-libs
gst-plugins-base
gst-plugins-base-libs
gst-plugins-espeak
gst-plugins-good
gst-plugins-ugly
icamerasrc-git
icamerasrc-git-debug
intel-ipu6-camera-bin
intel-ipu6-camera-hal-git
intel-ipu6-camera-hal-git-debug
intel-ipu6-dkms-git
libcamera-docs
# A future yay -Syu may hit this again. If yay pulls an updated PKGBUILD from the AUR, it will overwrite my local 
fix and fail the same way until the maintainer fixes it upstream. 
Worth leaving a comment on the libcamera-ipu6 AUR page asking them to change the ../ references to "$srcdir"/ — anyone with a custom BUILDDIR is broken right now.
libcamera-ipu6
libcamera-ipu6-debug
libcamera-ipu6-ipa
libcamera-ipu6-tools
pipewire-libcamera
pipewire-v4l2
python-libcamera-ipu6
v4l-utils
v4l2-relayd
v4l2-relayd-debug
v4l2loopback-dkms
v4l2loopback-utils
v4l2ucp
v4l2ucp-debug
```

- Package Versions

```bash
gambas3-gb-v4l 3.21.6-1
gst-plugin-libcamera-ipu6 0.7.0+ov01a10.2-5
gst-plugins-bad 1.28.5-1
gst-plugins-bad-libs 1.28.5-1
gst-plugins-base 1.28.5-1
gst-plugins-base-libs 1.28.5-1
gst-plugins-espeak 0.6.0-1
gst-plugins-good 1.28.5-1
gst-plugins-ugly 1.28.5-1
icamerasrc-git r93.867c5b6-1
icamerasrc-git-debug r93.867c5b6-1
intel-ipu6-camera-bin r92.30e8766-1
intel-ipu6-camera-hal-git r128.9899efa-1
intel-ipu6-camera-hal-git-debug r128.9899efa-1
intel-ipu6-dkms-git r265.c313a9e53-1
libcamera-docs 0.7.1-1
libcamera-ipu6 0.7.0+ov01a10.2-5
libcamera-ipu6-debug 0.7.0+ov01a10.2-5
libcamera-ipu6-ipa 0.7.0+ov01a10.2-5
libcamera-ipu6-tools 0.7.0+ov01a10.2-5
pipewire-libcamera 1:1.6.8-1
pipewire-v4l2 1:1.6.8-1
python-libcamera-ipu6 0.7.0+ov01a10.2-5
v4l-utils 1.32.0-2
v4l2-relayd 0.2.0-1
v4l2-relayd-debug 0.2.0-1
v4l2loopback-dkms 0.15.4-1
v4l2loopback-utils 0.15.4-1
v4l2ucp 2.0.2-6
v4l2ucp-debug 2.0.2-6
```

- Kernel Module

```bash
$ modinfo ov02c10

filename:       /lib/modules/7.1.3-arch1-2/updates/dkms/ov02c10.ko.zst
license:        GPL v2
description:    OmniVision OV02C10 sensor driver
author:         Hao Yao <hao.yao@intel.com>
srcversion:     97B6835FE4B9E41741D2DE0
alias:          acpi*:OVTI02C1:*
depends:        videodev,v4l2-fwnode,mc,v4l2-async
name:           ov02c10
retpoline:      Y
vermagic:       7.1.3-arch1-2 SMP preempt mod_unload 
sig_id:         PKCS#7
signer:         DKMS module signing key
sig_key:        55:B1:90:6A:F8:40:D3:35:2B:42:6A:52:9F:57:50:C1:C9:D7:45:DD
sig_hashalgo:   sha512
signature:      26:BF:AF:36:61:10:E6:AD:D3:4D:4E:7C:B0:05:2D:9F:8B:12:A5:64:
		67:96:FA:6A:B8:06:13:7F:CD:32:F5:DA:62:B5:EB:FD:5A:AC:A4:6C:
		97:43:96:72:D6:BA:DE:22:28:98:D6:BA:02:94:C0:21:C2:29:62:06:
		00:12:C3:81:5E:19:5D:64:9F:C6:D0:3F:12:E5:2E:61:7D:A8:0F:F3:
		B9:AC:73:6A:DE:5A:D3:E0:3F:39:BF:91:BE:F5:88:6E:9D:8D:34:B9:
		89:20:A0:03:30:EF:A6:C4:B7:70:8F:30:CB:22:E8:28:A4:A4:17:1F:
		81:71:D7:5C:0C:E8:F0:41:2B:21:53:0F:AE:18:06:65:35:77:38:BE:
		A4:29:C7:4C:C2:C1:D3:AC:40:4A:11:BC:98:AE:1B:C0:FF:AB:55:2D:
		92:0A:67:69:B1:50:51:CF:91:F7:8A:7F:DA:89:21:52:7C:AD:94:23:
		98:BF:ED:AC:C0:E0:8F:C2:AB:B6:42:CA:22:8A:17:7F:E6:3F:B9:DA:
		22:D9:16:7F:16:C8:25:65:70:7C:3B:2B:43:66:3E:25:7A:24:28:4D:
		DE:5F:EF:3D:6A:BD:48:C2:51:EC:63:5E:9A:0C:E8:6E:3F:79:62:FA:
		49:A5:1C:F3:85:CC:01:54:F6:F7:6D:B1:BA:FC:13:37
```

- For reference, if for some reason you would like to compile packages and drivers from source:
  - `git clone https://github.com/intel/icamerasrc.git`
  - `git clone https://aur.archlinux.org/intel-ipu6ep-camera-hal-git.git`
  - `git clone https://github.com/intel/ipu6-camera-bins`
  - `git clone https://github.com/intel/ipu6-camera-hal`
  - `git clone https://github.com/intel/ipu6-drivers.git`


- **Reboot**, then check the system log (`dmesg`) for the sequence below, which shows the camera failing once, then succeeding once the CVS handshake finishes:

   ```bash
   dmesg | grep -E "ov02c10|CVS"
   ```

   ```
   ov02c10 i2c-OVTI02C1:00: failed to find sensor: -121   ← not yet ready
   ov02c10 i2c-OVTI02C1:00: probe failed with error -517  ← this means "try again later", which is expected
   Intel CVS driver: Transfer of ownership success
   ov02c10 i2c-OVTI02C1:00: sensor identified: ov02c10 2.0MP  ← retry succeeded
   ```
   Then confirm the driver is actually attached to the sensor:
   ```bash
   ls /sys/bus/i2c/drivers/ov02c10/
   ```
   You should see `i2c-OVTI02C1:00` in the output.

## Step 2 — Install udev rules (device permission rules)

We need a rule file that: (a) makes the camera's device files accessible to normal users instead of only root, and (b) works around a case where the kernel doesn't automatically reconnect the sensor's driver.

- `/etc/udev/rules.d/99-camera.rules`

```
KERNEL=="video0", SUBSYSTEM=="video4linux", ATTR{name}=="IPU6 Virtual Camera", GROUP="video", MODE="0660"
KERNEL=="video99", SUBSYSTEM=="video4linux", ATTR{name}=="IPU6 Camera Buffer", GROUP="root", MODE="0600"
SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660"

# zero-copy permissions
KERNEL=="udmabuf", TAG+="uaccess"

# explicit binding workaround
ACTION=="add", SUBSYSTEM=="i2c", ATTR{name}=="OVTI02C1:00", RUN+="/bin/sh -c 'echo i2c-OVTI02C1:00 > /sys/bus/i2c/drivers/ov02c10/bind'"
```

- Copy into place and reload:

```bash
sudo cp 99-camera.rules /etc/udev/rules.d/99-camera.rules
sudo udevadm control --reload
sudo udevadm trigger
```

## Step 3 — Check that the camera driver software is installed correctly

The camera needs a driver library called the "HAL" (Hardware Abstraction Layer) — a file named `libcamhal.so.0` — plus a folder of configuration and calibration files at `/etc/camera`. 

It should have been installed with the Intel packages above.  Verify:

- HAL library exists

```bash
ls /usr/lib/libcamhal.so.0
```

If that file is missing, reinstall the package that provides it and refresh the system's library cache:

```bash
yay -S intel-ipu6-camera-hal-git
sudo ldconfig
```

The `/etc/camera` folder (installed automatically by that same package) should look roughly like this.

- For me, it was neccessary to symlink the `ipu6` and `ipu6ep` folders into the required `ipu6epmtl` folder, as this had the required contents.

```
/etc/camera/
├── ipu6 -> ipu6epmtl               # symlink, generic IPU6 alias
├── ipu6ep -> ipu6epmtl             # symlink, Alder-Lake-family alias
├── ipu6epmtl/                      # actual HAL variant dir for this Meteor Lake platform
│   ├── OV02C10_*.aiqb              # sensor tuning/calibration blobs
│   ├── libcamhal_profile.xml
│   ├── psys_policy_profiles.xml
│   └── sensors/
│       └── ov02c10-uf.xml          # OV02C10 sensor config (the one that matters here)
├── sensors/
│   └── ov2740-uf.xml               # unrelated sensor profile, present but unused on this hardware
└── OV02C10.aiqd                    # runtime AIQ data, symlinked from ipu6epmtl as ov02c10-uf_VIDEO.aiqd
```

If `ipu6` or `ipu6ep` aren't linked to `ipu6epmtl`, or if `ipu6epmtl/sensors/ov02c10-uf.xml` is missing, reinstall the HAL packages

## Step 4 — Refresh GStreamer's plugin cache

GStreamer is the multimedia toolkit used to pull video frames from the camera and hand them to other applications.  GStreamer keeps a cache of which plugins (like the camera driver plugin, `icamerasrc`) are installed, so it doesn't have to rescan everything every time. That cache can go stale after installing new software, and it's kept separately for your normal user account and for the root/admin account (since the camera service later runs as root).

- Clear and rebuild both:

```bash
# user space
rm -f ~/.cache/gstreamer-1.0/registry.*.bin
gst-inspect-1.0 icamerasrc | head -3

# super user
sudo rm -f /root/.cache/gstreamer-1.0/registry.*.bin
sudo gst-inspect-1.0 icamerasrc | head -3
```

Both commands should print some plugin details, not an error saying "No such element".

## Step 5 — Add your user account to the right permission groups

- Add your user to the groups we setup as having access to the camera hardware via udev rules

```bash
sudo usermod -aG video,render $USER
```

- Reload your environment, **log out and log back in** before continuing

## Step 6 — Set up the on-demand camera service (recommended)

This is the step that actually makes the camera usable by normal apps.

**What this step does:** unlike a plain USB webcam, this camera can't be opened directly by apps like a browser or Zoom. Instead, GStreamer has to pull frames from the camera using a plugin called `icamerasrc`, and feed them into a fake ("virtual") webcam device using `v4l2loopback`, which normal apps *can* open like any other webcam. This step sets that up so the real pipeline only turns on while some app has the virtual camera open — which is why the camera's LED will be off unless something is actively using it.

Three details matter here and are easy to get wrong if you're adapting this guide to different hardware:

- `icamerasrc device-name=2` selects the specific internal camera port wired  to the real sensor. `device-name=0` points at an unconnected port and  produces a black picture.
- The camera is physically mounted rotated 180° inside the laptop, so `videoflip method=rotate-180` is needed to make the video right-side up.
- The camera driver's shared-memory mechanism normally requires root permissions, so the systemd service needs a specific setting relaxed (see step 3 below) to allow it.

The virtual camera device on my system is `/dev/video48` (labeled "Virtual_WebCam_0"). The real IPU6 driver already uses `/dev/video0` through `/dev/video47` internally, so the virtual camera lands at the next free number. You can double check this with:

```bash
v4l2-ctl --list-devices
```

1. **Set up the video pipeline configuration.**

NOTE: the below configs may seem redundant, but they work for me

- Create/edit: `/etc/v4l2-relayd.d/intel-ipu.conf` with:

```ini
# videoconvert at the end: icamerasrc outputs NV12, but the relay forces the
# input pipeline to produce exactly FORMAT below.
VIDEOSRC="icamerasrc device-name=2 ! videoflip method=rotate-180 ! videoconvert"
# I420 (V4L2 'YU12'), NOT NV12: older Chromium/Electron apps (e.g. Hyperbeam's
# Electron 12 / Chromium 89) have no NV12 V4L2 capture support and will act as
# if no camera exists ("check that you've granted camera permission"). I420 is
# supported everywhere and has the same bandwidth as NV12.
FORMAT=I420
WIDTH=1920
HEIGHT=1080
# Must be a fraction! Plain "30" produces framerate=(int)30 in the GStreamer
# caps, the output pipeline dies with "Internal data stream error", and the
# service crash-loops until it hits the systemd start limit.
FRAMERATE=30/1
```

- Create/edit: `/etc/default/v4l2-relayd` 

```ini
VIDEOSRC="icamerasrc device-name=2 ! videoflip method=rotate-180 ! videoconvert"

FORMAT=I420
WIDTH=1920
HEIGHT=1080
FRAMERATE=30/1

CARD_LABEL="Virtual_WebCam_0"
```

2. **Allow the camera driver's shared-memory usage.**

- Create/edit: `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/icamerasrc.conf`

```ini
[Service]
# Allow system IPC permissions for CamHAL shared memory
PrivateIPC=no
# The packaged unit ships CapabilityBoundingSet= (empty). Without capabilities
# icamerasrc fails with "CameraId=N failed to open libcamhal device" and the
# virtual camera only ever shows the splash frame. Restore full capabilities:
CapabilityBoundingSet=~
```

2b. **Ensure the sensor driver is bound and stale SHM is cleared at service start.**

On kernel 6.18 LTS, `ov02c10` and `usbio-bridge` (the Lattice AI USB→I2C proxy for the IVSC) load from udev at the same moment. The I2C bridge isn't ready in time, so the first probe attempt fails with EREMOTEIO (not EPROBE_DEFER), and the kernel never auto-retries. Without the sensor entity in the media topology, `libcamhal` crashes with `std::invalid_argument: stoi` in `CameraParser::parseLinkElement` the first time any client connects. Additionally, a crash during libcamhal init leaves a stale SysV shared-memory segment (key `0x43414d`) that causes the same crash on every restart.

Create `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/prestart.conf`:

```ini
[Service]
# 1. Clear any stale CamHAL SysV SHM (key 0x43414d = "CAM").
ExecStartPre=/bin/sh -c 'for id in $(ipcs -m | awk "/0x0043414d/ && \$6 == 0 {print \$2}"); do ipcrm -m "$id"; done'

# 2. Ensure the ov02c10 sensor driver is bound before CamHAL tries to enumerate cameras.
#    By the time this service starts (multi-user.target), the USB bridge has settled.
ExecStartPre=/bin/sh -c 'for i in $(seq 1 10); do [ -L /sys/bus/i2c/drivers/ov02c10/i2c-OVTI02C1:00 ] && break; echo i2c-OVTI02C1:00 > /sys/bus/i2c/drivers/ov02c10/bind 2>/dev/null; sleep 1; done'
```

If you see `ov02c10 i2c-OVTI02C1:00: probe failed with error -517` (EPROBE_DEFER) followed by `Intel CVS driver: Transfer of ownership success` in dmesg, the sensor auto-retried and this drop-in is a no-op. If you instead see two consecutive `-121` (EREMOTEIO) failures with no success, this drop-in is required.

2c. **Use a v4l2-relayd that understands v4l2loopback ≥ 0.13.**

The `v4l2-relayd` 0.2.0 package subscribes to the old
`V4L2_EVENT_PRI_CLIENT_USAGE` event ID. v4l2loopback moved that ID in v0.13,
so the daemon never learns that an app opened the virtual camera and never
starts the real pipeline (symptom: apps get one frozen splash frame, LED never
turns on, nothing in the journal). Upstream fixed it in commit `0531139`.
Build the fixed daemon and point the service at it:

```bash
git clone https://gitlab.com/vicamo/v4l2-relayd.git
cd v4l2-relayd
gcc -O2 -DV4L2_RELAYD_VERSION='"0.4.0-fixed"' -o v4l2-relayd src/v4l2-relayd.c \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 glib-2.0 gio-2.0)
sudo install -m755 v4l2-relayd /usr/local/bin/v4l2-relayd
```

- Create `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/fixed-binary.conf`
  with the template's `ExecStart` line, but running
  `/usr/local/bin/v4l2-relayd` instead of `/usr/bin/v4l2-relayd`:

```ini
[Service]
# Use locally built v4l2-relayd (upstream main) whose V4L2_EVENT_PRI_CLIENT_USAGE
# ID matches v4l2loopback >= 0.13; Arch's 0.2.0 binary never receives client events.
ExecStart=
ExecStart=/bin/sh -c 'DEVICE=$(grep -l -m1 -E "^${CARD_LABEL}$" /sys/devices/virtual/video4linux/*/name | cut -d/ -f6); exec /usr/local/bin/v4l2-relayd -i "${VIDEOSRC}" $${SPLASHSRC:+-s "${SPLASHSRC}"} -o "appsrc name=appsrc caps=video/x-raw,format=${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE} ! videoconvert ! v4l2sink name=v4l2sink device=/dev/$${DEVICE}" $EXTRA_OPTS'
```

3. **Turn the service on:**

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now v4l2-relayd@intel-ipu.service
   ```

Once this is running, the camera's LED will light up only when an application opens `/dev/video48`, and turn off again once that app closes it.

## Step 7 — Manual on-demand script (optional)

- Route the camera feed to v4l2sink and give it a /dev/video48 device file

```bash
./run-webcam.sh
```

- Route the camera to `autovideosink` and see the feed with GStreamner (autovideosink)

```bash
./camera-on-test.sh
```

NOTE: `run-webcam.sh` only *feeds* the virtual camera — it opens no window, so
"nothing happening" is normal. To actually see yourself, open
`/dev/video48` from a second terminal (`ffplay -f v4l2 -i /dev/video48`) or
any webcam app while it runs. (Earlier versions of this guide mentioned
`ipu6-camera-*.service` files; those don't exist on this system.)

- Other diagnostic scripts

This repository also includes [`camera-check.sh`](camera-check.sh), a script that checks driver versions, recent log messages, and the camera's status all in one go — handy if something isn't working and you want a quick overview. It must be run as root (it refuses otherwise):

```bash
sudo ./camera-check.sh
```

- Turn the camera on and use `ffplay` to see the stream on the device file
  - To list devices, do `v4l2-ctl --list-devices`

```
# GStreamer to loop back the feed with v4l2

gst-launch-1.0 icamerasrc device-name=0 ! queue ! videoconvert ! video/x-raw,format=NV12 ! videoflip method=rotate-180 ! videoconvert ! v4l2sink name='v4l2sink-0' device=/dev/video48
```

```
# View the live stream in another window

ffplay -f v4l2 -i /dev/video48

# Or, a quick test that just counts frames without opening a window

v4l2-ctl --device /dev/video48 --stream-mmap --stream-count=15
```

- Also validate with `qcam` directly (Intel's hardware abstraction layer libcamhal).

- Successful output below.  A view of the camera stream (flipped upside down) is displayed:

```bash
$ qcam
[1367532]  INFO Camera camera_manager.cpp:340 libcamera v0.7.0+ov01a10.2
CamHAL[INF] aiqb file name OV02C10_1BG203N3_ADL.aiqb
CamHAL[INF] aiqb file name OV02C10_1BG203N3_ADL.aiqb
CamHAL[INF] aiqb file name OV02C10_1SG204N3_ADL.aiqb
CamHAL[INF] aiqb file name OV02C10_1SG204N3_ADL.aiqb
CamHAL[INF] aiqb file name OV02C10_CIFME14_ADL.aiqb
CamHAL[INF] aiqb file name OV02C10_CIFME14_ADL.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
[1367536]  INFO IPU6 ipu6.cpp:714 Found 7 IPU6 camera(s) via libcamhal
[1367536]  INFO IPU6 ipu6.cpp:175 Found IPU6 camera 0: ov02c10-uf (facing=0)
[1367536]  INFO Camera camera_manager.cpp:223 Adding camera 'ipu6-ov02c10-uf-0' for pipeline handler ipu6
[1367532]  INFO Camera camera.cpp:1216 configuring streams: (0) 1280x720-NV12/sYCC
[1367536]  INFO IPU6 ipu6.cpp:232 Opening camera device 0
[1367536]  INFO IPU6 ipu6.cpp:240 Camera device 0 opened successfully
[1367536]  INFO IPU6 ipu6.cpp:276 Configured HAL stream: 1280x720 NV12, stream_id=0 size=1382400
Using software format conversion from NV12
[1367536]  INFO IPU6 ipu6.cpp:327 Streaming started for camera 0
qt.accessibility.atspi: AtSpiAdaptor::applicationInterface does not implement "GetApplicationBusAddress" "/org/a11y/atspi/accessible/root"
[1367536]  INFO IPU6 ipu6.cpp:374 Streaming stopped for camera 0
```

- Validate `dmesg` output by finding the following messages

```
intel-ipu6 0000:00:05.0: enabling device (0000 -> 0002)
intel-ipu6 0000:00:05.0: Found supported sensor OVTI02C1:00
intel-ipu6 0000:00:05.0: Connected 1 cameras
intel-ipu6 0000:00:05.0: Sending BOOT_LOAD to CSE
intel-ipu6 0000:00:05.0: Sending AUTHENTICATE_RUN to CSE
intel-ipu6 0000:00:05.0: CSE authenticate_run done
intel-ipu6 0000:00:05.0: IPU6-v4[7d19] hardware version 6
Intel CVS driver i2c-INTC10E0:00: cvs_common_probe:Transfer of ownership success
```

Then open any app that can use a webcam (a browser, Cheese, OBS) and select "Virtual_WebCam_0" from its camera list. The LED next to the camera should light up only while that app is actively using it — and turn off once you close the app or switch to a different camera.

If something isn't working, check the **Troubleshooting** section below.

## Step 8 — Make desktop apps see the camera (GNOME Camera, browsers, PipeWire)

Modern GNOME apps (Camera/Snapshot, and browsers using the portal) don't open
`/dev/video48` directly — they ask the **xdg camera portal**, which lists
cameras from **PipeWire**, whose video devices are managed by **WirePlumber**.
Three things break that chain out of the box:

1. The portal only offers PipeWire nodes tagged `media.role = Camera`; the
   v4l2loopback node isn't tagged by default, so GNOME Camera sees nothing.
2. WirePlumber creates nodes for all 48 raw IPU6 ISYS devices
   (`/dev/video0`–`47`). They can't produce video, and they flood every picker.
3. If `pipewire-libcamera` + `libcamera-ipu6` are installed, WirePlumber's
   libcamera monitor grabs the same IPU6 kernel nodes as the relay's CamHAL
   (symptom in the relay log: `VIDIOC_REQBUFS error: Device or resource busy`).
   Only one stack may own the hardware — we use the relay.

- Create `/etc/wireplumber/wireplumber.conf.d/50-hide-ipu6-isys.conf`:

```ini
wireplumber.profiles = {
  main = {
    monitor.libcamera = disabled
  }
}

monitor.v4l2.rules = [
  {
    matches = [
      {
        api.v4l2.cap.driver = "isys"
      }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
  {
    matches = [
      {
        node.name = "v4l2_input._sys_devices_virtual_video4linux_video48"
      }
    ]
    actions = {
      update-props = {
        media.role = "Camera"
        node.description = "Built-in Webcam"
        priority.session = 1000
      }
    }
  }
]
```

- Set `exclusive_caps=1` in `/etc/modprobe.d/v4l2loopback.conf` so apps that
  probe V4L2 directly (Chrome, Zoom, Discord) treat the device as a real
  capture-only webcam:

```
options v4l2loopback video_nr=48 card_label="Virtual_WebCam_0" exclusive_caps=1
```

- Apply (order matters — the relay must be streaming before WirePlumber probes
  the device, otherwise the node won't appear until WirePlumber restarts):

```bash
sudo systemctl stop v4l2-relayd@intel-ipu.service
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
sudo systemctl start v4l2-relayd@intel-ipu.service
systemctl --user restart wireplumber
```

- Hide the raw IPU6 nodes from apps that scan `/dev/video*` themselves
  (Electron apps like Hyperbeam and Discord, Chrome, Zoom). These apps
  enumerate every V4L2 device they can open and usually **default to the
  first one** — which would be a dead `ipu6` node. Only the root-owned
  v4l2-relayd pipeline needs those nodes, so root-lock them. The filename
  prefix `72-` matters: the rule must run after `70-uaccess.rules` (which
  tags video devices for per-user ACLs) and before `73-seat-late.rules`
  (which applies the ACLs).

- Create `/etc/udev/rules.d/72-camera-hide-ipu6-isys.rules`
  (also in this repo as [`72-camera-hide-ipu6-isys.rules`](72-camera-hide-ipu6-isys.rules)):

```
SUBSYSTEM=="video4linux", ATTR{name}=="Intel IPU6 ISYS Capture*", GROUP="root", MODE="0600", TAG-="uaccess"
```

```bash
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=video4linux
# clear ACLs that were granted before the rule existed:
for i in $(seq 0 47); do sudo setfacl -b /dev/video$i 2>/dev/null; done
systemctl --user restart wireplumber
```

- Verify: `v4l2-ctl --list-devices` (as your normal user) shows **only**
  `Virtual_WebCam_0`, and `wpctl status` shows exactly one video Source,
  "Built-in Webcam". GNOME Camera shows live video; browsers, Zoom, Discord
  and Hyperbeam now see a single camera and select it by default. Diagnostics
  against the raw nodes still work with sudo (e.g. `sudo v4l2-ctl -d0 --info`).

---

## Troubleshooting

**`gst-inspect-1.0 icamerasrc` → "No such element"**
The camera driver library (`libcamhal.so.0`) is missing or not registered
with the system. Reinstall it and refresh the library cache
`yay -S --rebuild --noconfirm intel-ipu6-camera-hal-git && sudo ldconfig`.

**Video is completely black**
Usually this means the wrong camera port is selected (`device-name` must be
`2`, not `0`), or there's a format-negotiation problem between GStreamer
components. Double-check `VIDEOSRC` in Step 7 matches exactly. If the
on-demand service keeps producing a black picture even with the right
settings, you can fall back to the always-on version described in the
Appendix below.

**`CamHAL[ERR] Failed to open PSYS, error: Permission denied`**
Your user account isn't in the `video` group yet, or you haven't logged out
and back in since Step 6.

**The service fails to start, or keeps restarting**
Look at its recent logs with:
```bash
sudo journalctl -u v4l2-relayd@intel-ipu.service -n 30
```
A common cause is a stale GStreamer cache for the root account — redo the
root half of Step 5. Another is `FRAMERATE=30` instead of `FRAMERATE=30/1`
in the Step 6 configs (see the note there).

**Apps only ever get one frozen frame from Virtual_WebCam_0, LED never lights**
Either the stock `v4l2-relayd` 0.2.0 binary is still in use (it can't hear
v4l2loopback ≥ 0.13 client events — see Step 6.2b), or the drop-in restoring
`CapabilityBoundingSet=~` is missing (icamerasrc then logs
`failed to open libcamhal device` — visible with `GST_DEBUG=2`).

**An Electron app (Hyperbeam, old Discord builds) says to check camera permission**
That's Electron's wrapper around a `getUserMedia` failure: with
`exclusive_caps=1` the virtual camera advertises only the relay's `FORMAT`,
and Chromium older than ~2023 can't capture NV12 over V4L2 — the camera is
invisible to it. Make sure `FORMAT=I420` in the Step 6 configs (with the
trailing `videoconvert` in `VIDEOSRC`), then restart the relay and the app.

**A writer test worked once, then everything negotiates only BGR4 640x480**
v4l2loopback can get stuck on the first format a client fixed on the device
(check with `v4l2-ctl -d /dev/video48 --list-formats-out`). Clear it with:
```bash
sudo systemctl stop v4l2-relayd@intel-ipu.service
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
sudo systemctl start v4l2-relayd@intel-ipu.service
```

**The `ov02c10` driver isn't attached to the sensor at boot**
Run `ls /sys/bus/i2c/drivers/ov02c10/` — it should list `i2c-OVTI02C1:00`.
If it's empty, the USB bridge chip likely wasn't ready in time; the udev
rule from Step 3 is meant to fix this automatically, but you can also force
it by hand:
```bash
sudo modprobe -r ov02c10 && sudo modprobe ov02c10
```

**`VIDIOC_CREATE_BUFS returned -1 (Inappropriate ioctl for device)`**
This message is harmless. The virtual camera driver (`v4l2loopback`) doesn't
support one particular buffer-allocation method, so tools automatically fall
back to an older one — streaming still works fine.

**The camera's LED stays on all the time**
You're probably running the always-on pipeline from the Appendix instead of
the on-demand one from Step 7. Switch back with:
```bash
sudo systemctl disable --now ipu6-camera.service
sudo systemctl enable --now v4l2-relayd@intel-ipu.service
```

---

## Appendix — Always-on fallback (Method A)

If the on-demand setup from Step 7 turns out to be unreliable on your
machine (black frames, or the camera never quite negotiates correctly), this
simpler always-on setup is more robust — but as the name says, it keeps the
camera's LED lit the whole time your computer is on, since it never turns the
pipeline off.

```bash
sudo tee /etc/systemd/system/ipu6-camera.service > /dev/null << 'EOF'
[Unit]
Description=IPU6 Camera (OV02C10) to v4l2loopback bridge
After=systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/bin/gst-launch-1.0 icamerasrc device-name=2 \
  ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 \
  ! videoflip method=rotate-180 \
  ! videoconvert \
  ! video/x-raw,format=I420 \
  ! v4l2sink device=/dev/video48
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
# Switch from the on-demand service to this one:
sudo systemctl disable --now v4l2-relayd@intel-ipu.service
sudo systemctl enable --now ipu6-camera.service
```
