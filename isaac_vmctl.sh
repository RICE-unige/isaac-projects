#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults; can be overridden with environment variables.
ISAAC_IMAGE="${ISAAC_IMAGE:-nvcr.io/nvidia/isaac-sim:5.1.0}"
CONTAINER_NAME="${CONTAINER_NAME:-isaac-sim}"
ISAAC_HOST_ROOT="${ISAAC_HOST_ROOT:-$HOME/docker/isaac-sim}"
WEBRTC_SIGNAL_PORT="${WEBRTC_SIGNAL_PORT:-49100}"
WEBRTC_STREAM_PORT="${WEBRTC_STREAM_PORT:-47998}"
ROS_INSTALL_VARIANT="${ROS_INSTALL_VARIANT:-ros-base}"   # ros-base | desktop
ALLOWED_CLIENT_IP="${ALLOWED_CLIENT_IP:-}"               # optional; only used if ufw is active
ISAAC_EXTRA_ARGS="${ISAAC_EXTRA_ARGS:-}"
PRIVACY_USERID="${PRIVACY_USERID:-}"
START_TIMEOUT_SEC="${START_TIMEOUT_SEC:-30}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-}"
HOST_WORKSPACE_ROOT="${HOST_WORKSPACE_ROOT:-$SCRIPT_DIR}"
CONTAINER_WORKSPACE="${CONTAINER_WORKSPACE:-/workspace/isaac-projects}"
CONTAINER_UID="${CONTAINER_UID:-}"
CONTAINER_GID="${CONTAINER_GID:-}"

trap 'echo "[ERROR] ${SCRIPT_NAME}: line ${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} bootstrap           Install/repair Docker, NVIDIA runtime, ROS 2, and pull the Isaac Sim image.
  ${SCRIPT_NAME} start isaacsim      Start Isaac Sim with WebRTC.
  ${SCRIPT_NAME} start isaacsim --headless
                                 Start Isaac Sim without WebRTC flags.
  ${SCRIPT_NAME} run -- <command>    Run a one-shot command inside the Isaac Sim container image.
  ${SCRIPT_NAME} stop isaacsim       Stop the Isaac Sim container.
  ${SCRIPT_NAME} restart isaacsim    Restart Isaac Sim.
  ${SCRIPT_NAME} status              Show VM / Docker / Isaac Sim / ROS status.
  ${SCRIPT_NAME} logs                Show Isaac Sim container logs.
  ${SCRIPT_NAME} shell               Open a shell in the running Isaac Sim container.
  ${SCRIPT_NAME} install all         Install/repair Docker, NVIDIA container runtime, ROS 2, and Isaac Sim image.
  ${SCRIPT_NAME} install ros2        Install/repair ROS 2 only.
  ${SCRIPT_NAME} install docker      Install/repair Docker + NVIDIA container runtime only.
  ${SCRIPT_NAME} check               Show listener checks and client-side test commands.
  ${SCRIPT_NAME} help                Show this help.

Optional environment variables:
  ISAAC_IMAGE=nvcr.io/nvidia/isaac-sim:5.1.0
  CONTAINER_NAME=isaac-sim
  ISAAC_HOST_ROOT=
  WEBRTC_SIGNAL_PORT=49100
  WEBRTC_STREAM_PORT=47998
  ROS_INSTALL_VARIANT=ros-base|desktop
  ROS_DOMAIN_ID=0
  HOST_WORKSPACE_ROOT=${SCRIPT_DIR}
  CONTAINER_WORKSPACE=/workspace/isaac-projects
  CONTAINER_UID=<host-uid>            # optional; defaults to current user
  CONTAINER_GID=<host-gid>            # optional; defaults to current user
  ALLOWED_CLIENT_IP=<your-public-ip>   # only applied if ufw is already active
  PRIVACY_USERID=<email>
  ISAAC_EXTRA_ARGS='<extra Isaac Sim args>'
  NGC_API_KEY=<your-ngc-api-key>       # optional, only used if image pull requires login

