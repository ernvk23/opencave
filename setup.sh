#!/usr/bin/env bash
set -euo pipefail

CALL_DIR=$PWD
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
cd "$SCRIPT_DIR"

ENV_FILE=$SCRIPT_DIR/.env
IMAGE=localhost/opencave:latest
CLI=$HOME/.local/bin/opencave

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
  if [ "${1:-}" = setup ]; then
    printf '%s\n\n' 'Setup: ./setup.sh [--no-import-auth]'
  fi
  cat <<'HELP'
opencave                    Open a TUI in the current folder
opencave DIR                Open a TUI in DIR
opencave shell              Open Bash with shared tools and config
opencave help               Show this help

opencave serve [DIR]        Start a server for DIR (default: current folder)
opencave serve --openchamber
opencave serve-stop         Stop the server
opencave serve-restart      Restart the last served folder
opencave serve-status       Show server status
opencave serve-logs [openchamber]
                            Follow OpenCode logs (or the UI logs)
opencave creds              Show saved server URLs and passwords

opencave import-auth        Import saved credentials from host OpenCode
opencave import-skills [DIR] Copy global skills and preview conflicts
opencave update              Update versions and rebuild the image
opencave update --no-cache   Also force an Alpine package refresh
opencave version            Show the installed image's OpenCode version
opencave uninstall [--yes]
HELP
}

show_usage() {
  if [ "${0##*/}" = opencave ]; then
    usage
  else
    usage setup
  fi
}

absolute_path() {
  local path resolved
  case "$1" in
    '~') path=$HOME ;;
    '~/'*) path=$HOME/${1#\~/} ;;
    /*) path=$1 ;;
    *) path=${2:-$CALL_DIR}/$1 ;;
  esac
  IFS= read -r -d '' resolved < <(realpath -zm -- "$path") || die "could not resolve path: $path"
  case "$resolved" in
    *:*|*$'\n'*|*$'\r'*) die "mount paths cannot contain colons or line breaks: $path" ;;
  esac
  printf '%s\n' "$resolved"
}

contains_path() {
  [[ "$2" == "$1" || "$2" == "${1%/}/"* ]]
}

paths_overlap() {
  contains_path "$1" "$2" || contains_path "$2" "$1"
}

is_home_subdirectory() {
  [[ "$HOME_DIR" != / && "$1" == "$HOME_DIR/"* ]]
}

require_mount_paths() {
  local path resolved
  for path in "$@"; do
    resolved=$(absolute_path "$path")
    is_home_subdirectory "$resolved" ||
      die "refusing to mount $path: it must resolve to a directory below $HOME_DIR"
  done
}

require_data_mounts() {
  require_mount_paths "$DATA" "$DATA"/{share,state,bin,cache,config,agents}
}

require_project_mount() {
  require_mount_paths "$1"
  ! paths_overlap "$1" "$DATA" || die "project folder must not overlap OpenCave's data: $1"
  ! paths_overlap "$1" "$SCRIPT_DIR" || die "project folder must not overlap OpenCave's checkout: $1"
}

load_config() {
  WORKSPACE=
  DATA=${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data
  PORT=4096
  BIND_ADDR=127.0.0.1
  OPENCODE_SERVER_PASSWORD=
  OPENCHAMBER=no
  OPENCODE_TAG=2.3.2
  OPENCHAMBER_VERSION=2.7.2
  OPENCHAMBER_PORT=3000
  OPENCHAMBER_UI_PASSWORD=
  [ -f "$ENV_FILE" ] || return 0

  local key value
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      WORKSPACE|DATA|PORT|BIND_ADDR|OPENCODE_SERVER_PASSWORD|OPENCHAMBER|OPENCODE_TAG|OPENCHAMBER_VERSION|OPENCHAMBER_PORT|OPENCHAMBER_UI_PASSWORD)
        value=${value%$'\r'}
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$ENV_FILE"
}

write_config() {
  local tmp
  tmp=$(mktemp "$SCRIPT_DIR/.env.XXXXXX")
  printf '%s\n' \
    "WORKSPACE=$WORKSPACE" "DATA=$DATA" "PORT=$PORT" "BIND_ADDR=$BIND_ADDR" \
    "OPENCODE_SERVER_PASSWORD=$OPENCODE_SERVER_PASSWORD" "OPENCHAMBER=$OPENCHAMBER" \
    "OPENCODE_TAG=$OPENCODE_TAG" "OPENCHAMBER_VERSION=$OPENCHAMBER_VERSION" \
    "OPENCHAMBER_PORT=$OPENCHAMBER_PORT" "OPENCHAMBER_UI_PASSWORD=$OPENCHAMBER_UI_PASSWORD" > "$tmp"
  if [ -f "$ENV_FILE" ] && cmp -s "$tmp" "$ENV_FILE"; then
    rm -f -- "$tmp"
    chmod 600 "$ENV_FILE"
  else
    mv -f -- "$tmp" "$ENV_FILE"
  fi
}

require_install() {
  [ -f "$ENV_FILE" ] || die "run ./setup.sh first"
}

compose() (
  WORKSPACE_NAME=${WORKSPACE##*/}
  WORKSPACE_NAME=${WORKSPACE_NAME:-workspace}
  export WORKSPACE WORKSPACE_NAME WORKSPACE_MOUNT_MODE DATA PORT BIND_ADDR OPENCODE_SERVER_PASSWORD
  export OPENCHAMBER_VERSION OPENCHAMBER_PORT OPENCHAMBER_UI_PASSWORD
  # Use the same literal values as on-demand mode, regardless of provider.
  podman compose -f compose.yaml --env-file /dev/null "$@"
)

