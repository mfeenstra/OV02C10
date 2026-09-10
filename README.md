# Intel IPU6 MIPI Webcam Bring-up (OmniVision OV02C10 / OVTI02C1)

This repository provides configuration files, helper scripts, and documentation for getting the built-in MIPI camera working on a **Dell XPS 14 (DA14250)** (or similar systems using Meteor Lake processors and Intel IPU6) running Linux (specifically tested on Arch Linux with Kernel 7+).

The camera sensor is an **OmniVision OV02C10** (ACPI ID: `OVTI02C1`) routed through an **Intel IPU6** image signal processor. Unlike standard USB webcams that support the UVC (USB Video Class) protocol, this sensor uses a custom capture pipeline and proprietary HAL.

---

## Architecture & Data Flow

Below is the layout of the working on-demand capture pipeline:

```
OV02C10 Sensor ──(MIPI-CSI-2)──> Lattice AI USB Bridge ──(Internal USB)──> CPU
                                                                            │
                                                   ┌────────────────────────┴────────────────────────┐
                                                   │  Intel CVS (INTC10E0) Handshake (Ownership)     │
                                                   │  ov02c10 i2c Device Driver Initialization       │
                                                   └────────────────────────┬────────────────────────┘
                                                                            │
                                                                 IPU6 Raw Capture Nodes
                                                            (/dev/video0-47, root-only access)
                                                                            │
                                                                            ▼
                                                                 GStreamer `icamerasrc`
                                                                (libcamhal system service)
                                                                            │
                                                                            ▼
                                                               v4l2-relayd (On-Demand Relay)
                                                                            │
                                                                            ▼
                                                                  v4l2loopback Device
                                                             /dev/video48 "Virtual_WebCam_0"
                                                                            │
                                                                            ▼
                                                              Applications (via PipeWire Portal)
                                                               (Cheese, Zoom, OBS, Browsers)
```

WirePlumber is configured to disable its own `libcamera` monitor (which would otherwise compete with the relay for the hardware) and hide the 48 raw ISYS nodes. Consequently, `wpctl status` and the PipeWire camera portal see only one video source: `Virtual_WebCam_0` ("Built-in Webcam").

---

## Repository Structure

To keep the repository clean and intuitive, files are organized to match their target paths under `/etc` on the host system:

```
.
├── etc/
│   ├── default/
│   │   └── v4l2-relayd                 # Global v4l2-relayd service defaults
│   ├── modprobe.d/
│   │   ├── ipu6-camera.conf            # Soft dependencies for module load order
│   │   └── v4l2loopback.conf           # Options for the v4l2loopback virtual device
│   ├── modules-load.d/
│   │   ├── camera.conf                 # Loads sensor and bridge modules
│   │   ├── intel-ipu6.conf             # Loads core IPU6 modules
│   │   └── v4l2loopback.conf           # Loads the loopback module
│   ├── systemd/
│   │   └── system/
│   │       └── v4l2-relayd@intel-ipu.service.d/
│   │           ├── fixed-binary.conf   # Override to execute locally compiled v4l2-relayd
│   │           └── icamerasrc.conf     # Drops PrivateIPC / restores capability bounds
│   ├── tmpfiles.d/
│   │   └── intel-camera.conf           # Allocates /run/camera directory with correct perms
│   ├── udev/
│   │   └── rules.d/
│   │       ├── 72-camera-hide-ipu6-isys.rules # Hides /dev/video0-47 from normal users
│   │       └── 99-camera.rules         # Udev rules for group access and i2c bind workaround
│   ├── v4l2-relayd.d/
│   │   ├── intel-ipu.conf              # GStreamer pipeline format and parameters
│   │   └── images/
│   │       └── waiting.jpg             # Standby image displayed when camera is inactive
│   └── wireplumber/
│       └── wireplumber.conf.d/
│           └── 50-hide-ipu6-isys.conf  # Disables libcamera monitor & hides raw ISYS nodes
├── scripts/
│   ├── camera-check.sh                 # Comprehensive diagnostic script (must run as root)
│   ├── camera-on-test.sh               # Simple script to preview live camera via autovideosink
│   ├── fix-stuck-webcam-node.sh        # Fixes stuck PipeWire node issues (VIDIOC_S_FMT busy)
│   └── run-webcam.sh                   # Feeds the camera stream into /dev/video48 manually
├── pkglist.txt                         # Working snapshot package list (Arch Linux)
└── README.md                           # This guide
```

---

## Installation & Setup Instructions

### Step 1: Install Driver Modules and Helper Utilities

Ensure you have the required IPU6 driver packages, GStreamer plugins, and utilities installed. A point-in-time snapshot of package configurations is provided in [pkglist.txt](pkglist.txt). 

For Arch Linux, packages are available in the official repos and AUR:
* **`intel-ipu6-dkms-git`**: Main kernel driver modules for Intel IPU6.
* **`intel-ipu6-camera-bin`**: Proprietary firmware files and calibration binaries.
* **`intel-ipu6-camera-hal-git`**: Camera Hardware Abstraction Layer (`libcamhal`).
  - For unused variable compile errors, add the following to your `PKGBUILD` `build()` block: `sed -i 's/-Werror//g' $_pkgname/CMakeLists.txt`
