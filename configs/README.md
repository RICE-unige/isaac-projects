# configs/

Pre-built environment files for supported Isaac Sim versions. Source one of
these before running `isaac_vmctl.sh` to pin your environment to a known-good
configuration.

## Available Configs

| File | Isaac Sim Version | Ubuntu | Min Driver | Lab GPU Profile | Status |
|------|------------------|--------|------------|-----------------|--------|
| `isaac-sim-5.1.0.env` | 5.1.0 | 22.04 / 24.04 | 580.65.06 | RTX 5060 workstation / RTX 5090 SimplePod / RTX 6000 Pro Vast.ai | **Recommended** |
| `isaac-sim-6.0.0-dev2.env` | 6.0.0-dev2 | 22.04 / 24.04 | 580.65.06+ | RTX 5060 workstation / RTX 5090 SimplePod / RTX 6000 Pro Vast.ai | Preview / unstable |
| `isaac-lab.env` | N/A (overlay) | — | — | — | Source on top of a version config |
| `simplepod-tigervnc.env` | N/A (overlay) | 22.04 / 24.04 | N/A | RTX 5090 SimplePod | Enables TigerVNC XFCE desktop during bootstrap |

## Usage

```bash
# Fresh server setup
source configs/isaac-sim-5.1.0.env
./isaac_vmctl.sh bootstrap

# Start Isaac Sim 5.1 (recommended)
source configs/isaac-sim-5.1.0.env && ./isaac_vmctl.sh start isaacsim

# Start with Isaac Lab overlay
source configs/isaac-sim-5.1.0.env
source configs/isaac-lab.env
./isaac_vmctl.sh start isaacsim --headless

# Bootstrap SimplePod with a TigerVNC XFCE desktop on TCP 5901
source configs/isaac-sim-5.1.0.env
source configs/simplepod-tigervnc.env
./isaac_vmctl.sh bootstrap

# Start native Isaac Sim UI inside the TigerVNC desktop
./isaac_vmctl.sh start isaacsim --vnc

# Run a one-shot training command inside the mounted repo
./isaac_vmctl.sh run -- bash -lc 'cd projects/my-project && python train.py'

# Override a single variable inline
source configs/isaac-sim-5.1.0.env
ALLOWED_CLIENT_IP=203.0.113.5 ./isaac_vmctl.sh start isaacsim
```

## Adding a New Version

1. Copy the closest existing `.env` file.
2. Update `ISAAC_IMAGE` to the new tag.
3. Adjust `START_TIMEOUT_SEC` and any notes as needed.
4. Verify the WebRTC flag path: image tags starting with `5.*` use
   `--/app/livestream/...`; all other tags (including `6.*`) use
   `--/exts/omni.kit.livestream.app/...`.
   Check `build_isaac_command` in `isaac_vmctl.sh` to confirm.

For Isaac Lab, pin the Isaac Lab git tag/commit that supports the selected
Isaac Sim image. Do not use an unpinned main branch for thesis work.
Use [containers/isaac-lab.Dockerfile](../containers/isaac-lab.Dockerfile) when the lab
wants a reusable Isaac Lab image for several students.