server_url() {
  local address=$BIND_ADDR
  case "$address" in
    0.0.0.0) address=127.0.0.1 ;;
    ::|'[::]') address='[::1]' ;;
    \[*\]) ;;
    *:*) address="[$address]" ;;
  esac
  printf 'http://%s:%s/\n' "$address" "$PORT"
}

wait_for_http() {
  local url access status deadline
  url=$(server_url)
  access=$(printf 'opencode:%s' "$OPENCODE_SERVER_PASSWORD" | base64 -w0)
  deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if status=$(printf 'Authorization: Basic %s\n' "$access" |
      curl --disable --noproxy '*' --silent --max-time 1 --header @- \
        --output /dev/null --write-out '%{http_code}' "${url}api/info"); then
      case "$status" in
        200) return 0 ;;
        401)
          printf 'OpenCode rejected authentication (HTTP 401). Check OPENCODE_SERVER_PASSWORD in %s.\n' "$ENV_FILE" >&2
          return 1 ;;
      esac
    fi
    sleep 1
  done
  printf 'OpenCode did not become ready on port %s.\n' "$PORT" >&2
  return 1
}

print_status() {
  local show_passwords=no
  if [ "${1:-}" = passwords ] && [ -t 1 ]; then show_passwords=yes; fi
  printf 'OpenCode: %s (user: opencode)\n' "$(server_url)"
  if [ "$show_passwords" = yes ]; then printf '  Password: %s\n' "$OPENCODE_SERVER_PASSWORD"; fi
  if [ "$OPENCHAMBER" = yes ] && openchamber_running; then
    printf 'OpenChamber: http://127.0.0.1:%s/\n' "$OPENCHAMBER_PORT"
    if [ "$show_passwords" = yes ]; then printf '  Password: %s\n' "$OPENCHAMBER_UI_PASSWORD"; fi
  else
    printf 'OpenChamber: off\n'
  fi
  if [ "$show_passwords" = no ]; then printf 'Show passwords: opencave creds\n'; fi
}

require_rootless_podman() {
  local info rootless remote uid_maps gid_maps
  info=$(podman info --format '{{.Host.Security.Rootless}} {{.Host.ServiceIsRemote}} {{len .Host.IDMappings.UIDMap}} {{len .Host.IDMappings.GIDMap}}') ||
    die "Podman is not working; run 'podman info' as your regular user and see the README"
  read -r rootless remote uid_maps gid_maps <<< "$info"
  [ "$rootless" = true ] && [ "$remote" = false ] || die "OpenCave requires local, rootless Podman"
  [ "$uid_maps" -gt 1 ] && [ "$gid_maps" -gt 1 ] ||
    die "configure subordinate UID and GID ranges for your account; see the README"
}

require_compose() {
  # The Docker Compose provider uses the Podman user socket.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user start podman.socket >/dev/null 2>&1 || true
  fi
  compose --profile openchamber config >/dev/null ||
    die "serve needs a compatible Compose provider (podman-compose 1.3+ or Docker Compose v2+); see the README"
}

server_running() {
  [ -n "$(podman ps -q --filter 'name=^opencave$' --filter status=running 2>/dev/null)" ]
}

openchamber_running() {
  [ -n "$(podman ps -q --filter 'name=^opencave-openchamber$' --filter status=running 2>/dev/null)" ]
}

server_containers() {
  [ -n "$(podman ps -aq --filter 'name=^opencave(-openchamber)?$' 2>/dev/null)" ]
}

stop_server() {
  local containers entry
  containers=$(podman ps -a --filter 'name=^opencave(-openchamber)?$' \
    --format '{{.ID}} {{.Label "com.docker.compose.project.working_dir"}}') ||
    die "could not check for OpenCave containers"
  [ -n "$containers" ] || return 0
  while IFS= read -r entry; do
    [ "${entry#* }" = "$SCRIPT_DIR" ] ||
      die "container ${entry%% *} does not belong to this OpenCave checkout"
  done <<< "$containers"
  [ -n "$WORKSPACE" ] || die "server workspace is missing from $ENV_FILE"
  compose --profile openchamber down ||
    die "could not stop the OpenCave server; check the Compose provider and retry"
}

start_server() {
  local WORKSPACE_MOUNT_MODE
  command -v curl >/dev/null || die "install curl first"
  require_data_mounts
  require_project_mount "$WORKSPACE"
  [ -d "$DATA/share" ] || die "OpenCave data is missing; run ./setup.sh"
  podman image exists "$IMAGE" || die "OpenCave image is missing; run ./setup.sh or opencave update"
  WORKSPACE_MOUNT_MODE=$(project_mount_mode "$WORKSPACE") || exit 1
  mkdir -p -- "$DATA/openchamber/config/chats" || die "could not create $DATA/openchamber/config/chats"
  if [ "$OPENCHAMBER" = yes ]; then
    require_mount_paths "$DATA/openchamber/config" "$DATA/openchamber/npm"
    mkdir -p -- "$DATA/openchamber/config" "$DATA/openchamber/npm" ||
      die "could not create the OpenChamber data directories"
  fi
  require_compose
  compose up -d --no-build opencave || die "could not start the OpenCode container"
  if ! wait_for_http; then
    compose --profile openchamber down >/dev/null 2>&1 || true
    return 1
  fi
  if [ "$OPENCHAMBER" = yes ]; then
    if [ -z "$OPENCHAMBER_UI_PASSWORD" ]; then
      warn "set an OpenChamber password with 'opencave serve'"
    elif ! compose --profile openchamber up -d --no-deps --no-build openchamber; then
      warn "OpenChamber could not start. OpenCode is available."
    fi
  fi
  printf 'OpenCave is running.\n'
  print_status "${1:-}"
}

