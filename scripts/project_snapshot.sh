#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")

readonly DEFAULT_INCLUDE_PATHS=(
  "artifacts/checkpoints"
  "artifacts/logs"
  "artifacts/videos"
)

cleanup_paths=()

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local path
  for path in "${cleanup_paths[@]:-}"; do
    [[ -e "$path" ]] && rm -rf "$path"
  done
}

trap cleanup EXIT

register_cleanup() {
  cleanup_paths+=("$1")
}

usage() {
  cat <<'EOF'
Usage:
  scripts/project_snapshot.sh save --project <name-or-path> [options]
  scripts/project_snapshot.sh restore --project <name-or-path> --snapshot <path-or-rsync-source> [options]

Save options:
  --project <name-or-path>            Required; accepts my-project or projects/my-project
  --label <label>                     Optional snapshot label; defaults to UTC timestamp
  --include <project-relative-path>   Repeatable include path within the project
  --note <text>                       Optional note stored in the manifest
  --resume-command <command>          Optional resume command stored in the manifest
  --git-commit                        Create a repo-wide commit before saving if dirty
  --git-push                          Push the current branch after the optional commit
  --rsync-target <user@host:/path/>   Upload archive, manifest, and checksum after local save

Restore options:
  --project <name-or-path>            Required; accepts my-project or projects/my-project
  --snapshot <path-or-rsync-source>   Required; local archive path or rsync source
  --branch-name <name>                Optional restore branch name
  --force                             Replace existing target artifact paths; does not discard unrelated repo changes

Config:
  The helper loads projects/<name>/.snapshot.env when present.
  Supported variables:
    SNAPSHOT_GIT_REMOTE
    SNAPSHOT_RSYNC_TARGET
    SNAPSHOT_DEFAULT_INCLUDES
    SNAPSHOT_RESUME_COMMAND
EOF
}

need_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
  done
}

ensure_repo_root() {
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || error "Run this helper from inside a git clone."
  cd "$REPO_ROOT"
}

