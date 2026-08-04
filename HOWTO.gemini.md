# HOWTO: Get the OVTI02C1 (OmniVision OV02C10) Webcam Working on Dell XPS 14 DA14250 (Arch Linux)

This step-by-step guide walks through configuring the built-in webcam on a **Dell XPS 14 DA14250** running Arch Linux and Linux Kernel 7+.

By the end of this guide, your camera will function as a standard webcam: the camera's LED indicator will light up only when an application (browser, Zoom, OBS, Cheese, etc.) is actively capturing video, or when manually testing with the provided utility scripts.

---

## Hardware Architecture & Data Flow

Standard USB webcams conform to the UVC (USB Video Class) protocol and work out-of-the-box on Linux. This laptop's camera uses a more complex, multi-chip processing architecture:

| Component | Specifications |
| :--- | :--- |
| **Laptop Model** | Dell XPS 14 DA14250 |
| **Camera Sensor** | OmniVision OV02C10 (ACPI ID: `OVTI02C1`), 2 Megapixels |
| **Image Signal Processor** | Intel IPU6 (PCI ID: `8086:7d19`, Meteor Lake CPU generation, HAL variant `ipu6epmtl`) |
| **USB Bridge** | Lattice AI USB 2.0 Bridge (VID: `2ac1`, PID: `20c9`) on internal USB port 3-9 |
| **CVS Subsystem** | Intel Computer Vision Subsystem (`INTC10E0`) firmware handshake driver |

The camera sensor is not connected directly to the CPU's I2C system bus. Instead, it sits behind the Lattice USB bridge. The Linux kernel can only communicate with the sensor once the Intel CVS driver has performed a "Transfer of Ownership" handshake with the bridge firmware:

```
OV02C10 sensor ──(MIPI-CSI-2)──> Lattice AI USB Bridge ──(USB Port 3-9)──> CPU
                                                                 │
                                                   ┌─────────────┴─────────────┐
                                                   │       usbio-i2c driver    │
                                                   │  i2c-INTC10E0:00 (CVS)    │
                                                   │  i2c-OVTI02C1:00 (sensor) │
                                                   └───────────────────────────┘
```

---

## Summary of Known Issues & Core Steps