image_version() {
  podman run --rm --entrypoint opencode "$IMAGE" --version
}

build_image() {
  local -a options=(--pull=always)
  if [ "${1:-}" = --no-cache ]; then options+=(--no-cache); fi
  podman build "${options[@]}" --build-arg "OPENCODE_TAG=$OPENCODE_TAG" -t "$IMAGE" . ||
    die "could not build OpenCode $OPENCODE_TAG; set a known-good OPENCODE_TAG in $ENV_FILE and retry"
  printf 'OpenCode image ready: %s.\n' "$OPENCODE_TAG"
}

import_auth() {
  require_mount_paths "$DATA" "$DATA/share"
  command -v opencode >/dev/null || { warn "host OpenCode is missing"; return 1; }
  if server_running &&
    opencode auth export | podman exec -i opencave opencode auth import; then
    return 0
  fi
  # Do not write shared data while a terminal session is using it.
  if (
    lock_data
    require_idle_data
    opencode auth export | podman run --rm -i --security-opt no-new-privileges:true \
      --entrypoint opencode -v "$DATA/share:/root/.local/share/opencode:z" \
      "$IMAGE" --standalone auth import 8<&-
  ); then
    return 0
  fi
  warn "credential import failed; use OpenCode to log in or run 'opencave import-auth'"
  return 1
}

ask_yes() {
  local label=$1 default=${2:-no} hint answer
  case "$default" in
    y|Y|yes|YES) hint='[Y/n]' ;;
    *) hint='[y/N]' ;;
  esac
  read -r -p "$label $hint: " answer || answer=""
  case "${answer:-$default}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

skill_paths() {
  local root=$1 depth=${2:-0} entry
  for entry in "$root"/*; do
    case "$entry" in */node_modules) continue ;; esac
    if [ -d "$entry" ]; then
      if [ -f "$entry/SKILL.md" ]; then
        printf '%s\0' "$entry"
      elif [ ! -L "$entry" ] && [ "$depth" -lt 5 ]; then
        skill_paths "$entry" "$((depth + 1))"
      fi
    elif [ "$depth" -eq 0 ] && [[ "$entry" == *.md ]] && { [ -f "$entry" ] || [ -L "$entry" ]; }; then
      printf '%s\0' "$entry"
    fi
  done
}

skill_copy_hint() {
  printf 'To import manually, copy the skill and its supporting files to %q on the host.\n' "$1"
  printf '%s\n' 'For a conflict, remove or replace the existing path shown first.'
  printf '%s\n' 'Inside OpenCave: /root/.config/opencode/skills. Use real files instead of host symlinks; set up any required tools or MCPs separately.'
}

