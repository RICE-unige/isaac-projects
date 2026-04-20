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
TIGERVNC_ENABLE="${TIGERVNC_ENABLE:-0}"
TIGERVNC_DISPLAY="${TIGERVNC_DISPLAY:-1}"
TIGERVNC_PORT="${TIGERVNC_PORT:-5901}"
TIGERVNC_GEOMETRY="${TIGERVNC_GEOMETRY:-1920x1080}"
TIGERVNC_DEPTH="${TIGERVNC_DEPTH:-24}"
TIGERVNC_LOCALHOST="${TIGERVNC_LOCALHOST:-0}"
TIGERVNC_DESKTOP="${TIGERVNC_DESKTOP:-xfce}"
TIGERVNC_TERMINAL="${TIGERVNC_TERMINAL:-gnome-terminal}"
TIGERVNC_PASSWORD="${TIGERVNC_PASSWORD:-}"
VERBOSE=0
LOG_FILE="${LOG_FILE:-}"
ACTIVE_LOG_FILE=""
INVOCATION_STRING="$SCRIPT_NAME"
DOCKER_GROUP_RELOGIN_REQUIRED=0
TIGERVNC_XSTARTUP_UPDATED=0

COLOR_RESET=""
COLOR_BOLD=""
COLOR_BLUE=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_DIM=""
UI_IS_TTY=0
UI_SUPPORTS_UNICODE=0

setup_colors() {
  local charset_hint
  if [[ -t 1 ]]; then
    UI_IS_TTY=1
  fi

  charset_hint="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if command -v locale >/dev/null 2>&1; then
    charset_hint="$(locale charmap 2>/dev/null || printf '%s' "$charset_hint")"
  fi
  case "$charset_hint" in
    *UTF-8*|*utf8*|*UTF8*)
      UI_SUPPORTS_UNICODE=1
      ;;
  esac

  if [[ "$UI_IS_TTY" -eq 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_BLUE=$'\033[34m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
    COLOR_CYAN=$'\033[36m'
    COLOR_DIM=$'\033[2m'
  fi
}

clear_progress_line() {
  if [[ "$UI_IS_TTY" -eq 1 ]]; then
    printf '\r\033[2K'
  fi
}

show_progress_line() {
  if [[ "$UI_IS_TTY" -eq 1 ]]; then
    printf '\r\033[2K%s' "$1"
  fi
}

print_message() {
  local color="$1"
  local label="$2"
  local stream="$3"
  shift 3
  clear_progress_line
  if [[ "$stream" == "stderr" ]]; then
    printf '%b[%s]%b %s\n' "$color" "$label" "$COLOR_RESET" "$*" >&2
  else
    printf '%b[%s]%b %s\n' "$color" "$label" "$COLOR_RESET" "$*"
  fi
}

info()    { print_message "$COLOR_BLUE" "INFO" stdout "$*"; }
success() { print_message "$COLOR_GREEN" "OK" stdout "$*"; }
warn()    { print_message "$COLOR_YELLOW" "WARN" stderr "$*"; }
error()   { print_message "$COLOR_RED" "ERROR" stderr "$*"; exit 1; }

unexpected_error() {
  local exit_code=$?
  local line="$1"
  local command="$2"
  local message="${SCRIPT_NAME}: line ${line}: command failed: ${command}"
  if [[ -n "$ACTIVE_LOG_FILE" ]]; then
    message="${message}. See ${ACTIVE_LOG_FILE}"
  fi
  print_message "$COLOR_RED" "ERROR" stderr "$message"
  exit "$exit_code"
}

trap 'unexpected_error "${LINENO}" "${BASH_COMMAND}"' ERR

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

timestamp_compact_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

format_duration() {
  local seconds="$1"
  if (( seconds < 60 )); then
    printf '%ss' "$seconds"
  else
    printf '%sm%02ss' "$((seconds / 60))" "$((seconds % 60))"
  fi
}

repeat_char() {
  local char="$1"
  local count="$2"
  local output=""
  local i
  for ((i = 0; i < count; i++)); do
    output+="$char"
  done
  printf '%s' "$output"
}

spinner_frame() {
  local index="$1"
  if [[ "$UI_SUPPORTS_UNICODE" -eq 1 ]]; then
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    printf '%s' "${frames[$((index % ${#frames[@]}))]}"
  else
    local frames=("-" "\\" "|" "/")
    printf '%s' "${frames[$((index % ${#frames[@]}))]}"
  fi
}

status_glyph() {
  local phase="$1"
  case "$phase" in
    success)
      if [[ "$UI_SUPPORTS_UNICODE" -eq 1 ]]; then
        printf '✓'
      else
        printf 'OK'
      fi
      ;;
    failure)
      if [[ "$UI_SUPPORTS_UNICODE" -eq 1 ]]; then
        printf '✕'
      else
        printf '!!'
      fi
      ;;
  esac
}

render_progress_bar() {
  local completed="$1"
  local total="$2"
  local phase="${3:-complete}"
  local spinner_index="${4:-0}"
  local width=26
  local filled=0
  local fill_char empty_char active_char
  if (( total > 0 )); then
    filled=$((completed * width / total))
  fi

  if [[ "$UI_SUPPORTS_UNICODE" -eq 1 ]]; then
    fill_char="█"
    empty_char="░"
    if (( spinner_index % 2 == 0 )); then
      active_char="▓"
    else
      active_char="▒"
    fi
  else
    fill_char="="
    empty_char="-"
    active_char=">"
  fi

  local empty=$((width - filled))
  local bar
  bar="$(repeat_char "$fill_char" "$filled")"
  if [[ "$phase" == "active" && filled < width ]]; then
    bar+="$active_char"
    bar+="$(repeat_char "$empty_char" "$((width - filled - 1))")"
  else
    bar+="$(repeat_char "$empty_char" "$empty")"
  fi
  printf '%s[%s]%s' "$COLOR_CYAN" "$bar" "$COLOR_RESET"
}