| # | Problem | Symptom | Addressed In |
|---|---|---|---|
| **1** | Kernel attempts to probe the camera sensor before the CVS firmware handshake is complete. | `ov02c10: failed to find sensor: -121` on boot; camera fails to initialize. | [Step 1: Module Load Order](#step-1-install-required-software--configure-module-load-order) |
| **2** | Camera device nodes are locked to the `root` user. | `Permission denied` when opening `/dev/ipu-psys0` or video nodes. | [Step 2: Device Permissions](#step-2-configure-device-permissions-udev-rules) |
| **3** | The proprietary Hardware Abstraction Layer (HAL) library or sensor profiles are missing. | HAL errors in logs or apps fail to initialize the pipeline. | [Step 3: HAL & Calibration Calibration](#step-3-verify-hardware-abstraction-layer-hal--calibration-data) |
| **4** | GStreamer's plugin registry cache is out-of-date. | GStreamer says `No such element` for the `icamerasrc` plugin. | [Step 4: GStreamer Registry Cache](#step-4-refresh-gstreamer-plugin-cache) |
| **5** | User account lacks hardware access. | Apps cannot communicate with the camera. | [Step 5: User Permission Groups](#step-5-assign-user-permission-groups) |
| **6** | Shared-memory IPC allocation requires high system privileges. | `CamHAL[ERR] Fail to allocate shared memory` in logs. | [Step 6: On-Demand Service Setup](#step-6-configure-the-on-demand-relay-service-v4l2-relayd) |
| **7** | The physical camera sensor is mounted upside down. | Live video is rotated 180°. | [Step 6: On-Demand Service Setup](#step-6-configure-the-on-demand-relay-service-v4l2-relayd) |
| **8** | The default `v4l2-relayd` is incompatible with newer `v4l2loopback`. | Loopback device fails to stream frames; LED stays off. | [Step 6: On-Demand Service Setup](#step-6-configure-the-on-demand-relay-service-v4l2-relayd) |
| **9** | Raw IPU6 nodes flood app pickers and conflict with the relay. | Apps display dozens of dead camera sources. | [Step 7: PipeWire & Desktop Integration](#step-7-configure-pipewire-wireplumber-and-desktop-integration) |

---

## Step-by-Step Setup Flow

### Step 1: Install Required Software & Configure Module Load Order

You need the IPU6 kernel drivers, GStreamer plugins, and relay daemon. A full, point-in-time snapshot of the installed packages on a working system is available in [pkglist.txt](file:///home/matt/projects/OVTI02C1/pkglist.txt). 

The primary packages required from the official repositories and AUR are:
* **`intel-ipu6-dkms-git`**: Main kernel driver modules for Intel IPU6.
* **`intel-ipu6-camera-bin`**: Proprietary firmware files and binaries.
* **`intel-ipu6-camera-hal-git`**: Camera Hardware Abstraction Layer (`libcamhal`).
* **`icamerasrc-git`**: GStreamer source plugin to interface with `libcamhal`.
* **`v4l2loopback-dkms`**: Kernel module to create virtual loopback video devices.
* **`v4l2-relayd`**: Relay daemon to pipe frames from GStreamer to the loopback device.

> [!TIP]
> **AUR Build Note (`libcamera-ipu6`)**: The package `PKGBUILD` has a bug where it references relative paths `../` assuming the default build directory. If you run a custom `BUILDDIR` in your AUR helper config, manually edit the `PKGBUILD` to change `../` references to use `"$srcdir"/` instead.

#### Verify the Driver Module
Check that the kernel module is successfully registered:
```bash
modinfo ov02c10 | grep -E "filename|depends|alias"
```
*Expected Output:*
```
filename:       /lib/modules/.../updates/dkms/ov02c10.ko.zst
alias:          acpi*:OVTI02C1:*
depends:        videodev,v4l2-fwnode,mc,v4l2-async
```

#### Configure Module Loading
To ensure modules are loaded at boot time and in the correct sequence, place the following configuration files into `/etc/`:

1. **Kernel Modules Lists** (tells the system which modules to load):
   * Copy [camera.conf](file:///home/matt/projects/OVTI02C1/camera.conf) to `/etc/modules-load.d/camera.conf` (loads discrete sensor drivers).
   * Copy [intel-ipu6.conf](file:///home/matt/projects/OVTI02C1/intel-ipu6.conf) to `/etc/modules-load.d/intel-ipu6.conf` (loads IPU6 components).
   * Copy [modules-load.d-v4l2loopback.conf](file:///home/matt/projects/OVTI02C1/modules-load.d-v4l2loopback.conf) to `/etc/modules-load.d/v4l2loopback.conf` (loads the loopback system).

2. **Soft Dependencies** (forces the strict loading sequence required for the CVS handshake):
   * Copy [ipu6-camera.conf](file:///home/matt/projects/OVTI02C1/ipu6-camera.conf) to `/etc/modprobe.d/ipu6-camera.conf`. This mandates that the modules load in this order: `intel_cvs` -> `intel_ipu6` -> `intel_ipu6_isys` -> `ov02c10` -> `v4l2loopback`.

3. **Runtime AIQ Directory**:
   * Copy [intel-camera.conf](file:///home/matt/projects/OVTI02C1/intel-camera.conf) to `/etc/tmpfiles.d/intel-camera.conf` to automatically allocate `/run/camera` at boot for the Intel AIQ (Auto Image Quality) subsystem.

#### Reboot and Verify
Reboot your machine. Check the system log to confirm that the driver probed successfully after the ownership handshake:
```bash
dmesg | grep -E "ov02c10|CVS"
```
*Expected Output:*
```
ov02c10 i2c-OVTI02C1:00: failed to find sensor: -121   # Initial attempt fails (bridge locked)
ov02c10 i2c-OVTI02C1:00: probe failed with error -517  # Defers probe to wait for CVS
Intel CVS driver: Transfer of ownership success       # Handshake completes
ov02c10 i2c-OVTI02C1:00: sensor identified: ov02c10 2.0MP  # Success on retry
```
Ensure the driver is attached to the sensor device:
```bash
ls /sys/bus/i2c/drivers/ov02c10/
# Expected: i2c-OVTI02C1:00
```

---

### Step 2: Configure Device Permissions (udev rules)

A custom udev rule is required to make the camera's raw hardware and virtual devices group-accessible, and to automatically reconnect the I2C sensor driver interface if the system bus resets:

1. Copy the permission rule:
   ```bash
   sudo cp 99-camera.rules /etc/udev/rules.d/99-camera.rules
   ```
   *(Review the rule contents at [99-camera.rules](file:///home/matt/projects/OVTI02C1/99-camera.rules))*

2. Reload the rules and trigger the changes:
   ```bash
   sudo udevadm control --reload
   sudo udevadm trigger
   ```

---

### Step 3: Verify Hardware Abstraction Layer (HAL) & Calibration Data

The IPU6 pipeline relies on a proprietary Hardware Abstraction Layer library (`libcamhal.so.0`) and target sensor calibration profiles located in `/etc/camera`.

1. Verify the library is present:
   ```bash
   ls /usr/lib/libcamhal.so.0
   ```
   If it is missing, rebuild the HAL package and update the dynamic linker cache:
   ```bash
   yay -S intel-ipu6-camera-hal-git
   sudo ldconfig
   ```

2. Verify the configuration and calibration files:
   For this Meteor Lake system, the camera profiles must reside in the target directory `ipu6epmtl`. To maintain compatibility with packages expecting Alder Lake generic names, you must configure symbolic links in `/etc/camera/` as follows:
   ```
   /etc/camera/
   ├── ipu6 -> ipu6epmtl               # Symlink to Meteor Lake profile
   ├── ipu6ep -> ipu6epmtl             # Symlink to Meteor Lake profile
   ├── ipu6epmtl/                      # Target platform directory
   │   ├── OV02C10_*.aiqb              # Tuning blobs
   │   ├── libcamhal_profile.xml
   │   ├── psys_policy_profiles.xml
   │   └── sensors/
   │       └── ov02c10-uf.xml          # Sensor configuration
   ├── sensors/
   │   └── ov2740-uf.xml               # Unused profile
   └── OV02C10.aiqd                    # Symlink to ipu6epmtl/ov02c10-uf_VIDEO.aiqd
   ```
   Ensure these symlinks exist and point to the `ipu6epmtl` directory. If missing, reinstall the HAL and firmware packages.

---

### Step 4: Refresh GStreamer Plugin Cache

GStreamer caches its registry of available plugins, including the Intel IPU6 source (`icamerasrc`). This cache can go stale, preventing the driver from loading. Clear and rebuild the registry for both your normal user account and root (since the systemd relay service runs under root):

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

### Step 5: Assign User Permission Groups

Grant your local user account permission to access the video and GPU render nodes:
```bash
sudo usermod -aG video,render $USER
```
> [!IMPORTANT]
> You must **log out and log back in** (or reboot) for these group changes to apply before proceeding.

---

### Step 6: Configure the On-Demand Relay Service (`v4l2-relayd`)

The on-demand architecture feeds GStreamer frames from the real camera into a virtual webcam device (`/dev/video48` or equivalent) managed by `v4l2loopback`. The camera pipeline is active only when an application opens this loopback device.

#### 1. Deploy Relay Configurations
Copy the configurations to their system paths:
* Copy [intel-ipu.conf](file:///home/matt/projects/OVTI02C1/intel-ipu.conf) to `/etc/v4l2-relayd.d/intel-ipu.conf` (configures GStreamer sourcing, 180° rotation correction via `videoflip`, and outputs I420 format for wide application compatibility).
* Copy [v4l2-relayd](file:///home/matt/projects/OVTI02C1/v4l2-relayd) to `/etc/default/v4l2-relayd` (sets global service parameters).

> [!NOTE]
> The per-instance configuration `/etc/v4l2-relayd.d/intel-ipu.conf` takes precedence over global variables defined in `/etc/default/v4l2-relayd`.

#### 2. Create the systemd Service Drop-In
Create the directory and copy the systemd unit modification:
```bash
sudo mkdir -p /etc/systemd/system/v4l2-relayd@intel-ipu.service.d/
sudo cp icamerasrc.conf /etc/systemd/system/v4l2-relayd@intel-ipu.service.d/icamerasrc.conf
```
*(Review drop-in settings at [icamerasrc.conf](file:///home/matt/projects/OVTI02C1/icamerasrc.conf). This disables `PrivateIPC` and restores system capabilities so the camera HAL can allocate shared memory).*

#### 3. Build & Install the Fixed `v4l2-relayd` Daemon
The official `v4l2-relayd` 0.2.0 package is broken on systems running `v4l2loopback` version 0.13 or newer due to a change in the event API ID. Without this fix, the service will never detect when an app starts/stops the webcam stream.

To compile and link the fixed daemon:
```bash
git clone https://gitlab.com/vicamo/v4l2-relayd.git
cd v4l2-relayd
gcc -O2 -DV4L2_RELAYD_VERSION='"0.4.0-fixed"' -o v4l2-relayd src/v4l2-relayd.c \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 glib-2.0 gio-2.0)
sudo install -m755 v4l2-relayd /usr/local/bin/v4l2-relayd
```

After building, install the drop-in that directs systemd to launch the new local binary:
* Copy [fixed-binary.conf](file:///home/matt/projects/OVTI02C1/fixed-binary.conf) to `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/fixed-binary.conf`.

#### 4. Enable and Start the Service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now v4l2-relayd@intel-ipu.service
```

---

### Step 7: Configure PipeWire, WirePlumber, and Desktop Integration

Modern desktop environments (like GNOME) and applications query cameras via **PipeWire** and **WirePlumber**. By default, WirePlumber exposes all 48 raw IPU6 input channels to users (which are dead nodes that cannot stream) and conflicts with `v4l2-relayd` for exclusive control of the camera hardware.

1. **Configure WirePlumber rules**:
   * Copy [50-hide-ipu6-isys.conf](file:///home/matt/projects/OVTI02C1/50-hide-ipu6-isys.conf) to `/etc/wireplumber/wireplumber.conf.d/50-hide-ipu6-isys.conf`.
   This disables WirePlumber's internal `libcamera` monitor, disables all raw `isys` drivers, tags `/dev/video48` with the correct `media.role = "Camera"`, and labels it as "Built-in Webcam".

2. **Configure Loopback module options**:
   * Copy [modprobe.d-v4l2loopback.conf](file:///home/matt/projects/OVTI02C1/modprobe.d-v4l2loopback.conf) to `/etc/modprobe.d/v4l2loopback.conf`.
   This forces `exclusive_caps=1` so direct V4L2 apps treat the loopback node as a capture-only webcam.

3. **Hide raw nodes from Electron/Chromium apps**:
   * Copy [72-camera-hide-ipu6-isys.rules](file:///home/matt/projects/OVTI02C1/72-camera-hide-ipu6-isys.rules) to `/etc/udev/rules.d/72-camera-hide-ipu6-isys.rules`.
   This ensures that the raw `/dev/video0`-`47` devices are locked to `root:root` with mode `0600`, removing the `uaccess` tag so user-space Chrome and Discord apps ignore them and default to the virtual loopback node.

4. **Apply Settings**:
   Execute the following sequence (order is critical to prevent WirePlumber from probing the virtual device before the relay has attached to it):
   ```bash
   # Stop the relay and reload v4l2loopback
   sudo systemctl stop v4l2-relayd@intel-ipu.service
   sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
   
   # Restart the relay
   sudo systemctl start v4l2-relayd@intel-ipu.service
   
   # Reload udev and clear stale user permissions
   sudo udevadm control --reload
   sudo udevadm trigger --subsystem-match=video4linux
   for i in $(seq 0 47); do sudo setfacl -b /dev/video$i 2>/dev/null; done
   
   # Restart WirePlumber
   systemctl --user restart wireplumber
   ```

---

### Step 8: Testing, Verification, and Diagnostics

Perform the following steps to confirm your camera is working correctly:

#### 1. Device Enumeration Checks
Verify that your normal user account can only see the virtual device node:
```bash
v4l2-ctl --list-devices
```
*Expected Output:*
```
Virtual_WebCam_0 (platform:v4l2loopback-048):
	/dev/video48
```
`wpctl status` should show a single video Source under the "Video" category:
```
Built-in Webcam
```

#### 2. Run Automated Diagnostics Script
Run the diagnostic script included in this repository to verify driver states and log entries:
```bash
sudo ./camera-check.sh
```
*(Review script contents at [camera-check.sh](file:///home/matt/projects/OVTI02C1/camera-check.sh))*

#### 3. Test Camera Stream Pipelines
* **Test the stream directly using GStreamer (opens a preview window)**:
  ```bash
  ./camera-on-test.sh
  ```
  *(Review script contents at [camera-on-test.sh](file:///home/matt/projects/OVTI02C1/camera-on-test.sh))*
  
* **Manually feed the loopback device**:
  ```bash
  ./run-webcam.sh
  ```
  *(Review script contents at [run-webcam.sh](file:///home/matt/projects/OVTI02C1/run-webcam.sh))*
  
* **View the loopback stream**:
  While the loopback is being fed, open a separate terminal and run:
  ```bash
  ffplay -f v4l2 -i /dev/video48
  ```
  Or verify that frames are being successfully received:
  ```bash
  v4l2-ctl --device /dev/video48 --stream-mmap --stream-count=15
  ```

---

## Troubleshooting

### Issue: `gst-inspect-1.0 icamerasrc` prints "No such element"
* **Cause**: GStreamer cannot find or load the camera driver library.
* **Fix**: Reinstall the camera HAL package and rebuild the system library cache:
  ```bash
  yay -S --rebuild --noconfirm intel-ipu6-camera-hal-git
  sudo ldconfig
  ```
  Also, make sure you cleared GStreamer's registry cache for both `user` and `root` as outlined in [Step 4](#step-4-refresh-gstreamer-plugin-cache).

### Issue: Video stream is completely black
* **Cause**: The pipeline is pointed at the wrong device port (e.g., `device-name=0` instead of `device-name=2`), or GStreamer format negotiation failed.
* **Fix**: Verify your configurations in [intel-ipu.conf](file:///home/matt/projects/OVTI02C1/intel-ipu.conf). The source must specify `icamerasrc device-name=2`. If GStreamer negotiation is still failing, fall back to the always-on pipeline in [Appendix A](#appendix-a:--always-on-fallback-method-a).

### Issue: `CamHAL[ERR] Failed to open PSYS, error: Permission denied`
* **Cause**: Your user account lacks permission to interact with the raw video device interfaces.
* **Fix**: Ensure your user is added to the `video` and `render` groups (see [Step 5](#step-5-assign-user-permission-groups)) and that you have logged out and back in to apply changes.

### Issue: The relay service fails to start or keeps restarting
* **Cause**: A malformed parameter exists in the configuration files (like setting `FRAMERATE=30` instead of a fraction `30/1`), or GStreamer's cache is corrupt.
* **Fix**: Check systemd logs:
  ```bash
  sudo journalctl -u v4l2-relayd@intel-ipu.service -n 30
  ```
  Ensure [intel-ipu.conf](file:///home/matt/projects/OVTI02C1/intel-ipu.conf) has `FRAMERATE=30/1`. Re-run the GStreamer cache clear steps for the root user.

### Issue: Apps show one frozen frame from `/dev/video48` and the camera LED stays off
* **Cause**: The system is using the outdated `v4l2-relayd` 0.2.0 package which cannot detect newer `v4l2loopback` client events, or the drop-in to restore process capabilities is missing.
* **Fix**: Compile the fixed `v4l2-relayd` binary and apply the systemd drop-ins as detailed in [Step 6](#step-6-configure-the-on-demand-relay-service-v4l2-relayd). Check logs for capability errors with `GST_DEBUG=2`.

### Issue: Electron apps (Discord, older Chromium, etc.) fail to see the camera or request permissions
* **Cause**: Electron's capture engine does not support the default `NV12` format when querying loopback video nodes.
* **Fix**: Ensure that the pipeline output format is set to `I420` (not `NV12`) and ends with a `videoconvert` filter. Check that `/etc/v4l2-relayd.d/intel-ipu.conf` matches the files in the repository.

### Issue: PipeWire apps (Cheese, browsers, OBS) fail or freeze, but `ffplay` works fine
* **Cause**: WirePlumber's PipeWire v4l2 source node gets stuck in an active streaming state, logging `spa.v4l2: '/dev/video48' VIDIOC_S_FMT: Device or resource busy`. The kernel refuses to change format options while the interface is streaming.
* **Fix**: Run the reset script provided in the repository. This kills stale processes, destroys the stuck PipeWire node, and cycles the udev registration:
  ```bash
  ./fix-stuck-webcam-node.sh
  ```
  *(See [fix-stuck-webcam-node.sh](file:///home/matt/projects/OVTI02C1/fix-stuck-webcam-node.sh) for details)*

### Issue: The `ov02c10` driver is not bound to the sensor at boot
* **Cause**: The Lattice USB bridge chip initialized slower than the sensor driver probe.
* **Fix**: The udev rule in `/etc/udev/rules.d/99-camera.rules` is configured to handle this bind workaround. If it fails, manually force a reload of the kernel modules:
  ```bash
  sudo modprobe -r ov02c10 && sudo modprobe ov02c10
  ```

### Issue: The camera's LED indicator stays on permanently
* **Cause**: The system is running the legacy always-on service instead of the on-demand relay service.
* **Fix**: Disable the legacy service and enable the on-demand service:
  ```bash
  sudo systemctl disable --now ipu6-camera.service
  sudo systemctl enable --now v4l2-relayd@intel-ipu.service
  ```

---

## Appendix A:  Always-on Fallback (Method A)

If the recommended on-demand relay pipeline in [Step 6](#step-6-configure the on-demand-relay-service-v4l2-relayd) is unstable or produces black frames on your hardware, you can deploy a simpler, always-on fallback. This bypasses `v4l2-relayd` entirely but keeps the camera's LED lit as long as the service is running.

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

## Appendix B: Repository File to System Path Mapping

The following table maps files in this repository to their target destination paths on your system:

| Repository File | Target System Path | Configured In | Purpose |
| :--- | :--- | :--- | :--- |
| [99-camera.rules](file:///home/matt/projects/OVTI02C1/99-camera.rules) | `/etc/udev/rules.d/99-camera.rules` | [Step 2](#step-2-configure-device-permissions-udev-rules) | Grants local user access to video/dma heap nodes; executes explicit i2c sensor bind. |
| [72-camera-hide-ipu6-isys.rules](file:///home/matt/projects/OVTI02C1/72-camera-hide-ipu6-isys.rules) | `/etc/udev/rules.d/72-camera-hide-ipu6-isys.rules` | [Step 7](#step-7-configure-pipewire-wireplumber-and-desktop-integration) | Locks raw `/dev/video0-47` nodes to `root:root 0600` so apps ignore them. |
| [intel-ipu.conf](file:///home/matt/projects/OVTI02C1/intel-ipu.conf) | `/etc/v4l2-relayd.d/intel-ipu.conf` | [Step 6.1](#1-deploy-relay-configurations) | GStreamer source pipeline configuration (rotation flip, formats, dimensions). |
| [v4l2-relayd](file:///home/matt/projects/OVTI02C1/v4l2-relayd) | `/etc/default/v4l2-relayd` | [Step 6.1](#1-deploy-relay-configurations) | Core settings and label mapping for the `v4l2-relayd` service. |
| [icamerasrc.conf](file:///home/matt/projects/OVTI02C1/icamerasrc.conf) | `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/icamerasrc.conf` | [Step 6.2](#2-create-the-systemd-service-drop-in) | systemd drop-in to relax IPC sharing and capabilities constraints. |
| [fixed-binary.conf](file:///home/matt/projects/OVTI02C1/fixed-binary.conf) | `/etc/systemd/system/v4l2-relayd@intel-ipu.service.d/fixed-binary.conf` | [Step 6.3](#3-build--install-the-fixed-v4l2-relayd-daemon) | systemd drop-in pointing `ExecStart` to the compiled, fixed relay daemon binary. |
| [50-hide-ipu6-isys.conf](file:///home/matt/projects/OVTI02C1/50-hide-ipu6-isys.conf) | `/etc/wireplumber/wireplumber.conf.d/50-hide-ipu6-isys.conf` | [Step 7](#step-7-configure-pipewire-wireplumber-and-desktop-integration) | WirePlumber profile disabling libcamera monitor and hiding raw `isys` nodes. |
| [modprobe.d-v4l2loopback.conf](file:///home/matt/projects/OVTI02C1/modprobe.d-v4l2loopback.conf) | `/etc/modprobe.d/v4l2loopback.conf` | [Step 7](#step-7-configure-pipewire-wireplumber-and-desktop-integration) | Passes loopback device options (`exclusive_caps=1`, custom device naming). |
| [ipu6-camera.conf](file:///home/matt/projects/OVTI02C1/ipu6-camera.conf) | `/etc/modprobe.d/ipu6-camera.conf` | [Step 1](#configure-module-loading) | Modprobe options outlining exact softdeps for driver module load sequencing. |
| [intel-camera.conf](file:///home/matt/projects/OVTI02C1/intel-camera.conf) | `/etc/tmpfiles.d/intel-camera.conf` | [Step 1](#configure-module-loading) | Systemd tempfile rule allocating the `/run/camera` HAL runtime directory. |
| [camera.conf](file:///home/matt/projects/OVTI02C1/camera.conf) | `/etc/modules-load.d/camera.conf` | [Step 1](#configure-module-loading) | Registers `intel_skl_int3472_discrete`, `intel_cvs`, and `ov02c10` to load. |
| [intel-ipu6.conf](file:///home/matt/projects/OVTI02C1/intel-ipu6.conf) | `/etc/modules-load.d/intel-ipu6.conf` | [Step 1](#configure-module-loading) | Registers `intel_ipu6` and `intel_ipu6_isys` to load. |
| [modules-load.d-v4l2loopback.conf](file:///home/matt/projects/OVTI02C1/modules-load.d-v4l2loopback.conf) | `/etc/modules-load.d/v4l2loopback.conf` | [Step 1](#configure-module-loading) | Registers the `v4l2loopback` loopback module. |

*Note: Files suffixed with parent prefixes in this repository (e.g., `modprobe.d-v4l2loopback.conf` and `modules-load.d-v4l2loopback.conf`) must be renamed to `v4l2loopback.conf` in their respective target system directories.*