import_skills() (
  local mode=$1
  shift
  case "${1:-}" in -h|--help) printf '%s\n' 'Usage: opencave import-skills [DIR]'; exit ;; esac
  [ "$#" -le 1 ] || die "usage: opencave import-skills [DIR]"
  require_install
  local root source target=$DATA/config/skills skill id old out unsafe answer
  local -a roots=("${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" "$HOME/.agents/skills")
  local -a sources=() skills=() pending=()
  local imported=0 skipped=0 overwrite=no has_conflicts=no
  local -A existing=() ambiguous=() seen=() destinations=() planned=()
  if [ "$#" -eq 1 ]; then
    [ -n "$1" ] || die "skills directory cannot be empty"
    roots=("$1")
  fi
  for root in "${roots[@]}"; do
    source=$(absolute_path "$root") || exit 1
    if [ ! -d "$source" ]; then
      [ "$#" -eq 0 ] || die "skills directory not found: $source"
      continue
    fi
    if contains_path "$DATA" "$source" || contains_path "$source" "$DATA"; then
      die "choose a skills directory that does not overlap OpenCave's data"
    fi
    sources+=("$source")
  done
  mapfile -d '' -t skills < <(for source in "${sources[@]}"; do skill_paths "$source"; done)
  if [ "${#skills[@]}" -eq 0 ]; then
    if [ "$mode" != setup ]; then printf 'No host skills found.\n'; fi
    exit 0
  fi
  if [ "$mode" = setup ] && ! ask_yes "Copy missing global skills from the host?" no; then exit 0; fi

  require_data_mounts
  [ -d "$DATA/share" ] && [ -d "$DATA/config" ] || die "OpenCave data is missing; run ./setup.sh"
  lock_data
  require_idle_data
  [ ! -L "$DATA/config" ] && [ ! -L "$target" ] &&
    { [ ! -e "$target" ] || [ -d "$target" ]; } || die "not a regular skills directory: $target"

  while IFS= read -r -d '' skill; do
    id=${skill##*/}
    [ -d "$skill" ] || id=${id%.md}
    old=${existing[$id]:-}
    if [[ "$skill" == "$target/"* && "$old" == "$target/"* ]]; then ambiguous["$id"]=yes; fi
    existing["$id"]=$skill
  done < <(skill_paths "$DATA/agents/skills"; skill_paths "$target")

  for skill in "${skills[@]}"; do
    id=${skill##*/}
    [ -d "$skill" ] || id=${id%.md}
    [ -z "${seen[$id]:-}" ] || continue
    unsafe=$(find "$skill" ! -type f ! -type d -print -quit) || die "could not inspect $skill"
    if [ -n "$unsafe" ]; then
      if [ "$mode" = manual ]; then printf 'Skipped %q: linked or special file %q\n' "$id" "$unsafe"; fi
      ((skipped += 1))
      continue
    fi
    seen["$id"]=$skill

    old=${existing[$id]:-}
    out=$target/${skill##*/}
    if [[ "$old" == "$target/"* && "${old##*/}" == "${skill##*/}" ]]; then out=$old; fi
    if [ "${ambiguous[$id]:-}" = yes ] || [ -n "${planned[$out]:-}" ] ||
      { [ "$out" != "$old" ] && { [ -e "$out" ] || [ -L "$out" ]; }; }; then
      if [ "$mode" = manual ]; then
        printf 'Skipped %q: destination %q is ambiguous or occupied (existing %q)\n' "$skill" "$out" "${old:--}"
      fi
      ((skipped += 1))
      continue
    fi
    if [ -n "$old" ]; then
      printf 'Conflict %q: incoming %q; existing %q\n' "$id" "$skill" "$old"
      if [ "$mode" = manual ]; then has_conflicts=yes; fi
    fi
    pending+=("$id")
    destinations["$id"]=$out
    planned["$out"]=$id
  done

  if [ "$has_conflicts" = yes ] && [ -t 0 ]; then
    read -r -p 'Overwrite conflicts? [y] overwrite, [n] keep existing and copy new, [s] skip [y/n/S]: ' answer || answer=
    case "${answer,,}" in
      y|yes) overwrite=yes ;;
      n|no) ;;
      *) printf 'Import skipped; no skills were copied.\n'; skill_copy_hint "$target"; exit 0 ;;
    esac
  fi

  umask 077
  for id in "${pending[@]}"; do
    skill=${seen[$id]}
    old=${existing[$id]:-}
    out=${destinations[$id]}
    if [ -n "$old" ] && [ "$overwrite" = no ]; then
      ((skipped += 1))
      continue
    fi

    mkdir -p -- "$target" || die "could not create $target"
    if [ -n "$old" ]; then
      rm -rf -- "$old" || die "could not remove $old"
    fi
    if [ -e "$out" ] || [ -L "$out" ]; then
      die "destination appeared while importing: $out"
    fi
    if ! cp -R -- "$skill" "$out"; then
      rm -rf -- "$out"
      die "could not copy $skill to $out"
    fi
    ((imported += 1))
  done
  printf 'Imported %s skill(s); skipped %s.\n' "$imported" "$skipped"
  if [ "$mode" = manual ] && [ "$skipped" -gt 0 ]; then skill_copy_hint "$target"; fi
)

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ] ||
    die "invalid port: $1"
}

port_busy() {
  local port=$1
  command -v ss >/dev/null || return 1
  [ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null)" ] || return 1
  ! podman port opencave 4096/tcp 2>/dev/null | grep -E ":$port\$" >/dev/null
}