sanitize_component() {
  local raw="$1"
  local sanitized
  sanitized=$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9._-' '-')
  sanitized=${sanitized#-}
  sanitized=${sanitized%-}
  [[ -n "$sanitized" ]] || sanitized="snapshot"
  printf '%s\n' "$sanitized"
}

normalize_project_relative_path() {
  python3 - "$1" <<'PY'
import posixpath
import sys

value = sys.argv[1]
if not value:
    raise SystemExit(1)
if value.startswith("/"):
    raise SystemExit(1)
normalized = posixpath.normpath(value)
if normalized in ("", ".", ".."):
    raise SystemExit(1)
if normalized.startswith("../") or "/../" in f"/{normalized}/":
    raise SystemExit(1)
print(normalized)
PY
}

resolve_project() {
  local input="${1%/}"
  [[ -n "$input" ]] || error "--project is required"
  if [[ "$input" == projects/* ]]; then
    PROJECT_PATH="$input"
  else
    PROJECT_PATH="projects/$input"
  fi
  [[ -d "$REPO_ROOT/$PROJECT_PATH" ]] || error "Project directory not found: $PROJECT_PATH"
  PROJECT_NAME=$(basename "$PROJECT_PATH")
  PROJECT_ABS_PATH="$REPO_ROOT/$PROJECT_PATH"
  SNAPSHOT_CONFIG_PATH="$PROJECT_ABS_PATH/.snapshot.env"
}

load_snapshot_config() {
  SNAPSHOT_GIT_REMOTE="${SNAPSHOT_GIT_REMOTE:-}"
  SNAPSHOT_RSYNC_TARGET="${SNAPSHOT_RSYNC_TARGET:-}"
  SNAPSHOT_DEFAULT_INCLUDES="${SNAPSHOT_DEFAULT_INCLUDES:-}"
  SNAPSHOT_RESUME_COMMAND="${SNAPSHOT_RESUME_COMMAND:-}"
  if [[ -f "$SNAPSHOT_CONFIG_PATH" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$SNAPSHOT_CONFIG_PATH"
    set +a
  fi
}

collect_include_paths() {
  local -a requested=()
  local raw normalized repo_relative
  if [[ ${#CLI_INCLUDE_PATHS[@]} -gt 0 ]]; then
    requested=("${CLI_INCLUDE_PATHS[@]}")
  elif [[ -n "${SNAPSHOT_DEFAULT_INCLUDES:-}" ]]; then
    read -r -a requested <<<"$SNAPSHOT_DEFAULT_INCLUDES"
  else
    requested=("${DEFAULT_INCLUDE_PATHS[@]}")
  fi

  INCLUDED_PATHS=()
  for raw in "${requested[@]}"; do
    normalized=$(normalize_project_relative_path "$raw") || error "Include paths must stay inside the project: $raw"
    repo_relative="$PROJECT_PATH/$normalized"
    if [[ -e "$REPO_ROOT/$repo_relative" ]]; then
      INCLUDED_PATHS+=("$repo_relative")
    fi
  done

  [[ ${#INCLUDED_PATHS[@]} -gt 0 ]] || error "No included artifact paths exist for $PROJECT_PATH"
}

repo_status_porcelain() {
  git -C "$REPO_ROOT" status --porcelain --untracked-files=all
}

repo_is_dirty() {
  [[ -n "$(repo_status_porcelain)" ]]
}

current_branch_or_empty() {
  git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

utc_label_now() {
  date -u +%Y%m%dT%H%M%SZ
}

utc_timestamp_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

path_in_prefix() {
  local path="$1"
  local prefix="$2"
  [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

git_tracked_dirty_paths() {
  {
    git -C "$REPO_ROOT" diff --name-only
    git -C "$REPO_ROOT" diff --cached --name-only
    git -C "$REPO_ROOT" ls-files --others --exclude-standard
  } | awk 'NF' | sort -u
}

ensure_required_tools() {
  local -a tools=(git tar gzip sha256sum python3)
  [[ "$1" == "with-rsync" ]] && tools+=(rsync)
  need_cmd "${tools[@]}"
}

write_lines_file() {
  local output="$1"
  shift
  printf '%s\n' "$@" >"$output"
}

write_sha_sidecar() {
  local archive="$1"
  local sha_file="$2"
  local hash
  hash=$(sha256_file "$archive")
  printf '%s  %s\n' "$hash" "$(basename "$archive")" >"$sha_file"
  ARCHIVE_SHA256="$hash"
}

write_manifest_json() {
  local output="$1"
  local archive_sha="$2"
  local transfer_status="$3"
  local transfer_target="$4"
  local included_file="$5"
  MANIFEST_ARCHIVE_SHA256="$archive_sha" python3 - "$output" "$included_file" "$transfer_status" "$transfer_target" <<'PY'
import json
import os
import socket
import sys

output_path = sys.argv[1]
included_file = sys.argv[2]
transfer_status = sys.argv[3]
transfer_target = sys.argv[4]

with open(included_file, "r", encoding="utf-8") as fh:
    included_paths = [line.rstrip("\n") for line in fh if line.rstrip("\n")]

def env(name, default=""):
    return os.environ.get(name, default)

def env_bool(name):
    return env(name, "false").lower() == "true"

def env_nullable(name):
    value = env(name, "")
    return value if value != "" else None

manifest = {
    "schema_version": 1,
    "snapshot_id": env("MANIFEST_SNAPSHOT_ID"),
    "created_at_utc": env("MANIFEST_CREATED_AT_UTC"),
    "project_name": env("MANIFEST_PROJECT_NAME"),
    "project_path": env("MANIFEST_PROJECT_PATH"),
    "included_paths": included_paths,
    "note": env("MANIFEST_NOTE"),
    "resume_command": env("MANIFEST_RESUME_COMMAND"),
    "archive_filename": env("MANIFEST_ARCHIVE_FILENAME"),
    "archive_sha256": env_nullable("MANIFEST_ARCHIVE_SHA256"),
    "git": {
        "branch_before_save": env_nullable("MANIFEST_GIT_BRANCH_BEFORE_SAVE"),
        "head_before_save": env("MANIFEST_GIT_HEAD_BEFORE_SAVE"),
        "head_after_save": env("MANIFEST_GIT_HEAD_AFTER_SAVE"),
        "repo_dirty_before_save": env_bool("MANIFEST_GIT_REPO_DIRTY_BEFORE_SAVE"),
        "commit_created": env_bool("MANIFEST_GIT_COMMIT_CREATED"),
        "commit_sha_created": env_nullable("MANIFEST_GIT_COMMIT_SHA_CREATED"),
        "push_requested": env_bool("MANIFEST_GIT_PUSH_REQUESTED"),
        "push_status": env("MANIFEST_GIT_PUSH_STATUS"),
        "push_remote": env("MANIFEST_GIT_PUSH_REMOTE"),
    },
    "repo_snapshot": {
        "diff_patch_included": env_bool("MANIFEST_REPO_DIFF_PATCH_INCLUDED"),
        "untracked_bundle_included": env_bool("MANIFEST_REPO_UNTRACKED_BUNDLE_INCLUDED"),
    },
    "transfer": {
        "rsync_target": transfer_target,
        "rsync_status": transfer_status,
    },
    "host": {
        "hostname": socket.gethostname(),
        "user": env("USER", ""),
    },
}

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PY
}

load_manifest_fields() {
  local manifest_path="$1"
  eval "$(
    python3 - "$manifest_path" <<'PY'
import json
import shlex
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

def emit(name, value):
    if value is None:
        value = ""
    print(f"{name}={shlex.quote(str(value))}")

emit("RESTORE_MANIFEST_SNAPSHOT_ID", data["snapshot_id"])
emit("RESTORE_MANIFEST_PROJECT_NAME", data["project_name"])
emit("RESTORE_MANIFEST_PROJECT_PATH", data["project_path"])
emit("RESTORE_MANIFEST_ARCHIVE_SHA256", data.get("archive_sha256") or "")
emit("RESTORE_MANIFEST_NOTE", data.get("note", ""))
emit("RESTORE_MANIFEST_RESUME_COMMAND", data.get("resume_command", ""))
emit("RESTORE_MANIFEST_HEAD_AFTER_SAVE", data["git"]["head_after_save"])
emit("RESTORE_MANIFEST_DIFF_INCLUDED", str(bool(data["repo_snapshot"]["diff_patch_included"])).lower())
emit("RESTORE_MANIFEST_UNTRACKED_INCLUDED", str(bool(data["repo_snapshot"]["untracked_bundle_included"])).lower())
PY
  )"
  mapfile -t RESTORE_INCLUDED_PATHS < <(
    python3 - "$manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

for item in data.get("included_paths", []):
    print(item)
PY
  )
}

find_internal_manifest_path() {
  tar -tzf "$1" | awk '/^\.save-restore\/[^/]+\/manifest\.json$/ { print; exit }'
}

determine_remote_source() {
  local source="$1"
  [[ "$source" == *:* && ! -e "$source" ]]
}

remote_sidecar_path() {
  local remote_archive="$1"
  local suffix="$2"
  printf '%s\n' "${remote_archive%.tar.gz}${suffix}"
}

choose_restore_branch_name() {
  local requested="$1"
  local default_base base candidate index
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  default_base="restore/${PROJECT_NAME}/${RESTORE_MANIFEST_SNAPSHOT_ID}"
  base="$default_base"
  candidate="$base"
  index=2
  while git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$candidate"; do
    candidate="${base}-${index}"
    index=$((index + 1))
  done
  printf '%s\n' "$candidate"
}

write_restore_commands_file() {
  local output="$1"
  {
    printf './isaac_vmctl.sh bootstrap\n'
    printf './isaac_vmctl.sh start isaacsim\n'
    printf './isaac_vmctl.sh start isaacsim --headless\n'
    if [[ -n "$RESUME_COMMAND" ]]; then
      printf '%s\n' "$RESUME_COMMAND"
    fi
  } >"$output"
}

save_snapshot() {
  local project_input=""
  local label=""
  local note=""
  local resume_command=""
  local rsync_target=""
  local git_commit_requested="false"
  local git_push_requested="false"
  local do_rsync="without-rsync"

  CLI_INCLUDE_PATHS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        project_input="${2:-}"
        shift 2
        ;;
      --label)
        label="${2:-}"
        shift 2
        ;;
      --include)
        CLI_INCLUDE_PATHS+=("${2:-}")
        shift 2
        ;;
      --note)
        note="${2:-}"
        shift 2
        ;;
      --resume-command)
        resume_command="${2:-}"
        shift 2
        ;;
      --git-commit)
        git_commit_requested="true"
        shift
        ;;
      --git-push)
        git_push_requested="true"
        shift
        ;;
      --rsync-target)
        rsync_target="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown save option: $1"
        ;;
    esac
  done

  ensure_repo_root
  resolve_project "$project_input"
  load_snapshot_config
  collect_include_paths

  if [[ -z "$resume_command" && -n "${SNAPSHOT_RESUME_COMMAND:-}" ]]; then
    resume_command="$SNAPSHOT_RESUME_COMMAND"
  fi
  if [[ -z "$rsync_target" && -n "${SNAPSHOT_RSYNC_TARGET:-}" ]]; then
    rsync_target="$SNAPSHOT_RSYNC_TARGET"
  fi
  [[ -n "$rsync_target" ]] && do_rsync="with-rsync"
  ensure_required_tools "$do_rsync"

  if [[ -z "$label" ]]; then
    label=$(utc_label_now)
  else
    label=$(sanitize_component "$label")
  fi

  local branch_before_save head_before_save head_after_save short_sha snapshot_id created_at_utc
  local repo_dirty_before_save="false"
  local commit_created="false"
  local commit_sha_created=""
  local push_status="skipped"
  local push_remote=""
  local diff_patch_included="false"
  local untracked_bundle_included="false"
  local transfer_status="skipped"
  local exit_code=0

  branch_before_save=$(current_branch_or_empty)
  head_before_save=$(git -C "$REPO_ROOT" rev-parse HEAD)
  head_after_save="$head_before_save"
  if repo_is_dirty; then
    repo_dirty_before_save="true"
  fi

  short_sha=$(git -C "$REPO_ROOT" rev-parse --short=7 "$head_after_save")
  snapshot_id="$(sanitize_component "$PROJECT_NAME")__${label}__${short_sha}"
  created_at_utc=$(utc_timestamp_now)

  local status_capture_dir
  status_capture_dir=$(mktemp -d)
  register_cleanup "$status_capture_dir"
  local included_paths_file="$status_capture_dir/included_paths.txt"
  printf '%s\n' "${INCLUDED_PATHS[@]}" >"$included_paths_file"

  local status_file="$status_capture_dir/git_status.txt"
  {
    printf 'branch_before_save=%s\n' "${branch_before_save:-DETACHED}"
    printf 'head_before_save=%s\n' "$head_before_save"
    printf 'repo_dirty_before_save=%s\n' "$repo_dirty_before_save"
    printf '\n[git status --short]\n'
    repo_status_porcelain || true
    printf '\n[git remote]\n'
    git -C "$REPO_ROOT" remote || true
  } >"$status_file"

  if [[ "$repo_dirty_before_save" == "true" && ( "$git_commit_requested" == "true" || "$git_push_requested" == "true" ) ]]; then
    info "Creating a repo-wide snapshot commit before archiving."
    git -C "$REPO_ROOT" add -A
    if git -C "$REPO_ROOT" commit -m "save(${PROJECT_NAME}): recorded snapshot ${snapshot_id}"; then
      commit_created="true"
      commit_sha_created=$(git -C "$REPO_ROOT" rev-parse HEAD)
      head_after_save="$commit_sha_created"
    else
      warn "Git commit failed; the snapshot will fall back to a working-tree patch."
      exit_code=1
      head_after_save=$(git -C "$REPO_ROOT" rev-parse HEAD)
    fi
  fi

  if [[ "$git_push_requested" == "true" ]]; then
    local upstream_ref has_upstream="false"
    upstream_ref=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [[ -n "$upstream_ref" ]]; then
      has_upstream="true"
      push_remote="${upstream_ref%%/*}"
    else
      push_remote="${SNAPSHOT_GIT_REMOTE:-origin}"
    fi

    if [[ -z "$branch_before_save" ]]; then
      warn "Git push requested from detached HEAD; skipping push."
      push_status="failed"
      exit_code=1
    else
      info "Pushing the current branch with existing git auth."
      if [[ "$has_upstream" == "true" ]]; then
        if git -C "$REPO_ROOT" push; then
          push_status="success"
        else
          warn "Git push failed; local snapshot files will still be created."
          push_status="failed"
          exit_code=1
        fi
      else
        if git -C "$REPO_ROOT" push "$push_remote" "HEAD:${branch_before_save}"; then
          push_status="success"
        else
          warn "Git push failed; local snapshot files will still be created."
          push_status="failed"
          exit_code=1
        fi
      fi
    fi
  fi

  local repo_dirty_after_git="false"
  if repo_is_dirty; then
    repo_dirty_after_git="true"
  fi

  local staging_dir
  staging_dir=$(mktemp -d)
  register_cleanup "$staging_dir"

  local internal_meta_dir="$staging_dir/.save-restore/$snapshot_id"
  mkdir -p "$internal_meta_dir"

  local include_path
  for include_path in "${INCLUDED_PATHS[@]}"; do
    mkdir -p "$staging_dir/$(dirname "$include_path")"
    cp -a "$REPO_ROOT/$include_path" "$staging_dir/$include_path"
  done

  cp "$status_file" "$internal_meta_dir/git_status.txt"

  if [[ "$repo_dirty_after_git" == "true" ]]; then
    info "Capturing repo-wide working tree fallback data."
    git -C "$REPO_ROOT" diff --binary HEAD >"$internal_meta_dir/repo_diff.patch"
    diff_patch_included="true"

    local untracked_list
    untracked_list=$(mktemp)
    register_cleanup "$untracked_list"
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -z >"$untracked_list"
    if [[ -s "$untracked_list" ]]; then
      tar -C "$REPO_ROOT" --null -T "$untracked_list" -czf "$internal_meta_dir/repo_untracked.tar.gz"
      untracked_bundle_included="true"
    fi
  fi

  local output_dir="$PROJECT_ABS_PATH/artifacts/snapshots"
  mkdir -p "$output_dir"

  local archive_path="$output_dir/${snapshot_id}.tar.gz"
  local manifest_path="$output_dir/${snapshot_id}.manifest.json"
  local sha_path="$output_dir/${snapshot_id}.sha256"

  RESUME_COMMAND="$resume_command"
  write_restore_commands_file "$internal_meta_dir/restore_commands.txt"

  MANIFEST_SNAPSHOT_ID="$snapshot_id"
  MANIFEST_CREATED_AT_UTC="$created_at_utc"
  MANIFEST_PROJECT_NAME="$PROJECT_NAME"
  MANIFEST_PROJECT_PATH="$PROJECT_PATH"
  MANIFEST_NOTE="$note"
  MANIFEST_RESUME_COMMAND="$resume_command"
  MANIFEST_ARCHIVE_FILENAME="$(basename "$archive_path")"
  MANIFEST_ARCHIVE_SHA256=""
  MANIFEST_GIT_BRANCH_BEFORE_SAVE="$branch_before_save"
  MANIFEST_GIT_HEAD_BEFORE_SAVE="$head_before_save"
  MANIFEST_GIT_HEAD_AFTER_SAVE="$head_after_save"
  MANIFEST_GIT_REPO_DIRTY_BEFORE_SAVE="$repo_dirty_before_save"
  MANIFEST_GIT_COMMIT_CREATED="$commit_created"
  MANIFEST_GIT_COMMIT_SHA_CREATED="$commit_sha_created"
  MANIFEST_GIT_PUSH_REQUESTED="$git_push_requested"
  MANIFEST_GIT_PUSH_STATUS="$push_status"
  MANIFEST_GIT_PUSH_REMOTE="$push_remote"
  MANIFEST_REPO_DIFF_PATCH_INCLUDED="$diff_patch_included"
  MANIFEST_REPO_UNTRACKED_BUNDLE_INCLUDED="$untracked_bundle_included"
  export \
    MANIFEST_SNAPSHOT_ID \
    MANIFEST_CREATED_AT_UTC \
    MANIFEST_PROJECT_NAME \
    MANIFEST_PROJECT_PATH \
    MANIFEST_NOTE \
    MANIFEST_RESUME_COMMAND \
    MANIFEST_ARCHIVE_FILENAME \
    MANIFEST_ARCHIVE_SHA256 \
    MANIFEST_GIT_BRANCH_BEFORE_SAVE \
    MANIFEST_GIT_HEAD_BEFORE_SAVE \
    MANIFEST_GIT_HEAD_AFTER_SAVE \
    MANIFEST_GIT_REPO_DIRTY_BEFORE_SAVE \
    MANIFEST_GIT_COMMIT_CREATED \
    MANIFEST_GIT_COMMIT_SHA_CREATED \
    MANIFEST_GIT_PUSH_REQUESTED \
    MANIFEST_GIT_PUSH_STATUS \
    MANIFEST_GIT_PUSH_REMOTE \
    MANIFEST_REPO_DIFF_PATCH_INCLUDED \
    MANIFEST_REPO_UNTRACKED_BUNDLE_INCLUDED

  local archive_manifest_status="skipped"
  if [[ -n "$rsync_target" ]]; then
    archive_manifest_status="pending"
  fi
  write_manifest_json "$internal_meta_dir/manifest.json" "" "$archive_manifest_status" "$rsync_target" "$included_paths_file"

  info "Creating local snapshot archive at ${archive_path#"$REPO_ROOT/"}."
  tar -C "$staging_dir" -czf "$archive_path" .
  write_sha_sidecar "$archive_path" "$sha_path"
  MANIFEST_ARCHIVE_SHA256="$ARCHIVE_SHA256"
  export MANIFEST_ARCHIVE_SHA256

  if [[ -n "$rsync_target" ]]; then
    transfer_status="failed"
    local archive_uploaded="false"
    local checksum_uploaded="false"
    info "Uploading snapshot artifacts to ${rsync_target}."
    if rsync -avz "$archive_path" "$rsync_target"; then
      archive_uploaded="true"
    else
      warn "Archive upload failed."
    fi
    if [[ "$archive_uploaded" == "true" ]]; then
      if rsync -avz "$sha_path" "$rsync_target"; then
        checksum_uploaded="true"
      else
        warn "Checksum upload failed."
      fi
    fi
    if [[ "$archive_uploaded" == "true" && "$checksum_uploaded" == "true" ]]; then
      transfer_status="success"
    fi
  fi

  write_manifest_json "$manifest_path" "$ARCHIVE_SHA256" "$transfer_status" "$rsync_target" "$included_paths_file"

  if [[ "$transfer_status" == "success" ]]; then
    if ! rsync -avz "$manifest_path" "$rsync_target"; then
      warn "Manifest upload failed."
      transfer_status="failed"
      write_manifest_json "$manifest_path" "$ARCHIVE_SHA256" "$transfer_status" "$rsync_target" "$included_paths_file"
    fi
  fi

  if [[ -n "$rsync_target" && "$transfer_status" != "success" ]]; then
    exit_code=1
  fi

  info "Snapshot saved:"
  printf '  archive: %s\n' "${archive_path#"$REPO_ROOT/"}"
  printf '  manifest: %s\n' "${manifest_path#"$REPO_ROOT/"}"
  printf '  checksum: %s\n' "${sha_path#"$REPO_ROOT/"}"
  if [[ -n "$rsync_target" ]]; then
    printf '  rsync: %s\n' "$transfer_status"
  fi

  return "$exit_code"
}

restore_snapshot() {
  local project_input=""
  local snapshot_source=""
  local branch_name=""
  local force="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        project_input="${2:-}"
        shift 2
        ;;
      --snapshot)
        snapshot_source="${2:-}"
        shift 2
        ;;
      --branch-name)
        branch_name="${2:-}"
        shift 2
        ;;
      --force)
        force="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown restore option: $1"
        ;;
    esac
  done

  [[ -n "$snapshot_source" ]] || error "--snapshot is required"
  ensure_repo_root
  resolve_project "$project_input"
  load_snapshot_config

  local require_rsync="without-rsync"
  if determine_remote_source "$snapshot_source"; then
    require_rsync="with-rsync"
  fi
  ensure_required_tools "$require_rsync"

  local work_dir
  work_dir=$(mktemp -d)
  register_cleanup "$work_dir"

  local local_archive="$snapshot_source"
  local local_manifest=""
  local local_sha=""
  if determine_remote_source "$snapshot_source"; then
    info "Downloading snapshot archive via rsync."
    rsync -avz "$snapshot_source" "$work_dir/"
    local_archive="$work_dir/$(basename "$snapshot_source")"

    local remote_manifest
    remote_manifest=$(remote_sidecar_path "$snapshot_source" ".manifest.json")
    rsync -avz "$remote_manifest" "$work_dir/" >/dev/null 2>&1 || true

    local remote_sha
    remote_sha=$(remote_sidecar_path "$snapshot_source" ".sha256")
    rsync -avz "$remote_sha" "$work_dir/" >/dev/null 2>&1 || true
  fi

  [[ -f "$local_archive" ]] || error "Snapshot archive not found: $snapshot_source"

  local archive_basename
  archive_basename=$(basename "$local_archive")
  local archive_rootname="${archive_basename%.tar.gz}"
  if [[ -f "$(dirname "$local_archive")/${archive_rootname}.manifest.json" ]]; then
    local_manifest="$(dirname "$local_archive")/${archive_rootname}.manifest.json"
  fi
  if [[ -f "$(dirname "$local_archive")/${archive_rootname}.sha256" ]]; then
    local_sha="$(dirname "$local_archive")/${archive_rootname}.sha256"
  fi

  if [[ -z "$local_manifest" ]]; then
    local internal_manifest_path
    internal_manifest_path=$(find_internal_manifest_path "$local_archive")
    [[ -n "$internal_manifest_path" ]] || error "No manifest found alongside or inside the snapshot archive."
    local_manifest="$work_dir/internal-manifest.json"
    tar -xOf "$local_archive" "$internal_manifest_path" >"$local_manifest"
  fi

  load_manifest_fields "$local_manifest"
  [[ "$RESTORE_MANIFEST_PROJECT_PATH" == "$PROJECT_PATH" ]] || error "Snapshot project does not match --project (${RESTORE_MANIFEST_PROJECT_PATH} != ${PROJECT_PATH})."

  if [[ -n "$local_sha" ]]; then
    local expected_hash computed_hash
    expected_hash=$(awk '{print $1}' "$local_sha")
    computed_hash=$(sha256_file "$local_archive")
    [[ "$expected_hash" == "$computed_hash" ]] || error "Checksum mismatch for $(basename "$local_archive")"
  elif [[ -n "$RESTORE_MANIFEST_ARCHIVE_SHA256" ]]; then
    local computed_hash
    computed_hash=$(sha256_file "$local_archive")
    [[ "$RESTORE_MANIFEST_ARCHIVE_SHA256" == "$computed_hash" ]] || error "Checksum mismatch for $(basename "$local_archive")"
  else
    warn "No external checksum metadata was available; continuing without archive checksum verification."
  fi

  local dirty_paths_file="$work_dir/dirty_paths.txt"
  git_tracked_dirty_paths >"$dirty_paths_file"
  if [[ -s "$dirty_paths_file" ]]; then
    if [[ "$force" != "true" ]]; then
      error "Current repo has non-ignored local changes. Use --force only when the changes are limited to the target artifact paths."
    fi
    local dirty_path allowed
    while IFS= read -r dirty_path; do
      allowed="false"
      local include_path
      for include_path in "${RESTORE_INCLUDED_PATHS[@]}"; do
        if path_in_prefix "$dirty_path" "$include_path"; then
          allowed="true"
          break
        fi
      done
      [[ "$allowed" == "true" ]] || error "--force does not discard unrelated repo changes. Clean or stash $dirty_path before restore."
    done <"$dirty_paths_file"
  fi

  info "Fetching git history required for restore."
  git -C "$REPO_ROOT" fetch --all --prune
  git -C "$REPO_ROOT" cat-file -e "${RESTORE_MANIFEST_HEAD_AFTER_SAVE}^{commit}" 2>/dev/null || error "Saved commit is not available after fetch: ${RESTORE_MANIFEST_HEAD_AFTER_SAVE}"

  local final_branch_name
  final_branch_name=$(choose_restore_branch_name "$branch_name")
  git -C "$REPO_ROOT" switch -c "$final_branch_name" "$RESTORE_MANIFEST_HEAD_AFTER_SAVE"

  local include_path
  for include_path in "${RESTORE_INCLUDED_PATHS[@]}"; do
    if [[ -e "$REPO_ROOT/$include_path" ]]; then
      if [[ "$force" != "true" ]]; then
        error "Target path already exists: $include_path (use --force to replace it)"
      fi
      rm -rf "$REPO_ROOT/$include_path"
    fi
  done

  info "Extracting snapshot archive into the repo."
  tar -C "$REPO_ROOT" -xzf "$local_archive"

  local restore_meta_dir="$REPO_ROOT/.save-restore/$RESTORE_MANIFEST_SNAPSHOT_ID"
  local patch_path="$restore_meta_dir/repo_diff.patch"
  if [[ -f "$patch_path" ]]; then
    info "Reapplying repo diff patch."
    if git -C "$REPO_ROOT" apply --check "$patch_path"; then
      git -C "$REPO_ROOT" apply --binary "$patch_path"
    else
      error "Saved repo patch does not apply cleanly. Inspect $patch_path manually."
    fi
  fi

  local untracked_bundle_path="$restore_meta_dir/repo_untracked.tar.gz"
  if [[ -f "$untracked_bundle_path" ]]; then
    info "Restoring saved untracked files."
    tar -C "$REPO_ROOT" -xzf "$untracked_bundle_path"
  fi

  info "Restore complete."
  printf '  project: %s\n' "$PROJECT_PATH"
  printf '  branch: %s\n' "$final_branch_name"
  printf '  commit: %s\n' "$RESTORE_MANIFEST_HEAD_AFTER_SAVE"
  printf '  artifacts:\n'
  for include_path in "${RESTORE_INCLUDED_PATHS[@]}"; do
    printf '    - %s\n' "$include_path"
  done
  printf '  next:\n'
  printf '    ./isaac_vmctl.sh bootstrap\n'
  printf '    ./isaac_vmctl.sh start isaacsim\n'
  printf '    ./isaac_vmctl.sh start isaacsim --headless\n'
  if [[ -n "$RESTORE_MANIFEST_RESUME_COMMAND" ]]; then
    printf '    %s\n' "$RESTORE_MANIFEST_RESUME_COMMAND"
  fi
}

main() {
  local subcommand="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$subcommand" in
    save)
      save_snapshot "$@"
      ;;
    restore)
      restore_snapshot "$@"
      ;;
    help|-h|--help|"")
      usage
      ;;
    *)
      error "Unknown subcommand: $subcommand"
      ;;
  esac
}

main "$@"