Examples:
  ${SCRIPT_NAME} bootstrap
  ${SCRIPT_NAME} start isaacsim
  ${SCRIPT_NAME} start isaacsim --headless
  ${SCRIPT_NAME} run -- bash -lc 'cd projects/my-project && python train.py'
  ROS_INSTALL_VARIANT=desktop ${SCRIPT_NAME} install ros2
  ALLOWED_CLIENT_IP=203.0.113.5 ${SCRIPT_NAME} start isaacsim
  ISAAC_IMAGE=nvcr.io/nvidia/isaac-sim:6.0.0-dev2 ${SCRIPT_NAME} restart isaacsim
USAGE
}

need_root() {
  if [[ ${EUID} -eq 0 ]]; then
    ROOT_PREFIX=()
  else
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    ROOT_PREFIX=(sudo)
  fi
}

as_root() {
  need_root
  "${ROOT_PREFIX[@]}" "$@"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_supported_host() {
  [[ -r /etc/os-release ]] || error "/etc/os-release not found. Unsupported host."
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || error "This script only supports Ubuntu hosts. Found: ${PRETTY_NAME:-unknown}."

  case "${VERSION_ID:-}" in
    22.04)
      ROS_DISTRO=humble
      ROS_SETUP=/opt/ros/humble/setup.bash
      ;;
    24.04)
      ROS_DISTRO=jazzy
      ROS_SETUP=/opt/ros/jazzy/setup.bash
      ;;
    *)
      error "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. This script intentionally supports Ubuntu 22.04 (ROS 2 Humble) and Ubuntu 24.04 (ROS 2 Jazzy) only."
      ;;
  esac

  ARCH=$(dpkg --print-architecture)
  case "$ARCH" in
    amd64) ;;
    *) warn "Architecture is ${ARCH}. Isaac Sim container workflows are typically x86_64/amd64; continue only if that is intentional." ;;
  esac
}

current_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "$SUDO_USER"
  else
    id -un
  fi
}

home_dir() {
  local user
  user=$(current_user)
  getent passwd "$user" | cut -d: -f6
}