password() {
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

prepare_data() {
  local new=no config=$DATA/config/opencode.json
  if [ ! -d "$DATA" ] || [ -z "$(find "$DATA" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    new=yes
  elif [ "$first_install" = yes ] &&
    { [ ! -f "$DATA/.opencave-owner" ] || [ "$(< "$DATA/.opencave-owner")" != "$SCRIPT_DIR" ]; }; then
    die "DATA is nonempty and is not owned by this install: $DATA"
  fi
  if [ "$new" = yes ]; then
    mkdir -p -m 700 -- "$DATA"
    chmod 700 "$DATA"
    printf '%s\n' "$SCRIPT_DIR" > "$DATA/.opencave-owner"
  fi
  mkdir -p -- "$DATA"/{share,state,bin,cache,config,agents}
  if [ ! -L "$config" ] && [ ! -e "$config" ]; then
    printf '%s\n' '{ "$schema": "https://opencode.ai/config.json" }' > "$config"
  fi
}

lock_data() {
  if [ -d "$DATA/share" ]; then
    exec 8< "$DATA/share" || die "could not open $DATA/share to lock it"
    flock -x -w "${1:-0}" 8 || die "OpenCave data is in use. Close any OpenCave sessions and retry."
  fi
}

require_idle_data() {
  local containers container details
  local -a sessions=()
  # Containers started by older versions did not take the shared lock.
  containers=$(podman ps --all --filter status=running --filter status=paused \
    --filter volume=/root/.local/share/opencode --format '{{.ID}}') ||
    die "could not check whether OpenCave data is in use"
  for container in $containers; do
    details=$(podman container inspect --format '{{.ImageName}}{{range .Mounts}}{{printf "\n%s:%s" .Source .Destination}}{{end}}' "$container") ||
      die "could not verify whether container $container uses DATA"
    if ! grep -Fxq -- "$DATA/share:/root/.local/share/opencode" <<< "$details"; then
      continue
    fi
    if [ "${1:-}" = stop ] && [ "${details%%$'\n'*}" = "$IMAGE" ] &&
      grep -Fxq -- "$DATA/config:/root/.config/opencode" <<< "$details"; then
      sessions+=("$container")
    else
      die "OpenCave data is in use by container $container. Close it and retry."
    fi
  done
  if [ "${#sessions[@]}" -gt 0 ]; then
    printf 'Closing OpenCave sessions.\n'
    podman rm --force --ignore --time 10 "${sessions[@]}" >/dev/null
  fi
}

podman_selinux() {
  podman info --format '{{and .Host.Security.SELinuxEnabled (not .Host.ServiceIsRemote)}}' 2>/dev/null
}

record_labeled_project() (
  local identity key ledger=$DATA/.selinux-default-projects
  identity=$(stat -Lc '%d:%i' -- "$1") || exit 1
  umask 077
  [ ! -L "$ledger" ] && { [ ! -e "$ledger" ] || [ -f "$ledger" ]; } || exit 1
  exec 7>> "$ledger" || exit 1
  flock -x 7 || exit 1
  key=$identity$'\t'$1
  if grep -Fxq -- "$key" "$ledger"; then exit 0; fi
  printf '%s\n' "$key" >&7
)

project_mountpoint() {
  local mounts mount
  mounts=$(findmnt -rno TARGET) || return 1
  while IFS= read -r mount; do
    printf -v mount '%b' "$mount"
    if contains_path "$1" "$mount"; then printf '%s\n' "$mount"; return 0; fi
  done <<< "$mounts"
}

project_mount_mode() {
  local enabled context diagnostics mount
  enabled=$(podman_selinux) || die "could not check Podman's SELinux status"
  if [ "$enabled" = false ]; then printf '%s\n' rw; return; fi
  [ "$enabled" = true ] || die "could not check Podman's SELinux status"
  context=$(stat -c %C -- "$1") || die "could not read the SELinux label of $1"
  case "$context" in
    *:object_r:container_file_t:s0) printf '%s\n' rw; return ;;
    *:object_r:container_file_t:*)
      die "refusing private or custom SELinux label on $1; use: restorecon -RFvx $(printf '%q' "$1")" ;;
  esac
  command -v restorecon >/dev/null || die "install policycoreutils to check SELinux project labels"
  diagnostics=$(restorecon -nFv -- "$1" 2>&1) || die "could not check SELinux labels on $1: $diagnostics"
  [ -z "$diagnostics" ] ||
    die "refusing non-default SELinux label on $1: $diagnostics
use: restorecon -RFvx $(printf '%q' "$1")"
  # Podman's relabel can cross mountpoints; our check and cleanup must not.
  mount=$(project_mountpoint "$1") || die "could not check mountpoints under $1"
  [ -z "$mount" ] || die "refusing to relabel $1: it includes mountpoint $mount"
  diagnostics=$(restorecon -nRFvxI -- "$1" 2>&1 | sed -n '1p') ||
    die "could not check SELinux labels under $1: $diagnostics"
  [ -z "$diagnostics" ] ||
    die "refusing non-default SELinux labels under $1: $diagnostics
use: restorecon -RFvx $(printf '%q' "$1")"
  # Podman can relabel the project even if the container fails to start.
  record_labeled_project "$1" || die "could not record SELinux cleanup path: $1"
  printf '%s\n' z
}