render_install_status_line() {
  local phase="$1"
  local total="$2"
  local index="$3"
  local label="$4"
  local elapsed_seconds="$5"
  local spinner_index="${6:-0}"
  local mark mark_color bar progress_count

  case "$phase" in
    active)
      mark="$(spinner_frame "$spinner_index")"
      mark_color="$COLOR_BLUE"
      progress_count=$((index - 1))
      bar="$(render_progress_bar "$progress_count" "$total" active "$spinner_index")"
      ;;
    *)
      mark="$(spinner_frame "$spinner_index")"
      mark_color="$COLOR_BLUE"
      progress_count=$((index - 1))
      bar="$(render_progress_bar "$progress_count" "$total" active "$spinner_index")"
      ;;
  esac

  printf '%b%s%b %b[%d/%d]%b %s  %s  %b%s%b' \
    "$mark_color" "$mark" "$COLOR_RESET" \
    "$COLOR_DIM" "$index" "$total" "$COLOR_RESET" \
    "$label" \
    "$bar" \
    "$COLOR_DIM" "$(format_duration "$elapsed_seconds")" "$COLOR_RESET"
}

render_install_step_summary_line() {
  local phase="$1"
  local total="$2"
  local index="$3"
  local label="$4"
  local elapsed_seconds="$5"
  local mark mark_color

  case "$phase" in
    success)
      mark="$(status_glyph success)"
      mark_color="$COLOR_GREEN"
      ;;
    failure)
      mark="$(status_glyph failure)"
      mark_color="$COLOR_RED"
      ;;
    *)
      if [[ "$UI_SUPPORTS_UNICODE" -eq 1 ]]; then
        mark="•"
      else
        mark=">"
      fi
      mark_color="$COLOR_BLUE"
      ;;
  esac

  printf '%b%s%b %b[%d/%d]%b %s  %b%s%b' \
    "$mark_color" "$mark" "$COLOR_RESET" \
    "$COLOR_DIM" "$index" "$total" "$COLOR_RESET" \
    "$label" \
    "$COLOR_DIM" "$(format_duration "$elapsed_seconds")" "$COLOR_RESET"
}

use_live_progress_ui() {
  [[ "$VERBOSE" -eq 0 && "$UI_IS_TTY" -eq 1 ]]
}

print_live_status_line() {
  local stream="${2:-stdout}"
  clear_progress_line
  if [[ "$stream" == "stderr" ]]; then
    printf '%s\n' "$1" >&2
  else
    printf '%s\n' "$1"
  fi
}

start_install_spinner() {
  local total="$1"
  local index="$2"
  local label="$3"

  if ! use_live_progress_ui; then
    return 0
  fi

  (
    trap 'exit 0' TERM INT
    local spinner_index=0
    local started_at=$SECONDS
    while :; do
      show_progress_line "$(render_install_status_line active "$total" "$index" "$label" "$((SECONDS - started_at))" "$spinner_index")"
      sleep 0.12
      spinner_index=$((spinner_index + 1))
    done
  ) &
  INSTALL_SPINNER_PID=$!
}

stop_install_spinner() {
  local spinner_pid="${INSTALL_SPINNER_PID:-}"
  if [[ -n "$spinner_pid" ]]; then
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    INSTALL_SPINNER_PID=""
  fi
  clear_progress_line
}

parse_common_flags() {
  local -a parsed=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose|-v)
        VERBOSE=1
        ;;
      --log-file)
        [[ $# -ge 2 ]] || error "--log-file requires a path."
        LOG_FILE="$2"
        shift
        ;;
      *)
        parsed+=("$1")
        ;;
    esac
    shift
  done
  PARSED_ARGS=("${parsed[@]}")
}

