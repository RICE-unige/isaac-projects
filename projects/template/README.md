# Project Name

**Authors:** <!-- Your name(s) here -->
**Isaac Sim version:** <!-- e.g. 5.1.0 -->
**ROS 2 distro:** <!-- Humble / Jazzy -->

---

## Overview

<!-- A short description of what this project does. What robot? What task?
     What learning algorithm or control method are you using? -->

---

## Access

- Ask your thesis supervisor which GPU resource to use. The supervisor
  coordinates with [Omotoye Shamsudeen Adekoya](https://github.com/Omotoye)
  ([omotoye.adekoya@edu.unige.it](mailto:omotoye.adekoya@edu.unige.it)) or
  Prof. Carmine Recchiuto
  ([carmine.recchiuto@unige.it](mailto:carmine.recchiuto@unige.it)), who set
  up the machine and send credentials.
- Follow the repo-level [setup](../../README.md#quick-start) to install Docker,
  NVIDIA Container Toolkit, and ROS 2 on the assigned machine.
- Copy `.env.example` to `.env` and fill in your values (especially
  `NGC_API_KEY` if required and `ALLOWED_CLIENT_IP` if on a SimplePod VM).

> [!IMPORTANT]
> Keep this project in your fork. Do not keep thesis code, scenes, or model
> progress only on a running GPU server. Cloud GPU servers are deleted after
> the allocated hours.

---

## How to Run

### 1. Start Isaac Sim

From the **repository root**:

```bash
cp projects/<your-project-name>/.env.example projects/<your-project-name>/.env
# edit projects/<your-project-name>/.env
source projects/<your-project-name>/.env
./isaac_vmctl.sh bootstrap        # once on a fresh server; add --verbose for live logs
./isaac_vmctl.sh start isaacsim
```

On SimplePod, if you sourced `configs/simplepod-tigervnc.env` and want the
native Isaac Sim UI inside the VNC desktop instead of WebRTC, use:

```bash
./isaac_vmctl.sh start isaacsim --vnc
```

If you are running an Isaac Lab script on SimplePod and want the remote UI,
launch the Isaac Lab script itself with WebRTC instead of starting a separate
`isaacsim` container:

```bash
source configs/isaac-sim-5.1.0.env
source configs/isaac-lab.env
./isaac_vmctl.sh run --livestream public -- \
  bash -lc 'cd external/IsaacLab && ./isaaclab.sh -p scripts/tutorials/00_sim/launch_app.py'
```

If the task renders camera sensors, add `--enable-cameras`. If the printed IP
is not the one your laptop can reach, rerun with `--public-ip <reachable-ip>`.
Install the Isaac Sim WebRTC Streaming Client once on your laptop using the
repo-level [Quick Start](../../README.md#quick-start) instructions.

### 2. Source the project environment

In each new terminal:

```bash
source projects/<your-project-name>/setup.bash
```

### 3. Build and run your ROS 2 workspace

```bash
cd projects/<your-project-name>/ros2_ws
colcon build
source install/setup.bash
ros2 launch <your_package> <your_launch_file>.py
```

### 4. Connect to Isaac Sim

Run the connectivity check to get the IP and ports:

```bash
./isaac_vmctl.sh check
```

Open the Isaac Sim WebRTC client and connect to the IP printed above.

For Isaac Lab one-shot livestream runs, the `isaac_vmctl.sh run` command prints
the target IP before the script starts. Use that IP in the Isaac Sim WebRTC
Streaming Client.

> [!NOTE]
> On Vast.ai headless jobs, skip WebRTC and use
> [Zenoh](../../zenoh/README.md) with the external port mapped to server
> port `7447`.

### 5. Run a training command

Use `run` for one-shot training jobs so the command exits with the training
process and writes artifacts into the mounted project folder:

```bash
./isaac_vmctl.sh run -- bash -lc 'cd projects/<your-project-name> && python train.py'
```

---

## ROS 2 Package Structure

```
ros2_ws/
└── src/
    └── <your_package>/
        ├── package.xml
        ├── setup.py          # (Python package) or CMakeLists.txt (C++)
        ├── <your_package>/
        │   ├── __init__.py
        │   └── ...
        └── launch/
            └── ...
```

---

## Isaac Sim and RL Scene Structure

```
isaacsim/
├── worlds/           # Isaac Sim world files, USD scenes, robots, environments
├── rl_scenes/        # RL scene assets, task configs, training scene files
└── startup_scenes/   # Lab-provided startup scenes to copy and adapt
```

Put thesis-specific scene files here instead of scattering them across the
repository. Startup scenes are provided as a base when they match your project.
Inside the container, this repository is mounted at `/workspace/isaac-projects`.

---

## Repository Workflow

Work from your own fork of the main repository. Sync your fork regularly so
you receive lab updates to scripts, configs, and startup templates.

If this repository setup breaks, or if the instructions are unclear, open an
[issue on the main repository](https://github.com/RICE-unige/isaac-projects/issues)
and inform [Omotoye](https://github.com/Omotoye).

---

## Saving Training Progress

Use `scripts/project_snapshot.sh` from the repo root to save the project
artifacts and matching repo code state before the cloud server is deleted.

Copy the optional snapshot defaults file if you want to pin include paths,
an rsync target, or a resume command:

```bash
cp projects/<your-project-name>/snapshot.env.example \
  projects/<your-project-name>/.snapshot.env
```

Recommended per-session save:

```bash
./scripts/project_snapshot.sh save --project <your-project-name>
```

Recommended end-of-day save when your git auth is already configured:

```bash
./scripts/project_snapshot.sh save \
  --project <your-project-name> \
  --git-push
```

Restore on a fresh server:

```bash
./scripts/project_snapshot.sh restore \
  --project <your-project-name> \
  --snapshot projects/<your-project-name>/artifacts/snapshots/<snapshot-id>.tar.gz
```

> [!TIP]
> Save a `metadata.yaml` next to each checkpoint with the git commit, command,
> seed, task name, Isaac Sim version, and short notes. Snapshot archives,
> manifests, and checksums live under `artifacts/snapshots/`. The helper uses
> existing SSH or HTTPS git auth only and does not manage tokens.

---

## Isaac Sim Configuration

<!-- Document any Isaac-Sim-specific settings, USD scene paths, or extensions
     your project depends on. -->

| Variable | Value |
|----------|-------|
| `ISAAC_IMAGE` | `nvcr.io/nvidia/isaac-sim:5.1.0` |
| `WEBRTC_SIGNAL_PORT` | `49100` |
| `WEBRTC_STREAM_PORT` | `47998` |
| `TIGERVNC_ENABLE` | `0` |
| `TIGERVNC_PORT` | `5901` |
| `TIGERVNC_GEOMETRY` | `1920x1080` |
| `TIGERVNC_DESKTOP` | `xfce` |
| `ISAAC_EXTRA_ARGS` | _(none)_ |

---

## Troubleshooting

<!-- Add project-specific troubleshooting notes here. -->

See also the repo-level [Troubleshooting](../../README.md#troubleshooting) section.