reset_project_labels() {
  local ledger=$DATA/.selinux-default-projects entry project identity ids mounts mount current busy diagnostics
  local -A recorded=()
  local -a containers=() active_mounts=()
  [ ! -L "$ledger" ] && [ -f "$ledger" ] || return 0
  while IFS= read -r entry; do
    project=${entry#*$'\t'}
    identity=${entry%%$'\t'*}
    if [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] && is_home_subdirectory "$project"; then
      recorded["$project"]=$identity
    fi
  done < "$ledger"
  [ "${#recorded[@]}" -gt 0 ] || return 0

  printf 'Project folders recorded for SELinux cleanup:\n'
  printf '  %q\n' "${!recorded[@]}"
  if ! command -v restorecon >/dev/null ||
    [ "$(podman_selinux)" != true ]; then
    warn "cannot restore labels here: restorecon and local SELinux-enabled Podman are required"
    return 0
  fi

  ids=$(podman ps -q --all --filter status=running --filter status=paused) ||
    { warn "could not check active Podman containers; restore labels manually"; return 0; }
  if [ -n "$ids" ]; then
    mapfile -t containers <<< "$ids"
    mounts=$(podman container inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "${containers[@]}") ||
      { warn "could not check active Podman mounts; restore labels manually"; return 0; }
    while IFS= read -r mount; do
      [[ "$mount" = /* ]] || continue
      current=$(realpath -e -- "$mount" 2>/dev/null) || current=$mount
      active_mounts+=("$current")
    done <<< "$mounts"
  fi

  for project in "${!recorded[@]}"; do
    if [ ! -d "$project" ] || [ "$(realpath -e -- "$project" 2>/dev/null)" != "$project" ] ||
      [ "$(stat -Lc '%d:%i' -- "$project" 2>/dev/null)" != "${recorded[$project]}" ] ||
      paths_overlap "$project" "$DATA" || paths_overlap "$project" "$SCRIPT_DIR"; then
      warn "skipped label restore for $project: folder changed, is missing, or overlaps OpenCave data or checkout"
      continue
    fi
    busy=no
    for mount in "${active_mounts[@]}"; do
      if paths_overlap "$project" "$mount"; then busy=yes; break; fi
    done
    if [ "$busy" = yes ]; then
      warn "skipped label restore for $project: still used by a Podman container"
      continue
    fi
    if ! mount=$(project_mountpoint "$project") || [ -n "$mount" ]; then
      warn "skipped label restore for $project: contains a mountpoint or could not verify mounts"
      continue
    fi
    # Leave any later non-:z labels alone.
    if ! diagnostics=$(
      { find "$project" -xdev -context '*:object_r:container_file_t:s0' -print0 |
        restorecon -F -0 -f -; } 2>&1
    ) || [ -n "$diagnostics" ]; then
      [ -z "$diagnostics" ] || printf '%s\n' "$diagnostics" >&2
      warn "could not confirm a full SELinux label restore on $project; check it manually"
    fi
  done
}

serve() {
  require_install
  local dir= openchamber= port=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --openchamber) openchamber=yes ;;
      --no-openchamber) openchamber=no ;;
      --port)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "--port requires a value"
        port=$2
        shift ;;
      --port=*)
        port=${1#*=}
        [ -n "$port" ] || die "--port requires a value" ;;
      -h|--help) usage; exit 0 ;;
      -*)
        die "unexpected argument: $1 (see opencave help)" ;;
      *)
        [ -z "$dir" ] || die "usage: opencave serve [DIR]"
        dir=$1 ;;
    esac
    shift
  done

  if server_running; then
    die "OpenCave is already serving. Use 'opencave serve-stop' or 'opencave serve-restart'."
  fi
  stop_server

  dir=$(absolute_path "${dir:-$CALL_DIR}") || exit 1
  [ -d "$dir" ] || die "not a directory: $dir"
  require_project_mount "$dir"
  require_data_mounts
  WORKSPACE=$dir
  PORT=${port:-$PORT}
  validate_port "$PORT"

  if [ -n "$openchamber" ]; then
    OPENCHAMBER=$openchamber
  elif [ -t 0 ]; then
    if ask_yes "Start the OpenChamber web UI on 127.0.0.1:$OPENCHAMBER_PORT?" "$OPENCHAMBER"; then
      OPENCHAMBER=yes
    else
      OPENCHAMBER=no
    fi
  fi
  if [ "$OPENCHAMBER" = yes ]; then
    validate_port "$OPENCHAMBER_PORT"
    [ "$OPENCHAMBER_PORT" != "$PORT" ] || die "OpenCode and OpenChamber need different host ports"
    OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD:-$(password)}
  fi

  if port_busy "$PORT"; then
    die "port $PORT is already in use; pass --port to choose another"
  fi
  if [ "$OPENCHAMBER" = yes ] && port_busy "$OPENCHAMBER_PORT"; then
    die "port $OPENCHAMBER_PORT is already in use; set OPENCHAMBER_PORT in $ENV_FILE"
  fi
  write_config
  start_server passwords
}

serve_restart() {
  require_install
  [ "$#" -eq 0 ] || die "usage: opencave serve-restart"
  [ -n "$WORKSPACE" ] || die "no server has been configured; run 'opencave serve [DIR]' first"
  WORKSPACE=$(absolute_path "$WORKSPACE") || exit 1
  [ -d "$WORKSPACE" ] || die "server folder is missing: $WORKSPACE"
  require_project_mount "$WORKSPACE"
  require_data_mounts
  validate_port "$PORT"
  if [ "$OPENCHAMBER" = yes ]; then
    validate_port "$OPENCHAMBER_PORT"
    [ "$OPENCHAMBER_PORT" != "$PORT" ] || die "OpenCode and OpenChamber need different host ports"
    OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD:-$(password)}
  fi
  stop_server
  if port_busy "$PORT"; then
    die "port $PORT is already in use; check what is running and retry"
  fi
  if [ "$OPENCHAMBER" = yes ] && port_busy "$OPENCHAMBER_PORT"; then
    die "port $OPENCHAMBER_PORT is already in use; set OPENCHAMBER_PORT in $ENV_FILE"
  fi
  write_config
  start_server
}

serve_stop() {
  require_install
  [ "$#" -eq 0 ] || die "usage: opencave serve-stop"
  if ! server_containers; then
    printf 'OpenCave server is not running.\n'
    return 0
  fi
  stop_server
  printf 'OpenCave server stopped (data kept).\n'
}

serve_status() {
  require_install
  [ "$#" -eq 0 ] || die "usage: opencave serve-status"
  if server_running; then
    printf 'OpenCave server is running.\n'
    print_status
  else
    printf 'OpenCave server is not running.\n'
    printf 'Last folder: %s\n' "${WORKSPACE:-none}"
  fi
  podman ps -a --filter 'name=^opencave(-openchamber)?$' || true
}

serve_logs() {
  require_install
  [ "$#" -le 1 ] || die "usage: opencave serve-logs [opencode|openchamber]"
  case "${1:-}" in
    ''|opencode) exec podman logs -f opencave ;;
    openchamber) exec podman logs -f opencave-openchamber ;;
    -h|--help) printf '%s\n' 'Usage: opencave serve-logs [opencode|openchamber]'; exit 0 ;;
    *) die "usage: opencave serve-logs [opencode|openchamber]" ;;
  esac
}

resolve_versions() {
  local latest
  versions_changed=no

  latest=$(curl --disable -fsSL --max-time 15 \
    'https://api.github.com/repos/anomalyco/opencode/releases?per_page=100' 2>/dev/null |
    sed -n 's/.*"tag_name": *"v\(2\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' |
    sort -Vr | sed -n '1p') || latest=
  if [ -z "$latest" ]; then
    die "could not find an OpenCode v2 release; set a known-good OPENCODE_TAG in $ENV_FILE and retry"
  fi
  if [ "$latest" = "$OPENCODE_TAG" ]; then
    printf 'OpenCode: %s is up to date.\n' "$OPENCODE_TAG"
  elif [ "$(printf '%s\n%s\n' "$OPENCODE_TAG" "$latest" | sort -V | tail -n1)" != "$latest" ]; then
    printf 'OpenCode: keeping %s (remote %s is older).\n' "$OPENCODE_TAG" "$latest"
  else
    printf 'OpenCode: %s -> %s.\n' "$OPENCODE_TAG" "$latest"
    OPENCODE_TAG=$latest
    versions_changed=yes
  fi

  latest=$(curl --disable -fsSL --max-time 15 \
    'https://registry.npmjs.org/@openchamber%2Fweb/latest' 2>/dev/null |
    sed -n 's/.*"version":"\([0-9][^"]*\)".*/\1/p') || latest=
  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "could not find an OpenChamber release; set a known-good OPENCHAMBER_VERSION in $ENV_FILE and retry"
  fi
  if [ "$latest" = "$OPENCHAMBER_VERSION" ]; then
    printf 'OpenChamber: %s is up to date.\n' "$OPENCHAMBER_VERSION"
  elif [ "$(printf '%s\n%s\n' "$OPENCHAMBER_VERSION" "$latest" | sort -V | tail -n1)" != "$latest" ]; then
    printf 'OpenChamber: keeping %s (remote %s is older).\n' "$OPENCHAMBER_VERSION" "$latest"
  else
    printf 'OpenChamber: %s -> %s.\n' "$OPENCHAMBER_VERSION" "$latest"
    OPENCHAMBER_VERSION=$latest
    versions_changed=yes
  fi
}

update_command() {
  local build_flag=$1 was_running=no ui_running=no current_image= built_image=
  if server_running; then was_running=yes; fi
  if [ "$OPENCHAMBER" = yes ] && openchamber_running; then ui_running=yes; fi
  if [ "$was_running" = yes ]; then
    [ -n "$WORKSPACE" ] || die "a server is running but its folder is unknown; use 'opencave serve-stop' and serve again"
    WORKSPACE=$(absolute_path "$WORKSPACE") || exit 1
    [ -d "$WORKSPACE" ] || die "server folder is missing: $WORKSPACE"
    require_project_mount "$WORKSPACE"
    require_data_mounts
    validate_port "$PORT"
    if [ "$OPENCHAMBER" = yes ]; then
      validate_port "$OPENCHAMBER_PORT"
      [ "$OPENCHAMBER_PORT" != "$PORT" ] || die "OpenCode and OpenChamber need different host ports"
      OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD:-$(password)}
      write_config
    fi
  fi

  resolve_versions
  build_image "$build_flag"
  if [ "$versions_changed" = yes ]; then
    write_config
    printf 'Saved the new versions in %s.\n' "$ENV_FILE"
  fi

  if [ "$was_running" = yes ]; then
    current_image=$(podman container inspect --format '{{.Image}}' opencave 2>/dev/null) || current_image=
    built_image=$(podman image inspect --format '{{.Id}}' "$IMAGE")
    if [ "${current_image#sha256:}" != "${built_image#sha256:}" ] ||
      [ "$versions_changed" = yes ]; then
      stop_server
      if [ "$ui_running" = no ]; then OPENCHAMBER=no; fi
      start_server
    fi
  fi
}

uninstall() {
  local delete_data=no
  [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ] ||
    die "this is not the installed checkout; run 'opencave uninstall'"
  [ -f "$ENV_FILE" ] || die "settings are missing: $ENV_FILE; run ./setup.sh here and retry"

  printf 'OpenCave will remove the server, CLI, and .env.\n'
  if [ -f "$DATA/.opencave-owner" ] && [ "$(< "$DATA/.opencave-owner")" = "$SCRIPT_DIR" ] &&
    ! contains_path "$DATA" "$WORKSPACE" && ! contains_path "$DATA" "$SCRIPT_DIR" &&
    ! contains_path "$DATA" "$(realpath -m -- "$HOME")"; then
    delete_data=yes
    printf 'Data to remove: %s\n' "$DATA"
  else
    printf 'Data kept: %s (shared or unmarked)\n' "$DATA"
  fi
  printf 'Kept: project folders and their files, image, checkout.\n'
  if [ "$yes_flag" = no ]; then
    [ -t 0 ] && ask_yes "Uninstall OpenCave?" no || die "cancelled (use --yes for unattended uninstall)"
  fi

  stop_server
  require_idle_data stop
  # An attached TUI or shell may need a moment to release its lock.
  lock_data 5
  require_idle_data
  reset_project_labels
  if [ "$delete_data" = yes ]; then
    rm -rf --one-file-system -- "$DATA"
  fi
  rm -f -- "$ENV_FILE" "$CLI"
  printf 'OpenCave uninstalled.\n'
}

open_session() {
  require_install
  local mode=$1 dir name mount_mode workdir=/root
  shift
  require_data_mounts
  local mounts=(
    -v "$DATA/share:/root/.local/share/opencode:z"
    -v "$DATA/state:/root/.local/state/opencode:z"
    -v "$DATA/bin:/root/.local/bin:z"
    -v "$DATA/cache:/root/.cache:z"
    -v "$DATA/config:/root/.config/opencode:z"
    -v "$DATA/agents:/root/.agents:z"
  )
  local args=("$IMAGE" --standalone)
  if [ "$mode" = shell ]; then
    [ "$#" -eq 0 ] || die "usage: opencave shell"
    args=(--entrypoint bash "$IMAGE")
  else
    [ "$#" -le 1 ] || die "usage: opencave [DIR]"
    dir=$(absolute_path "${1:-$CALL_DIR}")
    [ -d "$dir" ] || die "not a directory: $dir"
    require_project_mount "$dir"
    name=${dir##*/}
    workdir=/workspace/${name:-workspace}
  fi

  [ -d "$DATA/share" ] || die "OpenCave data is missing; run ./setup.sh"
  mkdir -p -- "$DATA/agents" || die "could not create $DATA/agents"
  # Keep the lock in this process until Podman exits.
  exec 8< "$DATA/share"
  flock -sn 8 || die "OpenCave data is being removed"
  [ -f "$ENV_FILE" ] || die "OpenCave was uninstalled"
  if [ "$mode" != shell ]; then
    mount_mode=$(project_mount_mode "$dir") || exit 1
    mounts=( -v "$dir:$workdir:$mount_mode" "${mounts[@]}" )
  fi
  podman run --rm -it --security-opt no-new-privileges:true \
    "${mounts[@]}" -w "$workdir" "${args[@]}" 8<&-
}

case "${1:-}" in
  help|-h|--help) show_usage; exit 0 ;;
esac
if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then
  die "run OpenCave on the host"
fi

cmd=${1:-}
case "$cmd" in
  shell|creds|serve|serve-stop|serve-restart|serve-status|serve-logs|update|version|import-auth|import-skills|uninstall)
    shift ;;
  '')
    if [ "${0##*/}" = opencave ]; then cmd=session; else cmd=setup; fi ;;
  -*) cmd=setup ;;
  *) cmd=session ;;
