# Isaac Sim / Isaac Lab for RICE Lab Thesis Projects

![Isaac Sim](https://img.shields.io/badge/Isaac%20Sim-5.1.0%20%7C%206.0-76B900?logo=nvidia&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)
![ROS 2](https://img.shields.io/badge/ROS%202-Humble%20%7C%20Jazzy-22314E?logo=ros&logoColor=white)
![GPU](https://img.shields.io/badge/GPU-RTX%205060%20%7C%205090%20%7C%206000%20Pro-76B900?logo=nvidia&logoColor=white)
![Zenoh](https://img.shields.io/badge/Zenoh-1.9.0-0082C8)

This repository helps RICE lab thesis students start reproducible
**Isaac Sim**, **Isaac Lab**, and **ROS 2** work on the Cloud/lab GPU machines.

The main tool is [isaac_vmctl.sh](isaac_vmctl.sh). It bootstraps Docker,
NVIDIA Container Toolkit, ROS 2, pulls the Isaac Sim container, mounts this
repo into the container, and starts WebRTC or headless sessions.

**What To Do First**

1. Ask your thesis supervisor which GPU machine to use.
2. Fork this repository into your own GitHub account.
3. Clone your fork on the assigned machine.
4. Copy [projects/template](projects/template/) into your own project folder.
5. Keep your code, scenes, configs, and notes in your fork.
6. Open an [issue](https://github.com/RICE-unige/isaac-projects/issues) and
   inform [Omotoye](https://github.com/Omotoye) if the setup or docs break.

> [!IMPORTANT]
> Cloud GPU servers are deleted at the end of the allocated hours, not stopped.
> Push code and scenes to GitHub, and download checkpoints/logs before time
> runs out. Required setup should be reproducible from your fork, not one-off
> host changes. Contact Omotoye if you need extra time to save progress.

## GPU Access

GPU access is handled through your thesis supervisor. The supervisor coordinates
with [Omotoye Shamsudeen Adekoya](https://github.com/Omotoye) or Prof. Carmine
Recchiuto, who set up the machine and send credentials.

| Contact | Email | Teams |
|---|---|---|
| [Omotoye Shamsudeen Adekoya](https://github.com/Omotoye) | [omotoye.adekoya@edu.unige.it](mailto:omotoye.adekoya@edu.unige.it) | Search `Omotoye Adekoya` |
| Prof. Carmine Recchiuto | [carmine.recchiuto@unige.it](mailto:carmine.recchiuto@unige.it) | Search `Carmine Recchiuto` |

| Machine | Use For |
|---|---|
| Lab workstation, RTX 5060 | Setup, ROS integration, simple single-robot simulation. Not available yet. |
| [SimplePod](https://simplepod.ai/), RTX 5090 | Isaac Sim WebRTC, Zenoh, external ports, VPN, remote interactive work. |
| [Vast.ai](https://vast.ai/), RTX 6000 Pro | Headless training, and headless Isaac Sim/ROS 2 jobs when the environment is already set up. |

> [!NOTE]
> Until the RTX 5060 lab workstation arrives, use the cloud machines for all
> use cases.

## Quick Start

Fork `https://github.com/RICE-unige/isaac-projects`, then clone your fork:

```bash
git clone git@github.com:<your-github-user>/isaac-projects.git ~/isaac-projects
cd ~/isaac-projects
cp .env.example .env
```

Edit `.env` if your supervisor gives you specific values. Then start the path
that matches your machine.

**Fresh Server Bootstrap**

```bash
source .env
./isaac_vmctl.sh bootstrap
```

Run this once on each new cloud server. After that, use `start` or `run`
commands without reinstalling host packages.

**SimplePod: Isaac Sim with WebRTC**

```bash
source .env
./isaac_vmctl.sh start isaacsim
./isaac_vmctl.sh check
```

Open the Isaac Sim WebRTC client and connect to the public IP printed by
`./isaac_vmctl.sh check`.

**Vast.ai: Headless Training or Simulation**

```bash
source .env
./isaac_vmctl.sh start isaacsim --headless
```

Use Vast.ai when no viewport is needed. Zenoh can still be used for headless
ROS 2 work, but Vast.ai may map server port `7447` to a different external
port. Use the external mapped port from Vast.ai when connecting from your
laptop.

For training commands, use a one-shot container so logs and exit codes stay in
your terminal:

```bash
./isaac_vmctl.sh run -- bash -lc 'cd projects/my-project && python train.py'
```

**Isaac Lab**

```bash
source configs/isaac-sim-5.1.0.env
source configs/isaac-lab.env
./isaac_vmctl.sh start isaacsim
./isaac_vmctl.sh shell
```

The repo is mounted inside the container at `/workspace/isaac-projects`. Keep
Isaac Lab code in your fork, pin the Isaac Lab tag/commit in your project
README, and put outputs under `projects/<name>/artifacts/`.
For repeated lab use, build a pinned Isaac Lab image with
[containers/isaac-lab.Dockerfile](containers/isaac-lab.Dockerfile).

## Project Layout

Start from the template:

```bash
cp -r projects/template projects/my-project
cp projects/my-project/.env.example projects/my-project/.env
```

Use these folders:

| Path | Purpose | Commit? |
|---|---|---|
| `projects/<name>/isaacsim/worlds/` | Isaac Sim worlds, USD scenes, robot scenes | Yes, if small |
| `projects/<name>/isaacsim/rl_scenes/` | RL scene configs, tasks, curricula | Yes |
| `projects/<name>/isaacsim/startup_scenes/` | Lab startup scenes copied for your project | Yes |
| `projects/<name>/ros2_ws/src/` | ROS 2 packages, launch files, messages | Yes |
| `projects/<name>/artifacts/` | Checkpoints, logs, videos, generated output | No |

More detail: [projects/README.md](projects/README.md).

Inside the container, the repository is available at:

```text
/workspace/isaac-projects
```

## Saving Progress

For normal interactive work, GPU access is usually allocated for a fixed daily
window such as 8-12 hours. Training jobs can run longer when agreed with the
lab. When the allocation ends, the cloud server is deleted to stop charges.

Use [`scripts/project_snapshot.sh`](scripts/project_snapshot.sh) to save both
your repo state and the heavy project artifacts that do not belong in git.
The helper always creates a local archive under:

```text
projects/<name>/artifacts/snapshots/
```

Copy the template config once per project if you want local defaults for
includes, resume commands, or an rsync target:

```bash
cp projects/my-project/snapshot.env.example projects/my-project/.snapshot.env
```

Save the current project locally before the server is deleted:

```bash
./scripts/project_snapshot.sh save --project my-project
```

Save and also create or update a repo commit, then push with your existing git
auth:

```bash
./scripts/project_snapshot.sh save \
  --project my-project \
  --git-push \
  --resume-command "./isaac_vmctl.sh run -- bash -lc 'cd projects/my-project && python train.py'"
```

Save locally and upload the archive, manifest, and checksum to another SSH host:

```bash
./scripts/project_snapshot.sh save \
  --project my-project \
  --rsync-target user@backup-host:/absolute/path/isaac-snapshots/
```

Restore on a fresh server from a local archive:

```bash
git clone git@github.com:<your-github-user>/isaac-projects.git ~/isaac-projects
cd ~/isaac-projects
./scripts/project_snapshot.sh restore \
  --project my-project \
  --snapshot projects/my-project/artifacts/snapshots/<snapshot-id>.tar.gz
```

Restore directly from an rsync source:

```bash
./scripts/project_snapshot.sh restore \
  --project my-project \
  --snapshot user@backup-host:/absolute/path/isaac-snapshots/<snapshot-id>.tar.gz
```

> [!TIP]
> Keep the `.tar.gz`, `.manifest.json`, and `.sha256` files together. Git push
> uses your existing SSH or HTTPS auth only; the helper does not manage tokens
> or store credentials. Local archive creation is always the primary save path,
> even when push or rsync upload fails.

## Startup Templates

Templates will provide ready-to-edit Isaac Sim and Isaac Lab scenes for current
RICE thesis projects. Assets and preview GIFs are coming soon in
`docs/assets/startup-templates/`.

| Template | Description | Preview GIF | Status |
|---|---|---|---|
| Kinova Tabletop VLA | Kinova arm on a table for VLA pick-place, pushing, and basic manipulation tasks. | `docs/assets/startup-templates/kinova-tabletop-vla.gif` | `COMING SOON` |
| Spot + Kinova VLA | Mobile-manipulator scene for VLA control with Spot carrying a Kinova arm. | `docs/assets/startup-templates/spot-kinova-vla.gif` | `COMING SOON` |
| Spot Navigation RL | Isaac Lab training scene that spawns multiple Spot robots for navigation policy work. | `docs/assets/startup-templates/spot-navigation-rl.gif` | `COMING SOON` |
| Fire Search and Rescue | Realistic fire/smoke search-and-rescue scene with Spot and perception hooks. | `docs/assets/startup-templates/fire-search-rescue.gif` | `COMING SOON` |
| Drone Thermal Search | Drone scene with thermal camera workflow for aerial inspection and search tasks. | `docs/assets/startup-templates/drone-thermal-search.gif` | `COMING SOON` |
| Heterogeneous LLM Team | Mixed robot team scene for LLM-based task planning and coordination. | `docs/assets/startup-templates/heterogeneous-llm-team.gif` | `COMING SOON` |

## Common Commands

| Command | Use |
|---|---|
| `./isaac_vmctl.sh start isaacsim` | Start Isaac Sim with WebRTC |
| `./isaac_vmctl.sh start isaacsim --headless` | Start Isaac Sim without WebRTC |
| `./isaac_vmctl.sh run -- <command>` | Run a one-shot command inside the Isaac Sim image |
| `./isaac_vmctl.sh stop isaacsim` | Stop the container |
| `./isaac_vmctl.sh restart isaacsim` | Restart the container |
| `./isaac_vmctl.sh status` | Check host, GPU, Docker, ROS 2, container |
| `./isaac_vmctl.sh logs` | Follow Isaac Sim logs |
| `./isaac_vmctl.sh shell` | Open a shell in the running container |
| `./isaac_vmctl.sh check` | Print IP, port checks, client commands |
| `./isaac_vmctl.sh bootstrap` | Install Docker, NVIDIA runtime, ROS 2, image |

## WebRTC and ROS 2 Topics

Use **WebRTC** when you need the Isaac Sim viewport. On SimplePod, make sure
these inbound ports are available:

| Port | Purpose |
|---|---|
| TCP `49100` | WebRTC signaling |
| UDP `47998` | WebRTC video stream |

Use **Zenoh** when you need ROS 2 topics on your laptop:

```bash
# assigned GPU server
./zenoh/setup.sh
./zenoh/start_zenoh_bridge.sh

# Laptop
./zenoh/setup.sh
./zenoh/connect_zenoh_bridge.sh <GPU_PUBLIC_IP>

# Laptop with a Vast.ai mapped port
./zenoh/connect_zenoh_bridge.sh <VAST_PUBLIC_IP> <EXTERNAL_MAPPED_PORT>
```

Full guide: [zenoh/README.md](zenoh/README.md).

## Keeping Your Fork Updated

```bash
git remote add upstream https://github.com/RICE-unige/isaac-projects.git  # once
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

## Useful References

| Topic | Link |
|---|---|
| Version configs | [configs/README.md](configs/README.md) |
| Project workspaces | [projects/README.md](projects/README.md) |
| Zenoh ROS 2 bridge | [zenoh/README.md](zenoh/README.md) |
| Isaac Lab | [Isaac Lab documentation](https://isaac-sim.github.io/IsaacLab/) |
| Isaac Sim docs | [NVIDIA Isaac Sim documentation](https://docs.isaacsim.omniverse.nvidia.com/) |

## Troubleshooting

| Problem | First Check |
|---|---|
| WebRTC cannot connect | Run `./isaac_vmctl.sh check`; confirm SimplePod ports `49100/tcp` and `47998/udp`. |
| Container exits | Run `./isaac_vmctl.sh logs`. |
| No ROS 2 topics | Enable `omni.isaac.ros2_bridge`; check Zenoh and `ROS_DOMAIN_ID`. |
| GPU not visible | Contact your thesis supervisor, Omotoye, or Prof. Carmine Recchiuto. |

For setup or documentation issues, open an
[issue](https://github.com/RICE-unige/isaac-projects/issues) and inform
[Omotoye](https://github.com/Omotoye).