init_paths() {
  USER_NAME=$(current_user)
  USER_HOME=$(home_dir)
  if [[ -z "${ISAAC_HOST_ROOT:-}" || "$ISAAC_HOST_ROOT" == "$HOME/docker/isaac-sim" ]]; then
    ISAAC_HOST_ROOT="${USER_HOME}/docker/isaac-sim"
  fi
  if [[ ! "$HOST_WORKSPACE_ROOT" = /* ]]; then
    HOST_WORKSPACE_ROOT="$(cd "$HOST_WORKSPACE_ROOT" && pwd)"
  fi
  [[ -d "$HOST_WORKSPACE_ROOT" ]] || error "HOST_WORKSPACE_ROOT does not exist: ${HOST_WORKSPACE_ROOT}"

  if [[ -z "$CONTAINER_UID" ]]; then
    CONTAINER_UID=$(id -u "$USER_NAME")
  fi
  if [[ -z "$CONTAINER_GID" ]]; then
    CONTAINER_GID=$(id -g "$USER_NAME")
  fi
}

get_docker_cmd() {
  if have_cmd docker && docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif have_cmd docker; then
    DOCKER=(sudo docker)
  else
    DOCKER=(sudo docker)
  fi
}

docker_cmd() {
  get_docker_cmd
  ${DOCKER[@]} "$@"
}

require_docker_runtime() {
  have_cmd docker || error "Docker is not installed. Run: ./${SCRIPT_NAME} bootstrap"
  get_docker_cmd
  docker_cmd version >/dev/null 2>&1 || error "Docker is installed but not usable by this user. Run: ./${SCRIPT_NAME} bootstrap"
}

ensure_common_apt_bits() {
  as_root apt-get update -y
  as_root apt-get install -y ca-certificates curl gnupg software-properties-common lsb-release iproute2 net-tools netcat-openbsd
}

ensure_nvidia_driver_present() {
  have_cmd nvidia-smi || error "nvidia-smi not found. Install the NVIDIA GPU driver first, or use a GPU image that already has it."
  if ! nvidia-smi >/dev/null 2>&1; then
    error "nvidia-smi exists but the driver/GPU is not healthy. Fix that before using Isaac Sim containers."
  fi
}

ensure_docker_installed() {
  if have_cmd docker && docker --version >/dev/null 2>&1; then
    info "Docker already installed: $(docker --version)"
  else
    info "Installing Docker Engine from Docker's apt repository..."
    ensure_common_apt_bits

    # Remove conflicting packages if present.
    as_root bash -lc 'apt remove -y $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | cut -f1) || true'

    as_root install -m 0755 -d /etc/apt/keyrings
    as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    as_root chmod a+r /etc/apt/keyrings/docker.asc

    local codename arch
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    arch=$(dpkg --print-architecture)
    as_root bash -lc "cat > /etc/apt/sources.list.d/docker.sources <<DOCKERREPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKERREPO"

    as_root apt-get update -y
    as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    as_root systemctl enable --now docker
  fi

  # Let the current user use docker in future shells.
  local user
  user=$(current_user)
  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
      as_root usermod -aG docker "$user" || true
      warn "Added ${user} to docker group. A new shell/login is needed before plain 'docker' works without sudo."
    fi
  fi

  get_docker_cmd
  docker_cmd version >/dev/null
}

ensure_nvidia_container_runtime() {
  ensure_nvidia_driver_present
  ensure_docker_installed

  local ok=0
  if docker_cmd run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
    ok=1
  fi

  if [[ $ok -eq 1 ]]; then
    info "NVIDIA Container Toolkit already working with Docker."
    return 0
  fi

  info "Installing/configuring NVIDIA Container Toolkit..."
  ensure_common_apt_bits

  as_root bash -lc 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
  as_root bash -lc 'curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list'
  as_root apt-get update -y
  as_root apt-get install -y nvidia-container-toolkit
  as_root nvidia-ctk runtime configure --runtime=docker
  as_root systemctl restart docker

  if ! docker_cmd run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
    error "Docker still cannot see the GPU after configuring NVIDIA Container Toolkit. Check driver health, reboot if needed, then retry."
  fi

  info "NVIDIA Container Toolkit is working."
}

verify_nvidia_container_runtime() {
  ensure_nvidia_driver_present
  require_docker_runtime

  if ! docker_cmd run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
    error "Docker cannot see the GPU. Run: ./${SCRIPT_NAME} bootstrap"
  fi
}

install_ros_apt_source() {
  ensure_common_apt_bits
  as_root apt-get install -y software-properties-common
  as_root add-apt-repository -y universe

  local tmpdeb version codename
  tmpdeb=/tmp/ros2-apt-source.deb
  version=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F 'tag_name' | awk -F'"' '{print $4}')
  [[ -n "$version" ]] || error "Failed to resolve ros2-apt-source release version."
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")
  curl -L -o "$tmpdeb" "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${version}/ros2-apt-source_${version}.${codename}_all.deb"
  as_root dpkg -i "$tmpdeb"
}

ensure_ros2_installed() {
  require_supported_host
  init_paths

  if [[ -f "$ROS_SETUP" ]]; then
    info "ROS 2 ${ROS_DISTRO} already installed."
  else
    info "Installing ROS 2 ${ROS_DISTRO} (${ROS_INSTALL_VARIANT})..."
    install_ros_apt_source
    as_root apt-get update -y

    if [[ "$ROS_DISTRO" == "humble" ]]; then
      # Safer than a full distro upgrade on remote GPU VMs: update the packages ROS docs explicitly warn about.
      as_root apt-get install -y systemd systemd-sysv libsystemd0 udev
    fi

    local ros_pkg
    case "$ROS_INSTALL_VARIANT" in
      ros-base) ros_pkg="ros-${ROS_DISTRO}-ros-base" ;;
      desktop)  ros_pkg="ros-${ROS_DISTRO}-desktop" ;;
      *) error "ROS_INSTALL_VARIANT must be 'ros-base' or 'desktop'." ;;
    esac

    local rosdep_pkg=""
    if apt-cache show python3-rosdep >/dev/null 2>&1; then
      rosdep_pkg="python3-rosdep"
    elif apt-cache show python3-rosdep2 >/dev/null 2>&1; then
      rosdep_pkg="python3-rosdep2"
    fi

    as_root apt-get install -y "$ros_pkg" ros-dev-tools python3-colcon-common-extensions ${rosdep_pkg:+$rosdep_pkg}
  fi

  if [[ ! -f "$ROS_SETUP" ]]; then
    error "ROS setup script not found at ${ROS_SETUP} after installation."
  fi

  if have_cmd rosdep; then
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
      as_root rosdep init || true
    fi
    rosdep update || true
  fi
}

ensure_isaac_dirs() {
  info "Preparing Isaac Sim host directories under ${ISAAC_HOST_ROOT}..."
  mkdir -p \
    "${ISAAC_HOST_ROOT}/cache/main/ov" \
    "${ISAAC_HOST_ROOT}/cache/main/warp" \
    "${ISAAC_HOST_ROOT}/cache/computecache" \
    "${ISAAC_HOST_ROOT}/config" \
    "${ISAAC_HOST_ROOT}/data/documents" \
    "${ISAAC_HOST_ROOT}/data/Kit" \
    "${ISAAC_HOST_ROOT}/logs" \
    "${ISAAC_HOST_ROOT}/pkg"
  as_root chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${ISAAC_HOST_ROOT}"
}

ensure_isaac_image() {
  if docker_cmd image inspect "$ISAAC_IMAGE" >/dev/null 2>&1; then
    info "Isaac Sim image already present: ${ISAAC_IMAGE}"
    return 0
  fi

  info "Pulling Isaac Sim image: ${ISAAC_IMAGE}"
  if docker_cmd pull "$ISAAC_IMAGE"; then
    return 0
  fi

  if [[ -n "${NGC_API_KEY:-}" ]]; then
    warn "Initial pull failed; trying nvcr.io login with NGC_API_KEY..."
    printf '%s' "$NGC_API_KEY" | docker_cmd login nvcr.io -u '$oauthtoken' --password-stdin
    docker_cmd pull "$ISAAC_IMAGE"
    return 0
  fi

  error "Failed to pull ${ISAAC_IMAGE}. If nvcr.io requires auth in your environment, export NGC_API_KEY and rerun."
}

get_public_ip() {
  local ip
  ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || true)
  fi
  [[ -n "$ip" ]] || error "Could not determine the VM public IPv4 address."
  printf '%s' "$ip"
}

configure_ufw_if_active() {
  if ! have_cmd ufw; then
    return 0
  fi

  local ufw_status
  need_root
  ufw_status=$("${ROOT_PREFIX[@]}" ufw status 2>/dev/null | head -n1 || true)
  if [[ "$ufw_status" != Status:\ active* ]]; then
    if [[ -n "$ALLOWED_CLIENT_IP" ]]; then
      warn "ALLOWED_CLIENT_IP is set, but ufw is not active. Not enabling or changing firewall automatically to avoid breaking SSH."
    fi
    return 0
  fi

  info "ufw is active; ensuring rules exist for SSH and Isaac Sim WebRTC..."
  if [[ -n "$ALLOWED_CLIENT_IP" ]]; then
    as_root ufw allow from "$ALLOWED_CLIENT_IP" to any port 22 proto tcp
    as_root ufw allow from "$ALLOWED_CLIENT_IP" to any port "$WEBRTC_SIGNAL_PORT" proto tcp
    as_root ufw allow from "$ALLOWED_CLIENT_IP" to any port "$WEBRTC_STREAM_PORT" proto udp
  else
    as_root ufw allow 22/tcp
    as_root ufw allow "${WEBRTC_SIGNAL_PORT}/tcp"
    as_root ufw allow "${WEBRTC_STREAM_PORT}/udp"
  fi
}

append_extra_args() {
  local -n target=$1
  local -a extra_args=()

  if [[ -n "$ISAAC_EXTRA_ARGS" ]]; then
    # ISAAC_EXTRA_ARGS is intentionally simple: whitespace-separated flags.
    # For complex commands, use: isaac_vmctl.sh run -- bash -lc '...'
    read -r -a extra_args <<< "$ISAAC_EXTRA_ARGS"
    target+=("${extra_args[@]}")
  fi
}

build_isaac_command() {
  local mode=$1
  local public_ip=${2:-}
  local tag
  tag="${ISAAC_IMAGE##*:}"
  ISAAC_CMD=("./runheadless.sh")

  if [[ "$mode" == "webrtc" ]]; then
    if [[ "$tag" == 5.* ]]; then
      ISAAC_CMD+=(
        "--/app/livestream/publicEndpointAddress=${public_ip}"
        "--/app/livestream/port=${WEBRTC_SIGNAL_PORT}"
      )
    else
      ISAAC_CMD+=(
        "--/exts/omni.kit.livestream.app/primaryStream/publicIp=${public_ip}"
        "--/exts/omni.kit.livestream.app/primaryStream/signalPort=${WEBRTC_SIGNAL_PORT}"
        "--/exts/omni.kit.livestream.app/primaryStream/streamPort=${WEBRTC_STREAM_PORT}"
      )
    fi
  fi

  append_extra_args ISAAC_CMD
}

build_common_docker_args() {
  DOCKER_RUN_ARGS=(
    --gpus all
    --network=host
    -e ACCEPT_EULA=Y
    -e PRIVACY_CONSENT=Y
    -e "ROS_DOMAIN_ID=${ROS_DOMAIN_ID}"
    -e "CONTAINER_WORKSPACE=${CONTAINER_WORKSPACE}"
    -v "${ISAAC_HOST_ROOT}/cache/main:/isaac-sim/.cache:rw"
    -v "${ISAAC_HOST_ROOT}/cache/computecache:/isaac-sim/.nv/ComputeCache:rw"
    -v "${ISAAC_HOST_ROOT}/logs:/isaac-sim/.nvidia-omniverse/logs:rw"
    -v "${ISAAC_HOST_ROOT}/config:/isaac-sim/.nvidia-omniverse/config:rw"
    -v "${ISAAC_HOST_ROOT}/data:/isaac-sim/.local/share/ov/data:rw"
    -v "${ISAAC_HOST_ROOT}/pkg:/isaac-sim/.local/share/ov/pkg:rw"
    -v "${HOST_WORKSPACE_ROOT}:${CONTAINER_WORKSPACE}:rw"
    -w "${CONTAINER_WORKSPACE}"
    -u "${CONTAINER_UID}:${CONTAINER_GID}"
  )

  if [[ -n "$PRIVACY_USERID" ]]; then
    DOCKER_RUN_ARGS+=(-e "PRIVACY_USERID=${PRIVACY_USERID}")
  fi
  if [[ -n "$RMW_IMPLEMENTATION" ]]; then
    DOCKER_RUN_ARGS+=(-e "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}")
  fi
}

remove_existing_container() {
  if docker_cmd ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    info "Removing existing container named ${CONTAINER_NAME}..."
    docker_cmd rm -f "$CONTAINER_NAME" >/dev/null || true
  fi
}

start_isaacsim() {
  local mode="webrtc"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --headless) mode="headless"; shift ;;
      --webrtc)   mode="webrtc"; shift ;;
      *) error "Unknown start option: $1. Use --webrtc or --headless." ;;
    esac
  done

  require_supported_host
  init_paths
  verify_nvidia_container_runtime
  ensure_isaac_dirs
  ensure_isaac_image
  if [[ "$mode" == "webrtc" ]]; then
    configure_ufw_if_active
  fi

  local public_ip signal_ready ros_status
  public_ip="not needed"
  if [[ "$mode" == "webrtc" ]]; then
    public_ip=$(get_public_ip)
  fi
  if [[ -f "$ROS_SETUP" ]]; then
    ros_status="${ROS_DISTRO} (${ROS_SETUP})"
  else
    ros_status="not installed on host; run ./${SCRIPT_NAME} bootstrap if Zenoh/host ROS 2 is needed"
  fi

  build_isaac_command "$mode" "$public_ip"
  build_common_docker_args
  remove_existing_container

  info "Starting ${CONTAINER_NAME} from ${ISAAC_IMAGE} (${mode})..."
  docker_cmd run -d \
    --name "$CONTAINER_NAME" \
    "${DOCKER_RUN_ARGS[@]}" \
    "$ISAAC_IMAGE" \
    bash -lc 'cd /isaac-sim && exec "$@"' _ "${ISAAC_CMD[@]}"

  if [[ "$mode" == "headless" ]]; then
    cat <<EOF_SUMMARY

Isaac Sim headless start requested.

Container:      ${CONTAINER_NAME}
Image:          ${ISAAC_IMAGE}
Workspace:      ${HOST_WORKSPACE_ROOT} -> ${CONTAINER_WORKSPACE}
ROS 2 host:     ${ros_status}
ROS_DOMAIN_ID:  ${ROS_DOMAIN_ID}

Useful commands:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} logs
  ${SCRIPT_NAME} shell
EOF_SUMMARY
    return 0
  fi

  info "Container launched. Waiting up to ${START_TIMEOUT_SEC}s for the WebRTC signal port..."
  sleep 5
  docker_cmd logs --tail 80 "$CONTAINER_NAME" || true

  signal_ready=0
  for _ in $(seq 1 "$START_TIMEOUT_SEC"); do
    if docker_cmd ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      :
    else
      error "Container exited during startup. Run '${SCRIPT_NAME} logs' to inspect the failure."
    fi
    if ss -lnt | awk '{print $4}' | grep -Eq "[:.]${WEBRTC_SIGNAL_PORT}$"; then
      signal_ready=1
      break
    fi
    sleep 1
  done

  if [[ "$signal_ready" -eq 1 ]]; then
    info "WebRTC signal port ${WEBRTC_SIGNAL_PORT}/tcp is listening."
  else
    warn "Timed out waiting for ${WEBRTC_SIGNAL_PORT}/tcp. Isaac Sim may still be starting; run '${SCRIPT_NAME} logs' or '${SCRIPT_NAME} check' next."
  fi

  cat <<EOF_SUMMARY

Isaac Sim start requested.

Public IP:      ${public_ip}
Signal port:    ${WEBRTC_SIGNAL_PORT}/tcp
Media port:     ${WEBRTC_STREAM_PORT}/udp
Container:      ${CONTAINER_NAME}
Image:          ${ISAAC_IMAGE}
ROS 2 distro:   ${ROS_DISTRO}
ROS 2 host:     ${ros_status}
ROS_DOMAIN_ID:  ${ROS_DOMAIN_ID}
Workspace:      ${HOST_WORKSPACE_ROOT} -> ${CONTAINER_WORKSPACE}

Useful commands:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} logs
  ${SCRIPT_NAME} check
  ${SCRIPT_NAME} shell

Connect from your PC with the Isaac Sim WebRTC client to:
  ${public_ip}
EOF_SUMMARY
}

stop_isaacsim() {
  require_docker_runtime
  if docker_cmd ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    info "Stopping ${CONTAINER_NAME}..."
    docker_cmd stop "$CONTAINER_NAME" >/dev/null
  else
    warn "${CONTAINER_NAME} is not running."
  fi
}

status_all() {
  require_supported_host
  init_paths
  get_docker_cmd

  local public_ip="unknown"
  public_ip=$(get_public_ip 2>/dev/null || true)

  echo "=== Host ==="
  echo "User:            $(current_user)"
  echo "Ubuntu:          $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "Architecture:    $(dpkg --print-architecture)"
  echo "Public IP:       ${public_ip:-unknown}"
  echo

  echo "=== GPU ==="
  if have_cmd nvidia-smi; then
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
  else
    echo "nvidia-smi not found"
  fi
  echo

  echo "=== Docker ==="
  if have_cmd docker; then
    docker --version || true
    docker_cmd info --format 'Server: {{.ServerVersion}}' 2>/dev/null || true
  else
    echo "docker not installed"
  fi
  echo

  echo "=== ROS 2 ==="
  if [[ -f "$ROS_SETUP" ]]; then
    echo "Installed:       yes (${ROS_DISTRO})"
    echo "Setup script:    ${ROS_SETUP}"
  else
    echo "Installed:       no"
  fi
  echo

  echo "=== Isaac Sim Container ==="
  if have_cmd docker && docker_cmd ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker_cmd ps -a --filter "name=^/${CONTAINER_NAME}$"
  else
    echo "No container named ${CONTAINER_NAME}"
  fi
  echo

  echo "=== Listening Ports ==="
  ss -lntup | egrep ":(${WEBRTC_SIGNAL_PORT}|${WEBRTC_STREAM_PORT})\b" || echo "No listeners yet on ${WEBRTC_SIGNAL_PORT}/${WEBRTC_STREAM_PORT}"
}

logs_isaacsim() {
  require_docker_runtime
  docker_cmd logs -f "$CONTAINER_NAME"
}

shell_isaacsim() {
  require_docker_runtime
  init_paths
  docker_cmd exec -it -w "$CONTAINER_WORKSPACE" "$CONTAINER_NAME" bash
}

check_connectivity() {
  require_supported_host
  init_paths

  local public_ip
  public_ip=$(get_public_ip)

  echo "=== Server-side checks ==="
  if have_cmd docker && docker_cmd ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Container is running: ${CONTAINER_NAME}"
  else
    echo "Container is not running: ${CONTAINER_NAME}"
  fi
  echo
  echo "Listening sockets on this VM:"
  ss -lntup | egrep ":(${WEBRTC_SIGNAL_PORT}|${WEBRTC_STREAM_PORT})\b" || echo "No listeners found yet."
  echo

  echo "=== Run these on your PC ==="
  echo "TCP signaling test:"
  echo "  nc -vz ${public_ip} ${WEBRTC_SIGNAL_PORT}"
  echo
  echo "UDP media test (nmap is better for UDP):"
  echo "  nmap -sU -Pn -p ${WEBRTC_STREAM_PORT} ${public_ip}"
  echo
  echo "Isaac Sim WebRTC client target:"
  echo "  ${public_ip}"
}

run_in_isaac_container() {
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  [[ $# -gt 0 ]] || error "Usage: ${SCRIPT_NAME} run -- <command>"

  require_supported_host
  init_paths
  verify_nvidia_container_runtime
  ensure_isaac_dirs
  ensure_isaac_image
  build_common_docker_args

  info "Running one-shot command in ${ISAAC_IMAGE}..."
  info "Workspace: ${HOST_WORKSPACE_ROOT} -> ${CONTAINER_WORKSPACE}"
  docker_cmd run --rm \
    "${DOCKER_RUN_ARGS[@]}" \
    "$ISAAC_IMAGE" \
    "$@"
}

install_all() {
  require_supported_host
  init_paths
  ensure_nvidia_container_runtime
  ensure_ros2_installed
  ensure_isaac_dirs
  ensure_isaac_image
  info "All components are installed or already present."
}

main() {
  local cmd=${1:-help}
  local sub=${2:-}

  case "$cmd" in
    start)
      [[ "$sub" == "isaacsim" ]] || error "Usage: ${SCRIPT_NAME} start isaacsim"
      shift 2
      start_isaacsim "$@"
      ;;
    stop)
      [[ "$sub" == "isaacsim" ]] || error "Usage: ${SCRIPT_NAME} stop isaacsim"
      stop_isaacsim
      ;;
    restart)
      [[ "$sub" == "isaacsim" ]] || error "Usage: ${SCRIPT_NAME} restart isaacsim"
      shift 2
      stop_isaacsim || true
      start_isaacsim "$@"
      ;;
    run)
      shift
      run_in_isaac_container "$@"
      ;;
    bootstrap)
      install_all
      ;;
    status)
      status_all
      ;;
    logs)
      logs_isaacsim
      ;;
    shell)
      shell_isaacsim
      ;;
    check)
      check_connectivity
      ;;
    install)
      case "$sub" in
        all) install_all ;;
        ros2) ensure_ros2_installed ;;
        docker) ensure_nvidia_container_runtime ;;
        *) error "Usage: ${SCRIPT_NAME} install {all|ros2|docker}" ;;
      esac
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      error "Unknown command: ${cmd}. Run '${SCRIPT_NAME} help'."
      ;;
  esac
}

main "$@"