esac
[ "$EUID" -ne 0 ] || die "run OpenCave as your regular user"
if [ "$cmd" != creds ]; then
  command -v podman >/dev/null || die "install rootless Podman first; see the README"
  command -v flock >/dev/null || die "install flock (util-linux) first"
fi
HOME_DIR=$(absolute_path "$HOME")

# Serialize configuration and server changes.
case "$cmd" in
  setup|serve|serve-stop|serve-restart|update|uninstall|import-auth|import-skills)
    exec 9< "$SCRIPT_DIR"
    flock -x 9 ;;
esac

first_install=no
[ -f "$ENV_FILE" ] || first_install=yes
load_config
DATA=$(absolute_path "${DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data}" "$SCRIPT_DIR")

case "$cmd" in
  creds)
    [ "$#" -eq 0 ] || die "usage: opencave creds"
    require_install
    printf 'OpenCode\n'
    printf '  URL:      %s\n' "$(server_url)"
    printf '  Username: opencode\n'
    printf '  Password: %s\n' "${OPENCODE_SERVER_PASSWORD:-not set}"
    printf '\nOpenChamber\n'
    if [ "$OPENCHAMBER" = yes ]; then
      printf '  URL:      http://127.0.0.1:%s/\n' "$OPENCHAMBER_PORT"
      printf '  Password: %s\n' "${OPENCHAMBER_UI_PASSWORD:-not set}"
    else
      printf '  off\n'
    fi
    exit 0 ;;
  version)
    [ "$#" -eq 0 ] || die "usage: opencave version"
    require_install
    image_version
    exit ;;
  import-auth)
    [ "$#" -eq 0 ] || die "usage: opencave import-auth"
    require_install
    import_auth
    exit ;;
  import-skills) import_skills manual "$@"; exit ;;
  serve) serve "$@"; exit ;;
  serve-restart) serve_restart "$@"; exit ;;
  serve-stop) serve_stop "$@"; exit ;;
  serve-status) serve_status "$@"; exit ;;
  serve-logs) serve_logs "$@"; exit ;;
  session|shell) open_session "$cmd" "$@"; exit ;;
