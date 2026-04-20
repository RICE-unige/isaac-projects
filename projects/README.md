# projects/

This directory holds thesis project workspaces for RICE lab students.

Students should normally fork the main repository, clone their own fork, and
keep project files inside that fork. If the main repository changes, sync your
fork regularly. If the setup breaks or instructions are unclear, open an issue
on the [main repository](https://github.com/RICE-unige/isaac-projects/issues)
and inform [Omotoye](https://github.com/Omotoye).

> [!IMPORTANT]
> Cloud GPU servers are deleted at the end of allocated hours, not stopped.
> Keep project files in GitHub and download or archive checkpoints/logs before
> the allocation ends.

Two usage models are supported:

---

## Model A — Work inside this repo (recommended for beginners)

Copy the template directory and give it your project name:

```bash
cp -r projects/template projects/my-legged-robot
cd projects/my-legged-robot
cp .env.example .env
```

Edit `.env` with your configuration, then start Isaac Sim from the repo root:

```bash
source projects/my-legged-robot/.env
./isaac_vmctl.sh bootstrap        # once on a fresh server; add --verbose for live logs
./isaac_vmctl.sh start isaacsim
```

On SimplePod, if you sourced `configs/simplepod-tigervnc.env` and want the
native Isaac Sim UI inside the VNC desktop instead of WebRTC, use:

```bash
./isaac_vmctl.sh start isaacsim --vnc
```

For Isaac Lab scripts that need a remote UI on SimplePod, do not start a
separate `isaacsim` session first. Run the Isaac Lab command itself with
livestreaming:

```bash
source projects/my-legged-robot/.env
source ~/isaac-projects/configs/isaac-sim-5.1.0.env
source ~/isaac-projects/configs/isaac-lab.env
~/isaac-projects/isaac_vmctl.sh run --livestream public -- \
  bash -lc 'cd external/IsaacLab && ./isaaclab.sh -p scripts/tutorials/00_sim/launch_app.py'
```

If the task renders camera sensors, add `--enable-cameras`. If the printed IP
is not the one your laptop can reach, rerun with `--public-ip <reachable-ip>`.
Install the laptop-side client once using the repo-level
[WebRTC instructions](../README.md#quick-start).

Source the project environment in each new terminal:

```bash
source projects/my-legged-robot/setup.bash
```

---

## Model B — Separate repository (recommended for advanced users)

Clone this repo for the tooling only, then create your project as a sibling:

```
~/
├── isaac-projects/         ← this repo (tooling)
│   └── isaac_vmctl.sh
└── my-legged-robot/        ← your project repo
    ├── .env.example
    ├── .env                ← local only; do not commit
    ├── isaacsim/
    │   ├── worlds/
    │   ├── rl_scenes/
    │   └── startup_scenes/
    ├── setup.bash
    └── ros2_ws/
```

Copy the template files as a starting point:

```bash
cp -r ~/isaac-projects/projects/template ~/my-legged-robot
cd ~/my-legged-robot
cp .env.example .env
```

In your project, reference the script by path:

```bash
source .env
HOST_WORKSPACE_ROOT=$PWD ~/isaac-projects/isaac_vmctl.sh start isaacsim
```

Inside the container, `HOST_WORKSPACE_ROOT` appears at
`/workspace/isaac-projects`.

---

## Isaac Sim and RL Scene Files

Use these directories inside each project workspace:

| Directory | Purpose |
|---|---|
| `isaacsim/worlds/` | Isaac Sim world files, USD scenes, robot scenes, and environment templates |
| `isaacsim/rl_scenes/` | Reinforcement-learning scenes, task configs, and training-specific scene assets |
| `isaacsim/startup_scenes/` | Startup scenes provided by the lab; copy and adapt them when relevant |
| `ros2_ws/src/` | ROS 2 packages, launch files, nodes, and message packages |

Keep large generated caches, training logs, and build artifacts out of git.
Use `artifacts/checkpoints/` and `artifacts/logs/` for local training output,
then archive and download those folders before the cloud server is deleted.
The container runs as your host UID/GID by default, so files written under the
mounted project remain owned by you.

---

## Saving and Restoring Project State

Use `scripts/project_snapshot.sh` from the repo root to save project artifacts
and the matching repo code state in one step.

Optional local defaults live in:

```bash
cp projects/my-legged-robot/snapshot.env.example projects/my-legged-robot/.snapshot.env
```

Local save:

```bash
./scripts/project_snapshot.sh save --project my-legged-robot
```

End-of-day save with git push:

```bash
./scripts/project_snapshot.sh save \
  --project my-legged-robot \
  --git-push
```

Restore into a fresh clone:

```bash
./scripts/project_snapshot.sh restore \
  --project my-legged-robot \
  --snapshot projects/my-legged-robot/artifacts/snapshots/<snapshot-id>.tar.gz
```

The helper stores archives under `artifacts/snapshots/`, uploads with `rsync`
only when requested, and reuses your existing git auth when `--git-push` is
enabled.

---

## Shared VM — Multiple Students

If you share a single VM, each student must use a **unique** container name and
port set to avoid conflicts. Edit your project's `.env`:

```bash
CONTAINER_NAME=isaac-sim-alice
WEBRTC_SIGNAL_PORT=49101
WEBRTC_STREAM_PORT=47999
TIGERVNC_PORT=5902
ISAAC_HOST_ROOT=/home/alice/docker/isaac-sim
```

See the main [README](../README.md) for the full port and configuration reference.

---

## What Not to Commit

Add these to your project's `.gitignore`:

```
.env                        # may contain your NGC_API_KEY
.snapshot.env               # local snapshot defaults only; no tokens
ros2_ws/build/
ros2_ws/install/
ros2_ws/log/
artifacts/
runs/
wandb/
checkpoints/
*.pt
*.pth
__pycache__/
*.pyc
```