* **`libcamera-ipu6`**: Linux support library for complex cameras and the Intel IPU6 pipeline.
  - For install failure related to post-build testing of `v4l2_compat`, append `| grep -v v4l2_comat` to the `PKGBUILD` `check()` block's `tests=` expression.
* **`icamerasrc-git`**: GStreamer source plugin to interface with `libcamhal`.
* **`v4l2loopback-dkms`**: Kernel module for virtual loopback devices.
* **`v4l2-relayd`**: Daemon to pipe GStreamer frames into loopback.

> [!TIP]
> **AUR Build Note (`libcamera-ipu6`)**: The package `PKGBUILD` has a bug where it references relative paths `../` assuming the default build directory. If you run a custom `BUILDDIR` in your AUR helper config, manually edit the `PKGBUILD` to change `../` references to use `"$srcdir"/` instead.

Ensure the driver module is registered:
```bash
modinfo ov02c10 | grep -E "filename|depends|alias"
```
*Expected Output:*
```
filename:       /lib/modules/.../updates/dkms/ov02c10.ko.zst
alias:          acpi*:OVTI02C1:*
depends:        videodev,v4l2-fwnode,mc,v4l2-async
```

---

### Step 2: Deploy Configuration Files

Copy the configuration tree from the repository to your system:
```bash
# Execute from the root of this repository
sudo cp -r etc/* /etc/
```

This installs configurations for module loading, permissions, udev rules, WirePlumber, and systemd overrides.

---

### Step 3: Build & Install Fixed `v4l2-relayd`

The official `v4l2-relayd` 0.2.0 package is broken on systems running `v4l2loopback` version 0.13 or newer due to a change in the event API ID. Without this fix, the service will never detect when an application starts or stops the webcam stream.

To compile and link the fixed daemon from upstream:
```bash
git clone https://gitlab.com/vicamo/v4l2-relayd.git
cd v4l2-relayd
gcc -O2 -DV4L2_RELAYD_VERSION='"0.4.0-fixed"' -o v4l2-relayd src/v4l2-relayd.c \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 glib-2.0 gio-2.0)
sudo install -m755 v4l2-relayd /usr/local/bin/v4l2-relayd
```

The systemd drop-in file `etc/systemd/system/v4l2-relayd@intel-ipu.service.d/fixed-binary.conf` already configures systemd to run this newly built binary from `/usr/local/bin/` instead of the packaged version in `/usr/bin/`.

---

### Step 4: Refresh GStreamer Plugin Cache

GStreamer maintains a registry of available plugins, including the Intel IPU6 source (`icamerasrc`). This cache can go stale. Rebuild the registry for both your user account and root (since the systemd relay service runs as root):

```bash
# Clear normal user cache
rm -f ~/.cache/gstreamer-1.0/registry.*.bin
gst-inspect-1.0 icamerasrc | head -n 3

# Clear root cache
sudo rm -f /root/.cache/gstreamer-1.0/registry.*.bin
sudo gst-inspect-1.0 icamerasrc | head -n 3
```
Both commands must successfully print details of the `icamerasrc` element without showing "No such element".

---

### Step 5: Assign Permissions and Apply Configurations

1. Grant your local user account permission to access the video and GPU render nodes:
   ```bash
   sudo usermod -aG video,render $USER
   ```
   > [!IMPORTANT]
   > You must log out and log back in (or reboot) for these group changes to take effect.

2. Reload configurations and reload the kernel modules in the correct sequence:
   ```bash
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
   ```

---

### Step 6: Verify and Test

1. Verify that your normal user account can only see the virtual device node:
   ```bash
   v4l2-ctl --list-devices
   ```
   *Expected Output:*
   ```
   Virtual_WebCam_0 (platform:v4l2loopback-048):
       /dev/video48
   ```

2. Verify that PipeWire only detects one video source (the virtual loopback node):
   ```bash
   wpctl status
   ```
   The "Video" section should list exactly one source: `Built-in Webcam`.

3. Run the automated diagnostic script to check driver states and kernel logs:
   ```bash
   sudo ./scripts/camera-check.sh
   ```

4. Verify live video stream using the test script (opens a preview window):
   ```bash
   ./scripts/camera-on-test.sh
   ```

---

## Troubleshooting

### `gst-inspect-1.0 icamerasrc` prints "No such element"
* **Cause**: GStreamer cannot find or load the camera driver library (`libcamhal.so.0`).
* **Fix**: Reinstall the camera HAL package and rebuild the system library cache:
  ```bash
  yay -S --rebuild --noconfirm intel-ipu6-camera-hal-git && sudo ldconfig
  ```
  Ensure you cleared GStreamer's registry cache for both `user` and `root` as outlined in Step 4.

### Video stream is completely black
* **Cause**: The pipeline is pointed at the wrong device port (e.g. `device-name=0` instead of `device-name=2`), or GStreamer format negotiation failed.
* **Fix**: Verify your configurations in `etc/v4l2-relayd.d/intel-ipu.conf`. The source must specify `icamerasrc device-name=2`. If GStreamer negotiation is still failing, fall back to the always-on pipeline in Appendix A.