esac

yes_flag=no import_first=yes update_build_flag=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-import-auth) import_first=no ;;
    --yes) yes_flag=yes ;;
    --no-cache)
      [ "$cmd" = update ] || die "--no-cache is for update"
      update_build_flag=$1 ;;
    -h|--help) show_usage; exit 0 ;;
    *) die "unexpected argument: $1 (see opencave help)" ;;
  esac
  shift
done
if [ "$import_first" = no ] && [ "$cmd" != setup ]; then
  die "--no-import-auth is for setup"
fi
[ "$yes_flag" = no ] || [ "$cmd" = uninstall ] || die "--yes is for uninstall"

case "$cmd" in
  uninstall)
    uninstall
    exit ;;
  update)
    require_install
    command -v curl >/dev/null || die "install curl first"
    require_rootless_podman
    update_command "$update_build_flag"
    exit ;;
  setup) ;;
  *) die "unknown command: $cmd" ;;
esac

require_rootless_podman
require_data_mounts
if contains_path "$DATA" "$SCRIPT_DIR"; then
  die "DATA must not contain the checkout"
fi
if [ -e "$CLI" ] || [ -L "$CLI" ]; then
  [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ] ||
    die "$CLI belongs to another install or command"
fi

umask 077
if ! podman image exists "$IMAGE"; then build_image; fi
if [ -f "$ENV_FILE" ]; then stop_server; fi
prepare_data
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD:-$(password)}
if [ "$OPENCHAMBER" = yes ]; then
  OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD:-$(password)}
fi
if [ "$first_install" = yes ] && [ "$import_first" = yes ] && command -v opencode >/dev/null; then
  import_auth || true
fi
write_config
if [ "$first_install" = yes ] && [ -t 0 ]; then
  import_skills setup || warn "skill import did not finish; retry with 'opencave import-skills'"
fi
if [ ! -L "$CLI" ]; then
  mkdir -p -- "$(dirname -- "$CLI")"
  ln -s -- "$SCRIPT_DIR/setup.sh" "$CLI"
fi
printf 'OpenCave is ready. Open a TUI with opencave, or serve a folder with opencave serve [DIR].\n'