parse_leading_common_flags() {
  local -a remaining=("$@")
  while [[ ${#remaining[@]} -gt 0 ]]; do
    case "${remaining[0]}" in
      --verbose|-v)
        VERBOSE=1
        remaining=("${remaining[@]:1}")
        ;;
      --log-file)
        [[ ${#remaining[@]} -ge 2 ]] || error "--log-file requires a path."
        LOG_FILE="${remaining[1]}"
        remaining=("${remaining[@]:2}")
        ;;
      *)
        break
        ;;
    esac
  done
  PARSED_ARGS=("${remaining[@]}")
}

prepare_log_file() {
  local label="$1"
  if [[ -n "$ACTIVE_LOG_FILE" ]]; then
    return 0
  fi

  if [[ -n "$LOG_FILE" ]]; then
    ACTIVE_LOG_FILE="$LOG_FILE"
  else
    local log_root
    log_root="$(home_dir)/.local/state/isaac-projects/logs"
    ACTIVE_LOG_FILE="${log_root}/${label}_$(timestamp_compact_utc).log"
  fi

  mkdir -p "$(dirname "$ACTIVE_LOG_FILE")"
  : >"$ACTIVE_LOG_FILE"
  {
    printf '[%s] Command: %s\n' "$(timestamp_utc)" "$INVOCATION_STRING"
    printf '[%s] Log mode: %s\n' "$(timestamp_utc)" "$([[ "$VERBOSE" -eq 1 ]] && printf 'verbose' || printf 'summary')"
  } >>"$ACTIVE_LOG_FILE"
}

show_install_log_hint() {
  local label="$1"
  info "${label} log: ${ACTIVE_LOG_FILE}"
  if [[ "$VERBOSE" -eq 0 ]]; then
    info "Use --verbose to stream the full installer output, or run: tail -f ${ACTIVE_LOG_FILE}"
  fi
}

run_logged() {
  local total="$1"
  local index="$2"
  local label="$3"
  shift 3

  {
    printf '\n[%s] %s\n' "$(timestamp_utc)" "$label"
  } >>"$ACTIVE_LOG_FILE"

  if [[ "$VERBOSE" -eq 1 ]]; then
    if "$@" > >(tee -a "$ACTIVE_LOG_FILE") 2> >(tee -a "$ACTIVE_LOG_FILE" >&2); then
      return 0
    fi
    return $?
  fi

  local exit_code=0
  start_install_spinner "$total" "$index" "$label"
  if "$@" >>"$ACTIVE_LOG_FILE" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi
  stop_install_spinner
  return "$exit_code"
}

run_install_step() {
  local total="$1"
  local index="$2"
  local label="$3"
  shift 3

  local started_at=$SECONDS
  if ! use_live_progress_ui; then
    info "[${index}/${total}] ${label}"
  fi

  if run_logged "$total" "$index" "$label" "$@"; then
    if use_live_progress_ui; then
      print_live_status_line "$(render_install_step_summary_line success "$total" "$index" "$label" "$((SECONDS - started_at))")"
    else
      success "[${index}/${total}] ${label}  $(format_duration "$((SECONDS - started_at))")"
    fi
    return 0
  fi

  if use_live_progress_ui; then
    print_live_status_line "$(render_install_step_summary_line failure "$total" "$index" "$label" "$((SECONDS - started_at))")" stderr
  fi
  if [[ "$VERBOSE" -eq 0 ]]; then
    warn "Last 25 log lines:"
    tail -n 25 "$ACTIVE_LOG_FILE" >&2 || true
  fi
  error "Failed during '${label}'. Full log: ${ACTIVE_LOG_FILE}"
}

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} bootstrap [--verbose] [--log-file <path>]
                                 Install/repair Docker, NVIDIA runtime, ROS 2, and pull the Isaac Sim image.
                                 Also installs and starts TigerVNC when TIGERVNC_ENABLE=1.
  ${SCRIPT_NAME} bootstrap zenoh|bridge [--force]
                                 Download or refresh the Zenoh bridge binary under zenoh/.
  ${SCRIPT_NAME} start isaacsim      Start Isaac Sim with WebRTC.
  ${SCRIPT_NAME} start tigervnc|vnc  Install/start the TigerVNC desktop.
  ${SCRIPT_NAME} start zenoh|bridge [port] [--domain <id>] [--namespace <ns>] [--config <file>]
                                 Start the server-side Zenoh ROS 2 bridge.
  ${SCRIPT_NAME} start isaacsim --headless
                                 Start Isaac Sim without WebRTC flags.
  ${SCRIPT_NAME} run [--livestream public|private] [--enable-cameras] [--public-ip <ip>] -- <command>
                                 Run a one-shot command inside the Isaac Sim container image.
  ${SCRIPT_NAME} stop isaacsim       Stop the Isaac Sim container.
  ${SCRIPT_NAME} stop tigervnc|vnc   Stop the TigerVNC desktop.
  ${SCRIPT_NAME} restart isaacsim    Restart Isaac Sim.
  ${SCRIPT_NAME} status              Show VM / Docker / Isaac Sim / ROS status.
  ${SCRIPT_NAME} logs                Show Isaac Sim container logs.
  ${SCRIPT_NAME} shell               Open a shell in the running Isaac Sim container.
  ${SCRIPT_NAME} install all [--verbose] [--log-file <path>]
                                 Install/repair Docker, NVIDIA container runtime, ROS 2, and Isaac Sim image.
  ${SCRIPT_NAME} install ros2 [--verbose] [--log-file <path>]
                                 Install/repair ROS 2 only.
  ${SCRIPT_NAME} install docker [--verbose] [--log-file <path>]
                                 Install/repair Docker + NVIDIA container runtime only.
  ${SCRIPT_NAME} install zenoh|bridge [--force]
                                 Download or refresh the Zenoh bridge binary under zenoh/.
  ${SCRIPT_NAME} install tigervnc|vnc [--verbose] [--log-file <path>]
                                 Install/start the TigerVNC desktop.
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
  HOST_WORKSPACE_ROOT=<repo-root>
  CONTAINER_WORKSPACE=/workspace/isaac-projects
  CONTAINER_UID=<host-uid>            # optional; defaults to current user
  CONTAINER_GID=<host-gid>            # optional; defaults to current user
  ALLOWED_CLIENT_IP=<your-public-ip>   # only applied if ufw is already active
  TIGERVNC_ENABLE=0|1                  # when 1, bootstrap installs/starts TigerVNC
  TIGERVNC_DISPLAY=1
  TIGERVNC_PORT=5901
  TIGERVNC_GEOMETRY=1920x1080
  TIGERVNC_DEPTH=24
  TIGERVNC_LOCALHOST=0|1               # 0 listens on all interfaces; 1 binds localhost only
  TIGERVNC_DESKTOP=xfce|gnome-flashback
  TIGERVNC_TERMINAL=gnome-terminal
  TIGERVNC_PASSWORD=<8-char-password>  # optional; generated once when unset
  PRIVACY_USERID=<email>
  ISAAC_EXTRA_ARGS='<extra Isaac Sim args>'
  NGC_API_KEY=<your-ngc-api-key>       # optional, only used if image pull requires login

Optional flags:
  --verbose, -v                      Stream detailed bootstrap/install logs live.
  --log-file <path>                  Write bootstrap/install logs to a specific file.

Examples:
  ${SCRIPT_NAME} bootstrap
  TIGERVNC_ENABLE=1 ${SCRIPT_NAME} bootstrap
  ${SCRIPT_NAME} bootstrap --verbose
  ${SCRIPT_NAME} bootstrap zenoh
  ${SCRIPT_NAME} bootstrap bridge --force
  ${SCRIPT_NAME} start isaacsim
  ${SCRIPT_NAME} start tigervnc
  ${SCRIPT_NAME} start zenoh
  ${SCRIPT_NAME} start bridge 7447 --domain 0
  ${SCRIPT_NAME} start isaacsim --headless
  ${SCRIPT_NAME} run -- bash -lc 'cd projects/my-project && python train.py'
  ${SCRIPT_NAME} run --livestream public -- bash -lc 'cd external/IsaacLab && ./isaaclab.sh -p scripts/tutorials/00_sim/launch_app.py'
  ${SCRIPT_NAME} run --livestream public --enable-cameras -- bash -lc 'cd external/IsaacLab && ./isaaclab.sh -p scripts/demos/quadrupeds.py'
  ROS_INSTALL_VARIANT=desktop ${SCRIPT_NAME} install ros2
  ${SCRIPT_NAME} install docker --log-file /tmp/isaac-bootstrap.log
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

is_truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

as_current_user() {
  local target_user="${USER_NAME:-$(current_user)}"
  local target_home="${USER_HOME:-$(home_dir)}"

  if [[ ${EUID} -eq 0 && -n "${USER_NAME:-}" && "$USER_NAME" != "root" ]]; then
    runuser -u "$target_user" -- env HOME="$target_home" USER="$target_user" LOGNAME="$target_user" "$@"
  else
    env HOME="$target_home" USER="$target_user" LOGNAME="$target_user" "$@"
  fi
}

install_for_current_user() {
  local mode="$1"
  local src="$2"
  local dst="$3"
  local user_group
  user_group=$(id -gn "$USER_NAME")

  if [[ ${EUID} -eq 0 ]]; then
    install -o "$USER_NAME" -g "$user_group" -m "$mode" "$src" "$dst"
  else
    install -m "$mode" "$src" "$dst"
  fi
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
  as_root apt-get install -y ca-certificates curl gnupg software-properties-common lsb-release iproute2 net-tools netcat-openbsd rsync
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
      DOCKER_GROUP_RELOGIN_REQUIRED=1
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

  ensure_ros_setup_in_bashrc
}

ensure_ros_setup_in_bashrc() {
  local bashrc_path="${USER_HOME}/.bashrc"
  local marker_begin="# >>> isaac-projects ROS 2 setup >>>"
  local marker_end="# <<< isaac-projects ROS 2 setup <<<"
  local setup_line_quoted="source \"${ROS_SETUP}\""
  local setup_line_unquoted="source ${ROS_SETUP}"
  local tmp_file user_group

  mkdir -p "$USER_HOME"
  touch "$bashrc_path"

  if ! grep -Fqx "$marker_begin" "$bashrc_path" && \
     { grep -Fqx "$setup_line_quoted" "$bashrc_path" || grep -Fqx "$setup_line_unquoted" "$bashrc_path"; }; then
    info "ROS 2 setup already sourced in ${bashrc_path}."
    return 0
  fi

  tmp_file=$(mktemp)
  if grep -Fqx "$marker_begin" "$bashrc_path"; then
    awk -v begin="$marker_begin" -v end="$marker_end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$bashrc_path" >"$tmp_file"
  else
    cp "$bashrc_path" "$tmp_file"
  fi

  {
    printf '\n%s\n' "$marker_begin"
    printf 'if [ -f "%s" ]; then\n' "$ROS_SETUP"
    printf '  source "%s"\n' "$ROS_SETUP"
    printf 'fi\n'
    printf '%s\n' "$marker_end"
  } >>"$tmp_file"

  if [[ ${EUID} -eq 0 ]]; then
    user_group=$(id -gn "$USER_NAME")
    install -o "$USER_NAME" -g "$user_group" -m 0644 "$tmp_file" "$bashrc_path"
  else
    install -m 0644 "$tmp_file" "$bashrc_path"
  fi
  rm -f "$tmp_file"
  info "Ensured ROS 2 setup is sourced from ${bashrc_path}."
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

validate_tigervnc_config() {
  TIGERVNC_DISPLAY="${TIGERVNC_DISPLAY#:}"

  [[ "$TIGERVNC_DISPLAY" =~ ^[0-9]+$ ]] || error "TIGERVNC_DISPLAY must be a number, for example 1."
  [[ "$TIGERVNC_DISPLAY" -ge 1 && "$TIGERVNC_DISPLAY" -le 99 ]] || error "TIGERVNC_DISPLAY must be between 1 and 99."

  if [[ -z "$TIGERVNC_PORT" ]]; then
    TIGERVNC_PORT=$((5900 + TIGERVNC_DISPLAY))
  fi
  [[ "$TIGERVNC_PORT" =~ ^[0-9]+$ ]] || error "TIGERVNC_PORT must be a TCP port number."
  [[ "$TIGERVNC_PORT" -ge 1 && "$TIGERVNC_PORT" -le 65535 ]] || error "TIGERVNC_PORT must be between 1 and 65535."

  [[ "$TIGERVNC_GEOMETRY" =~ ^[0-9]+x[0-9]+$ ]] || error "TIGERVNC_GEOMETRY must look like 1920x1080."
  [[ "$TIGERVNC_DEPTH" =~ ^[0-9]+$ ]] || error "TIGERVNC_DEPTH must be a number."

  case "$TIGERVNC_DESKTOP" in
    xfce|gnome-flashback) ;;
    *) error "TIGERVNC_DESKTOP must be 'xfce' or 'gnome-flashback'." ;;
  esac
}

tigervnc_desktop_label() {
  case "$TIGERVNC_DESKTOP" in
    xfce) printf 'XFCE desktop with GNOME Terminal and Ubuntu Yaru theme' ;;
    gnome-flashback) printf 'GNOME Flashback with Ubuntu Yaru theme' ;;
    *) printf '%s' "$TIGERVNC_DESKTOP" ;;
  esac
}

