#!/usr/bin/env bash
# Project environment setup script.
#
# Source this in every new terminal before working on the project:
#   source setup.bash
#
# It will:
#   1. Load project-specific variables from .env (if present)
#   2. Source the ROS 2 environment (Humble or Jazzy, whichever is installed)
#   3. Source the colcon workspace if it has been built
#
# Do not enable strict shell options here: this file is meant to be sourced,
# and changing set -e/-u/pipefail would leak into the user's interactive shell.

_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 1. Load project .env ─────────────────────────────────────────────────────
if [[ -f "${_project_dir}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${_project_dir}/.env"
  set +a
  echo "[setup] Loaded ${_project_dir}/.env"
else
  echo "[setup] No .env found — skipping project overrides."
fi

# ─── 2. Source ROS 2 ──────────────────────────────────────────────────────────
_ros_sourced=0
for _ros_setup in /opt/ros/jazzy/setup.bash /opt/ros/humble/setup.bash; do
  if [[ -f "$_ros_setup" ]]; then
    # shellcheck source=/dev/null
    source "$_ros_setup"
    _ros_sourced=1
    echo "[setup] Sourced ROS 2: ${_ros_setup}"
    break
  fi
done

if [[ $_ros_sourced -eq 0 ]]; then
  echo "[setup] WARNING: ROS 2 not found. Run: ./isaac_vmctl.sh install ros2"
fi

# ─── 3. Source colcon workspace ───────────────────────────────────────────────
_ws_setup="${_project_dir}/ros2_ws/install/setup.bash"
if [[ -f "$_ws_setup" ]]; then
  # shellcheck source=/dev/null
  source "$_ws_setup"
  echo "[setup] Sourced workspace: ${_ws_setup}"
else
  echo "[setup] Workspace not built yet. Run: cd ros2_ws && colcon build"
fi

echo "[setup] Done. ROS_DISTRO=${ROS_DISTRO:-not set}"

unset _project_dir _ros_sourced _ros_setup _ws_setup