### `CamHAL[ERR] Failed to open PSYS, error: Permission denied`
* **Cause**: Your user account lacks permission to interact with the raw video device interfaces.
* **Fix**: Ensure your user is added to the `video` and `render` groups (see Step 5) and that you have logged out and back in to apply changes.

### The relay service fails to start or keeps restarting
* **Cause**: A malformed parameter exists in the configuration files (like setting `FRAMERATE=30` instead of a fraction `30/1`), or GStreamer's cache is corrupt.
* **Fix**: Check systemd logs:
  ```bash
  sudo journalctl -u v4l2-relayd@intel-ipu.service -n 30
  ```
  Ensure `/etc/v4l2-relayd.d/intel-ipu.conf` has `FRAMERATE=30/1`. Re-run the GStreamer cache clear steps for the root user.

### Apps show one frozen frame from `/dev/video48` and the camera LED stays off
* **Cause**: The system is using the outdated `v4l2-relayd` 0.2.0 package which cannot detect newer `v4l2loopback` client events, or the drop-in to restore process capabilities is missing.
* **Fix**: Compile the fixed `v4l2-relayd` binary and apply the systemd drop-ins as detailed in Step 3. Check logs for capability errors with `GST_DEBUG=2`.

### Electron apps (Discord, Chromium, etc.) fail to see the camera or request permissions
* **Cause**: Electron's capture engine does not support the default `NV12` format when querying loopback video nodes.
* **Fix**: Ensure that the pipeline output format is set to `I420` (not `NV12`) and ends with a `videoconvert` filter. Check that `/etc/v4l2-relayd.d/intel-ipu.conf` matches the files in the repository.

### PipeWire apps (Cheese, browsers, OBS) fail or freeze, but `ffplay` works fine
* **Cause**: WirePlumber's PipeWire v4l2 source node gets stuck in an active streaming state, logging `spa.v4l2: '/dev/video48' VIDIOC_S_FMT: Device or resource busy`. The kernel refuses to change format options while the interface is streaming.
* **Fix**: Run the reset script provided in the repository. This kills stale processes, destroys the stuck PipeWire node, and cycles the udev registration:
  ```bash
  sudo ./scripts/fix-stuck-webcam-node.sh
  ```

### The `ov02c10` driver is not bound to the sensor at boot
* **Cause**: The Lattice USB bridge chip initialized slower than the sensor driver probe.
* **Fix**: The udev rule in `etc/udev/rules.d/99-camera.rules` is configured to handle this bind workaround. If it fails, manually force a reload of the kernel modules:
  ```bash
  sudo modprobe -r ov02c10 && sudo modprobe ov02c10
  ```

---

## Appendix A: Always-on Fallback (Method A)

If the recommended on-demand relay pipeline in Step 5 is unstable or produces black frames on your hardware, you can deploy a simpler, always-on fallback. This bypasses `v4l2-relayd` entirely but keeps the camera's LED lit as long as the service is running.

1. Write the fallback service file:
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
   ```

2. Enable the fallback service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl disable --now v4l2-relayd@intel-ipu.service
   sudo systemctl enable --now ipu6-camera.service
   ```

---

## Appendix B: Application Compatibility Matrix

Not every video app that can open a camera will work here — which ones do depends on *how* they get frames. There are three distinct paths into the pipeline, and they don't all coexist:

- **(a) PipeWire/portal path** — the app asks the xdg camera portal, which hands it a PipeWire stream from WirePlumber's node for `Virtual_WebCam_0`. This is the intended path.
- **(b) Direct V4L2 path** — the app opens `/dev/video48` itself, bypassing PipeWire.
- **(c) Direct libcamera path** — the app talks to `libcamera`/the OV02C10 sensor directly, bypassing `/dev/video48` and the relay entirely. This conflicts with the relay's own exclusive libcamera acquisition (`icamerasrc`, inside `v4l2-relayd@intel-ipu.service`) — only one libcamera client can hold a camera at a time.

| App(s) | Path | Result | Why |
|---|---|---|---|
| Cheese, GNOME Camera/Snapshot, browsers (Chrome/Firefox WebRTC), Zoom, Discord, OBS (PipeWire Camera source) | (a) portal → PipeWire | **Works** | Intended path — target apps. |
| `qv4l2`, `ffmpeg` | (b) direct V4L2, `read()` capture | **Works** | Opens its own fresh handle instead of reusing/reformatting PipeWire's — no `VIDIOC_S_FMT`/`REQBUFS` collision. |
| `guvcview` | (b) direct V4L2, `mmap` capture | **Fails** — `VIDIOC_REQBUFS`/`VIDIOC_S_FORMAT: Device or resource busy` | PipeWire already holds the loopback's one mmap buffer allocation (`v4l2loopback` here is `max_buffers: 2`, no room for a second independent mmap owner). |
| `qcam` | (c) direct libcamera | **Fails** — can't acquire the camera | The relay's `icamerasrc` already holds the only libcamera acquisition on the sensor 24/7. |