ensure_tigervnc_desktop_installed() {
  local -a packages missing
  packages=(
    tigervnc-standalone-server
    tigervnc-common
    xfce4
    xfce4-goodies
    xfce4-terminal
    gnome-session-flashback
    metacity
    dbus-x11
    xauth
    x11-xserver-utils
    xterm
    gnome-terminal
    nautilus
    thunar
    adwaita-icon-theme
    yaru-theme-gtk
    yaru-theme-icon
  )
  missing=()

  local pkg
  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    info "TigerVNC desktop packages are already installed."
    return 0
  fi

  info "Installing TigerVNC desktop packages..."
  ensure_common_apt_bits
  as_root add-apt-repository -y universe
  as_root apt-get update -y
  as_root apt-get install -y "${missing[@]}"
}

ensure_tigervnc_user_files() {
  TIGERVNC_XSTARTUP_UPDATED=0

  local vnc_dir="${USER_HOME}/.vnc"
  local xstartup_path="${vnc_dir}/xstartup"
  local passwd_path="${vnc_dir}/passwd"
  local generated_password_path="${vnc_dir}/isaac-projects-vnc-password.txt"
  local user_group
  user_group=$(id -gn "$USER_NAME")

  mkdir -p "$vnc_dir"
  if [[ ${EUID} -eq 0 ]]; then
    chown "$USER_NAME:$user_group" "$vnc_dir"
  fi
  chmod 700 "$vnc_dir"

  local tmp_xstartup
  tmp_xstartup=$(mktemp)
  cat >"$tmp_xstartup" <<'EOF_XSTARTUP'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

TIGERVNC_DESKTOP="${TIGERVNC_DESKTOP:-xfce}"
TIGERVNC_TERMINAL="${TIGERVNC_TERMINAL:-gnome-terminal}"
TIGERVNC_GTK_THEME="${TIGERVNC_GTK_THEME:-Yaru}"
TIGERVNC_ICON_THEME="${TIGERVNC_ICON_THEME:-Yaru}"

export TIGERVNC_DESKTOP TIGERVNC_TERMINAL TIGERVNC_GTK_THEME TIGERVNC_ICON_THEME
export XDG_SESSION_TYPE=x11
export GTK_THEME="$TIGERVNC_GTK_THEME"

if [[ -r "$HOME/.profile" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.profile"
fi

case "$TIGERVNC_DESKTOP" in
  xfce)
    export XDG_CURRENT_DESKTOP=XFCE
    export XDG_SESSION_DESKTOP=xfce
    export DESKTOP_SESSION=xfce
    if command -v startxfce4 >/dev/null 2>&1; then
      exec dbus-run-session -- bash -lc '
        xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "${TIGERVNC_GTK_THEME:-Yaru}" >/dev/null 2>&1 || true
        xfconf-query -c xsettings -p /Net/IconThemeName -n -t string -s "${TIGERVNC_ICON_THEME:-Yaru}" >/dev/null 2>&1 || true
        xfconf-query -c xsettings -p /Gtk/MonospaceFontName -n -t string -s "Ubuntu Mono 12" >/dev/null 2>&1 || true
        xfconf-query -c xfce4-session -p /general/SaveOnExit -n -t bool -s false >/dev/null 2>&1 || true
        if command -v "${TIGERVNC_TERMINAL:-gnome-terminal}" >/dev/null 2>&1; then
          mkdir -p "$HOME/.local/share/applications"
          xdg-mime default org.gnome.Terminal.desktop x-scheme-handler/terminal >/dev/null 2>&1 || true
        fi
        exec startxfce4
      '
    fi
    ;;
  gnome-flashback)
    export XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME
    export XDG_SESSION_DESKTOP=gnome-flashback-metacity
    export DESKTOP_SESSION=gnome-flashback-metacity
    if command -v gnome-session >/dev/null 2>&1; then
      exec dbus-run-session -- gnome-session --session=gnome-flashback-metacity
    fi
    ;;
esac

if command -v "$TIGERVNC_TERMINAL" >/dev/null 2>&1; then
  exec "$TIGERVNC_TERMINAL"
fi
exec xterm
EOF_XSTARTUP
  if [[ ! -f "$xstartup_path" ]] || ! cmp -s "$tmp_xstartup" "$xstartup_path"; then
    TIGERVNC_XSTARTUP_UPDATED=1
  fi
  install_for_current_user 0755 "$tmp_xstartup" "$xstartup_path"
  rm -f "$tmp_xstartup"

  local xfce_config_dir="${USER_HOME}/.config/xfce4"
  local helpers_path="${xfce_config_dir}/helpers.rc"
  local desktop_dir="${USER_HOME}/Desktop"
  local terminal_desktop_path="${desktop_dir}/GNOME Terminal.desktop"
  mkdir -p "$xfce_config_dir" "$desktop_dir"
  if [[ ${EUID} -eq 0 ]]; then
    chown "$USER_NAME:$user_group" "${USER_HOME}/.config" "$xfce_config_dir" "$desktop_dir"
  fi

  local tmp_helpers
  tmp_helpers=$(mktemp)
  cat >"$tmp_helpers" <<'EOF_HELPERS'
TerminalEmulator=gnome-terminal
EOF_HELPERS
  install_for_current_user 0644 "$tmp_helpers" "$helpers_path"
  rm -f "$tmp_helpers"

  local tmp_terminal_desktop
  tmp_terminal_desktop=$(mktemp)
  cat >"$tmp_terminal_desktop" <<'EOF_TERMINAL_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=GNOME Terminal
Comment=Open a command line
Exec=gnome-terminal
Icon=org.gnome.Terminal
Terminal=false
Categories=System;TerminalEmulator;
EOF_TERMINAL_DESKTOP
  install_for_current_user 0755 "$tmp_terminal_desktop" "$terminal_desktop_path"
  rm -f "$tmp_terminal_desktop"

  local password generated_password tmp_pass tmp_plain
  generated_password=0
  if [[ -n "$TIGERVNC_PASSWORD" ]]; then
    password="$TIGERVNC_PASSWORD"
  elif [[ -f "$generated_password_path" ]]; then
    password=$(tr -d '\r\n' <"$generated_password_path")
  else
    password=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    generated_password=1
  fi

  [[ -n "$password" ]] || error "TigerVNC password is empty. Set TIGERVNC_PASSWORD and retry."
  if [[ ${#password} -gt 8 ]]; then
    warn "TigerVNC classic VNC authentication uses only the first 8 password characters."
    password="${password:0:8}"
  fi

  tmp_pass=$(mktemp)
  printf '%s\n' "$password" | vncpasswd -f >"$tmp_pass"
  install_for_current_user 0600 "$tmp_pass" "$passwd_path"
  rm -f "$tmp_pass"

  if [[ "$generated_password" -eq 1 ]]; then
    tmp_plain=$(mktemp)
    printf '%s\n' "$password" >"$tmp_plain"
    install_for_current_user 0600 "$tmp_plain" "$generated_password_path"
    rm -f "$tmp_plain"
    info "Generated TigerVNC password saved to ${generated_password_path}."
  elif [[ -f "$generated_password_path" && -z "$TIGERVNC_PASSWORD" ]]; then
    info "Using existing generated TigerVNC password from ${generated_password_path}."
  else
    info "Using TigerVNC password from TIGERVNC_PASSWORD."
  fi
}

configure_tigervnc_ufw_if_active() {
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

  info "ufw is active; ensuring a TigerVNC rule exists..."
  if [[ -n "$ALLOWED_CLIENT_IP" ]]; then
    as_root ufw allow from "$ALLOWED_CLIENT_IP" to any port "$TIGERVNC_PORT" proto tcp
  else
    as_root ufw allow "${TIGERVNC_PORT}/tcp"
  fi
}

tigervnc_port_listening() {
  ss -lnt | awk '{print $4}' | grep -Eq "[:.]${TIGERVNC_PORT}$"
}

tigervnc_display_running() {
  have_cmd vncserver || return 1
  as_current_user vncserver -list 2>/dev/null | awk '{print $1}' | grep -qx ":${TIGERVNC_DISPLAY}"
}

start_tigervnc_server() {
  local display=":${TIGERVNC_DISPLAY}"
  local localhost_value="no"
  if is_truthy "$TIGERVNC_LOCALHOST"; then
    localhost_value="yes"
  fi

  if tigervnc_display_running && tigervnc_port_listening && [[ "$TIGERVNC_XSTARTUP_UPDATED" -eq 0 ]]; then
    info "TigerVNC already listening on ${TIGERVNC_PORT}/tcp."
    return 0
  fi
  if tigervnc_port_listening && ! tigervnc_display_running; then
    error "TCP ${TIGERVNC_PORT} is already in use. Choose a different TIGERVNC_PORT."
  fi

  if tigervnc_display_running && [[ "$TIGERVNC_XSTARTUP_UPDATED" -eq 1 ]]; then
    info "TigerVNC startup file changed; restarting display ${display}."
  fi
  as_current_user vncserver -kill "$display" >/dev/null 2>&1 || true

  info "Starting TigerVNC desktop on ${display} (${TIGERVNC_PORT}/tcp, ${TIGERVNC_GEOMETRY})..."
  as_current_user vncserver "$display" \
    -geometry "$TIGERVNC_GEOMETRY" \
    -depth "$TIGERVNC_DEPTH" \
    -rfbport "$TIGERVNC_PORT" \
    -localhost "$localhost_value"

  local _
  for _ in $(seq 1 15); do
    if tigervnc_port_listening; then
      info "TigerVNC is listening on ${TIGERVNC_PORT}/tcp."
      return 0
    fi
    sleep 1
  done

  warn "TigerVNC did not appear on ${TIGERVNC_PORT}/tcp yet. Check ${USER_HOME}/.vnc/*.log."
  return 1
}

print_tigervnc_connection_summary() {
  validate_tigervnc_config

  local public_ip password_hint
  public_ip=$(get_public_ip 2>/dev/null || true)
  password_hint="${USER_HOME}/.vnc/isaac-projects-vnc-password.txt"

  echo
  echo "TigerVNC desktop:"
  echo "  Target:       ${public_ip:-<server-ip>}:${TIGERVNC_PORT}"
  echo "  Display:      :${TIGERVNC_DISPLAY}"
  echo "  Geometry:     ${TIGERVNC_GEOMETRY}"
  echo "  Desktop:      $(tigervnc_desktop_label)"
  if [[ -f "$password_hint" && -z "$TIGERVNC_PASSWORD" ]]; then
    echo "  Password:     ${password_hint}"
  else
    echo "  Password:     value supplied by TIGERVNC_PASSWORD"
  fi
}

ensure_tigervnc_ready() {
  require_supported_host
  init_paths
  validate_tigervnc_config
  ensure_tigervnc_desktop_installed
  ensure_tigervnc_user_files
  configure_tigervnc_ufw_if_active
  start_tigervnc_server
}

stop_tigervnc_server() {
  require_supported_host
  init_paths
  validate_tigervnc_config

  local display=":${TIGERVNC_DISPLAY}"
  if have_cmd vncserver; then
    info "Stopping TigerVNC display ${display}..."
    as_current_user vncserver -kill "$display" || warn "TigerVNC display ${display} was not running."
  else
    warn "vncserver is not installed."
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

  echo "=== TigerVNC Desktop ==="
  echo "Enabled:         ${TIGERVNC_ENABLE}"
  echo "Display:         :${TIGERVNC_DISPLAY#:}"
  echo "Port:            ${TIGERVNC_PORT}/tcp"
  if have_cmd vncserver; then
    as_current_user vncserver -list || true
  else
    echo "vncserver not installed"
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
  ss -lntup | egrep ":(${WEBRTC_SIGNAL_PORT}|${WEBRTC_STREAM_PORT}|${TIGERVNC_PORT})\b" || echo "No listeners yet on ${WEBRTC_SIGNAL_PORT}/${WEBRTC_STREAM_PORT}/${TIGERVNC_PORT}"
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
  ss -lntup | egrep ":(${WEBRTC_SIGNAL_PORT}|${WEBRTC_STREAM_PORT}|${TIGERVNC_PORT})\b" || echo "No listeners found yet."
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
  if is_truthy "$TIGERVNC_ENABLE" || tigervnc_port_listening; then
    echo
    echo "TigerVNC TCP test:"
    echo "  nc -vz ${public_ip} ${TIGERVNC_PORT}"
    echo
    echo "TigerVNC client target:"
    echo "  ${public_ip}:${TIGERVNC_PORT}"
  fi
}

run_in_isaac_container() {
  local livestream_mode="0"
  local enable_cameras="0"
  local public_ip=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --livestream)
        [[ $# -ge 2 ]] || error "--livestream requires 'public' or 'private'."
        case "$2" in
          public) livestream_mode="1" ;;
          private) livestream_mode="2" ;;
          *) error "--livestream must be 'public' or 'private'." ;;
        esac
        shift 2
        ;;
      --enable-cameras)
        enable_cameras="1"
        shift
        ;;
      --public-ip)
        [[ $# -ge 2 ]] || error "--public-ip requires an IPv4 or hostname value."
        public_ip="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        error "Usage: ${SCRIPT_NAME} run [--livestream public|private] [--enable-cameras] [--public-ip <ip>] -- <command>"
        ;;
    esac
  done

  [[ $# -gt 0 ]] || error "Usage: ${SCRIPT_NAME} run [--livestream public|private] [--enable-cameras] [--public-ip <ip>] -- <command>"

  require_supported_host
  init_paths
  verify_nvidia_container_runtime
  ensure_isaac_dirs
  ensure_isaac_image
  if [[ "$livestream_mode" != "0" ]]; then
    configure_ufw_if_active
  fi
  build_common_docker_args

  if [[ "$livestream_mode" != "0" ]]; then
    DOCKER_RUN_ARGS+=(-e "LIVESTREAM=${livestream_mode}")
    if [[ "$livestream_mode" == "1" ]]; then
      if [[ -z "$public_ip" ]]; then
        public_ip=$(get_public_ip)
      fi
      DOCKER_RUN_ARGS+=(-e "PUBLIC_IP=${public_ip}")
    elif [[ -n "$public_ip" ]]; then
      DOCKER_RUN_ARGS+=(-e "PUBLIC_IP=${public_ip}")
    fi
  fi

  if [[ "$enable_cameras" == "1" ]]; then
    DOCKER_RUN_ARGS+=(-e "ENABLE_CAMERAS=1")
  fi

  info "Running one-shot command in ${ISAAC_IMAGE}..."
  info "Workspace: ${HOST_WORKSPACE_ROOT} -> ${CONTAINER_WORKSPACE}"
  if [[ "$livestream_mode" == "1" ]]; then
    info "Isaac Lab livestream mode: public WebRTC"
    info "Connect the Isaac Sim WebRTC client to: ${public_ip}"
    info "Required ports on the host: ${WEBRTC_SIGNAL_PORT}/tcp and ${WEBRTC_STREAM_PORT}/udp"
    info "If this IP is wrong for your cloud provider or VPN setup, rerun with --public-ip <reachable-ip>."
  elif [[ "$livestream_mode" == "2" ]]; then
    info "Isaac Lab livestream mode: private/local WebRTC"
    if [[ -n "$public_ip" ]]; then
      info "Configured reachable client target: ${public_ip}"
    else
      info "Use the host IP reachable from your laptop in the Isaac Sim WebRTC client."
    fi
    info "Required ports on the host: ${WEBRTC_SIGNAL_PORT}/tcp and ${WEBRTC_STREAM_PORT}/udp"
  fi
  if [[ "$enable_cameras" == "1" ]]; then
    info "ENABLE_CAMERAS=1 will be set inside the container."
  fi
  docker_cmd run --rm \
    "${DOCKER_RUN_ARGS[@]}" \
    "$ISAAC_IMAGE" \
    "$@"
}

prepare_host_context() {
  require_supported_host
  init_paths
}

begin_install_session() {
  local label="$1"
  prepare_log_file "$label"
  info "Installer output is summarized in the terminal."
  show_install_log_hint "$label"
}

print_install_success_summary() {
  local label="$1"
  success "${label} completed successfully."
  info "Detailed log: ${ACTIVE_LOG_FILE}"
  if [[ "$DOCKER_GROUP_RELOGIN_REQUIRED" -eq 1 ]]; then
    warn "Docker group membership changed during install. Open a new shell before running plain 'docker' without sudo."
  fi
}

zenoh_setup() {
  local setup_script="${SCRIPT_DIR}/zenoh/setup.sh"
  [[ -f "$setup_script" ]] || error "Zenoh setup script not found at ${setup_script}"
  exec bash "$setup_script" "$@"
}

zenoh_start_bridge() {
  local start_script="${SCRIPT_DIR}/zenoh/start_zenoh_bridge.sh"
  [[ -f "$start_script" ]] || error "Zenoh start script not found at ${start_script}"
  exec bash "$start_script" "$@"
}

install_docker_stack() {
  begin_install_session "install-docker"
  run_install_step 2 1 "Validate host and workspace settings" prepare_host_context
  run_install_step 2 2 "Install or verify Docker and NVIDIA Container Toolkit" ensure_nvidia_container_runtime
  print_install_success_summary "Docker and NVIDIA runtime setup"
}

install_ros2_stack() {
  begin_install_session "install-ros2"
  run_install_step 2 1 "Validate host and workspace settings" prepare_host_context
  run_install_step 2 2 "Install or verify ROS 2" ensure_ros2_installed
  print_install_success_summary "ROS 2 setup"
}

install_tigervnc_stack() {
  begin_install_session "install-tigervnc"
  run_install_step 2 1 "Validate host and workspace settings" prepare_host_context
  run_install_step 2 2 "Install and start TigerVNC desktop" ensure_tigervnc_ready
  print_install_success_summary "TigerVNC desktop setup"
  print_tigervnc_connection_summary
}

install_all() {
  local total_steps=5
  if is_truthy "$TIGERVNC_ENABLE"; then
    total_steps=6
  fi

  begin_install_session "bootstrap"
  run_install_step "$total_steps" 1 "Validate host and workspace settings" prepare_host_context
  run_install_step "$total_steps" 2 "Install or verify Docker and NVIDIA Container Toolkit" ensure_nvidia_container_runtime
  run_install_step "$total_steps" 3 "Install or verify ROS 2" ensure_ros2_installed
  run_install_step "$total_steps" 4 "Prepare Isaac Sim cache and data directories" ensure_isaac_dirs
  run_install_step "$total_steps" 5 "Pull or verify the Isaac Sim container image" ensure_isaac_image
  if is_truthy "$TIGERVNC_ENABLE"; then
    run_install_step "$total_steps" 6 "Install and start TigerVNC desktop" ensure_tigervnc_ready
  fi
  print_install_success_summary "Bootstrap"
  if is_truthy "$TIGERVNC_ENABLE"; then
    print_tigervnc_connection_summary
  fi
}

main() {
  setup_colors
  parse_leading_common_flags "$@"
  set -- "${PARSED_ARGS[@]}"
  INVOCATION_STRING="${SCRIPT_NAME}"
  if [[ $# -gt 0 ]]; then
    INVOCATION_STRING+=" $*"
  fi

  local cmd=${1:-help}
  local sub=${2:-}

  case "$cmd" in
    start)
      case "$sub" in
        isaacsim)
          shift 2
          start_isaacsim "$@"
          ;;
        tigervnc|vnc)
          shift 2
          [[ $# -eq 0 ]] || error "Usage: ${SCRIPT_NAME} start {tigervnc|vnc}"
          ensure_tigervnc_ready
          print_tigervnc_connection_summary
          ;;
        zenoh|bridge)
          shift 2
          zenoh_start_bridge "$@"
          ;;
        *)
          error "Usage: ${SCRIPT_NAME} start {isaacsim|tigervnc|vnc|zenoh|bridge}"
          ;;
      esac
      ;;
    stop)
      case "$sub" in
        isaacsim)
          stop_isaacsim
          ;;
        tigervnc|vnc)
          stop_tigervnc_server
          ;;
        *)
          error "Usage: ${SCRIPT_NAME} stop {isaacsim|tigervnc|vnc}"
          ;;
      esac
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
      case "$sub" in
        zenoh|bridge)
          shift 2
          zenoh_setup "$@"
          ;;
        *)
          shift
          parse_common_flags "$@"
          [[ ${#PARSED_ARGS[@]} -eq 0 ]] || error "Usage: ${SCRIPT_NAME} bootstrap [--verbose] [--log-file <path>] | ${SCRIPT_NAME} bootstrap {zenoh|bridge} [--force]"
          install_all
          ;;
      esac
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
        all)
          shift 2
          parse_common_flags "$@"
          [[ ${#PARSED_ARGS[@]} -eq 0 ]] || error "Usage: ${SCRIPT_NAME} install all [--verbose] [--log-file <path>]"
          install_all
          ;;
        ros2)
          shift 2
          parse_common_flags "$@"
          [[ ${#PARSED_ARGS[@]} -eq 0 ]] || error "Usage: ${SCRIPT_NAME} install ros2 [--verbose] [--log-file <path>]"
          install_ros2_stack
          ;;
        docker)
          shift 2
          parse_common_flags "$@"
          [[ ${#PARSED_ARGS[@]} -eq 0 ]] || error "Usage: ${SCRIPT_NAME} install docker [--verbose] [--log-file <path>]"
          install_docker_stack
          ;;
        zenoh|bridge)
          shift 2
          zenoh_setup "$@"
          ;;
        tigervnc|vnc)
          shift 2
          parse_common_flags "$@"
          [[ ${#PARSED_ARGS[@]} -eq 0 ]] || error "Usage: ${SCRIPT_NAME} install {tigervnc|vnc} [--verbose] [--log-file <path>]"
          install_tigervnc_stack
          ;;
        *) error "Usage: ${SCRIPT_NAME} install {all|ros2|docker|zenoh|bridge|tigervnc|vnc}" ;;
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
