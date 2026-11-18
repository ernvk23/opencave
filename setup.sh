#!/usr/bin/env bash
set -euo pipefail

CALL_DIR=$PWD
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
cd "$SCRIPT_DIR"

ENV_FILE=$SCRIPT_DIR/.env
IMAGE=localhost/opencave:latest
SERVICE=opencave.service
UNIT_DIR=$HOME/.config/systemd/user
UNIT_FILE=$UNIT_DIR/$SERVICE
CLI=$HOME/.local/bin/opencave

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
  if [ "${1:-}" = setup ]; then
    printf '%s\n\n' 'Setup: ./setup.sh [--workspace DIR] [--port N] [--no-import-auth]'
  fi
  cat <<'HELP'
opencave                    Open a TUI in the current folder
opencave DIR                Open a TUI in DIR
opencave shell              Open Bash with shared tools and config
opencave help               Show this help

opencave service-start      Set up or enable and start the user service
opencave service-stop       Stop and disable the service
opencave service-restart    Restart the service
opencave service-status     Show the unit and container status
opencave service-logs       Follow the service journal
opencave service-remove     Return to on-demand use and keep data

opencave creds              Show service URLs and passwords
opencave reconfigure        Change the mode or service settings (setup flags accepted)
opencave import-auth        Import saved credentials from host OpenCode
opencave update             Rebuild the image and refresh a running service
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

require_service_mounts() {
  require_data_mounts
  require_mount_paths "$WORKSPACE" "$DATA/openchamber/config/chats"
  if [ "$OPENCHAMBER" = yes ]; then
    require_mount_paths "$DATA/openchamber/config" "$DATA/openchamber/npm"
  fi
}

load_config() {
  WORKSPACE=$HOME/opencave
  DATA=${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data
  PORT=4096
  BIND_ADDR=127.0.0.1
  OPENCODE_SERVER_PASSWORD=
  OPENCHAMBER=no
  OPENCHAMBER_VERSION=2.7.2
  OPENCHAMBER_PORT=3000
  OPENCHAMBER_UI_PASSWORD=
  [ -f "$ENV_FILE" ] || return 0

  local key value
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      WORKSPACE|DATA|PORT|BIND_ADDR|OPENCODE_SERVER_PASSWORD|OPENCHAMBER|OPENCHAMBER_VERSION|OPENCHAMBER_PORT|OPENCHAMBER_UI_PASSWORD)
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
    "OPENCHAMBER_VERSION=$OPENCHAMBER_VERSION" "OPENCHAMBER_PORT=$OPENCHAMBER_PORT" \
    "OPENCHAMBER_UI_PASSWORD=$OPENCHAMBER_UI_PASSWORD" > "$tmp"
  if [ -f "$ENV_FILE" ] && cmp -s "$tmp" "$ENV_FILE"; then
    rm -f -- "$tmp"
    chmod 600 "$ENV_FILE"
  else
    mv -f -- "$tmp" "$ENV_FILE"
    config_changed=yes
  fi
}

require_install() {
  [ -f "$ENV_FILE" ] || die "run ./setup.sh first"
}

require_service() {
  require_install
  [ -f "$UNIT_FILE" ] || die "use 'opencave service-start' to install the service"
}

compose() (
  WORKSPACE_NAME=${WORKSPACE##*/}
  WORKSPACE_NAME=${WORKSPACE_NAME:-workspace}
  export WORKSPACE WORKSPACE_NAME DATA PORT BIND_ADDR OPENCODE_SERVER_PASSWORD
  export OPENCHAMBER_VERSION OPENCHAMBER_PORT OPENCHAMBER_UI_PASSWORD
  # Use the same literal values as on-demand mode, regardless of provider.
  podman compose -f compose.yaml --env-file /dev/null "$@"
)

service_url() {
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
  url=$(service_url)
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
  printf 'OpenCode did not become ready on port %s. See journalctl --user -u %s.\n' "$PORT" "$SERVICE" >&2
  return 1
}

print_access() {
  printf 'OpenCave is running.\n\n'
  printf 'OpenCode\n'
  printf '  URL:      %s\n' "$(service_url)"
  printf '  Username: opencode\n'
  if [ -t 1 ]; then
    printf '  Password: %s\n' "$OPENCODE_SERVER_PASSWORD"
  fi
  printf '\nOpenChamber\n'
  if [ "$OPENCHAMBER" = yes ]; then
    printf '  URL:      http://127.0.0.1:%s/\n' "$OPENCHAMBER_PORT"
    if [ -t 1 ] && [ -n "$OPENCHAMBER_UI_PASSWORD" ]; then
      printf '  Password: %s\n' "$OPENCHAMBER_UI_PASSWORD"
    fi
  else
    printf '  off\n'
  fi
  printf '\nPasswords: opencave creds\n'
  printf 'Config:    %s\n' "$ENV_FILE"
}

print_status() {
  printf 'OpenCode: %s (user: opencode)\n' "$(service_url)"
  if [ "$OPENCHAMBER" = yes ]; then
    printf 'OpenChamber: http://127.0.0.1:%s/\n' "$OPENCHAMBER_PORT"
  else
    printf 'OpenChamber: off\n'
  fi
  printf 'Passwords: opencave creds\n'
}

setup_unit() {
  local script=$SCRIPT_DIR/setup.sh tmp
  script=${script//\\/\\\\}
  script=${script//\"/\\\"}
  script=${script//%/%%}
  mkdir -p "$UNIT_DIR"
  tmp=$(mktemp "$UNIT_DIR/.opencave.XXXXXX")
  cat > "$tmp" <<UNIT
[Unit]
Description=OpenCave OpenCode server
Requires=podman.socket
After=podman.socket

[Service]
Type=exec
Delegate=yes
ExecStart=:/usr/bin/env bash "$script" --service-up
ExecStartPost=:/usr/bin/env bash "$script" --service-ready
ExecStopPost=:/usr/bin/env bash "$script" --service-down
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=90

[Install]
WantedBy=default.target
UNIT
  if [ -f "$UNIT_FILE" ] && cmp -s "$tmp" "$UNIT_FILE"; then
    rm -f -- "$tmp"
  else
    chmod 644 "$tmp"
    mv -f -- "$tmp" "$UNIT_FILE"
    systemctl --user daemon-reload
    unit_changed=yes
  fi
}

configure_linger() {
  local user
  user=$(id -un)
  if command -v loginctl >/dev/null &&
    [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" != yes ]; then
    loginctl --no-ask-password enable-linger "$user" >/dev/null 2>&1 ||
      warn "could not enable linger; the service can start at login"
  fi
}

require_service_deps() {
  command -v curl >/dev/null || die "curl is required for service mode"
  systemctl --user show-environment >/dev/null || die "a systemd user session is required"
  compose version >/dev/null 2>&1 || die "install a podman compose provider"
}

stop_service() {
  if ! systemctl --user disable --now "$SERVICE" >/dev/null 2>&1; then
    warn "could not stop/disable $SERVICE"
  fi
  cleanup_service
}

cleanup_service() {
  [ -f "$ENV_FILE" ] || return 0
  local containers
  containers=$(podman ps -aq --filter 'name=^opencave(-openchamber)?$' \
    --filter "label=com.docker.compose.project.working_dir=$SCRIPT_DIR")
  # A stopped, legacy, or missing unit may have left behind Compose containers.
  if [ -n "$containers" ]; then
    systemctl --user start podman.socket
    compose --profile openchamber down
  fi
}

remove_service() {
  if [ -f "$UNIT_FILE" ]; then
    stop_service
    rm -f -- "$UNIT_FILE"
    systemctl --user daemon-reload
  else
    cleanup_service
  fi
}

image_version() {
  podman run --rm --entrypoint opencode "$IMAGE" --version
}

build_image() {
  local pinned target current image_exists=no
  [ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] || die "OpenCave requires rootless Podman"
  if podman image exists "$IMAGE"; then image_exists=yes; fi
  pinned=$(sed -n 's/^ARG OPENCODE_TAG=//p' Containerfile)
  target=$(curl --disable -fsSL --max-time 15 \
    'https://api.github.com/repos/anomalyco/opencode/releases?per_page=100' 2>/dev/null |
    sed -n 's/.*"tag_name": *"v\(2\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' |
    sort -Vr | sed -n '1p') || target=
  if [ -z "$target" ]; then
    [ "$image_exists" = no ] || die "could not resolve OpenCode releases; keeping the installed image"
    target=$pinned
  fi

  if [ "$image_exists" = yes ]; then
    current=$(image_version | sed -nE 's/^(opencode[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+)$/\2/p') &&
      [ -n "$current" ] || die "could not determine the installed OpenCode version"
    if [ "$current" != "$target" ] &&
      [ "$(printf '%s\n%s\n' "$current" "$target" | sort -V | sed -n '1p')" = "$target" ]; then
      die "resolved tag $target is older than installed $current"
    fi
  fi

  podman build --pull --build-arg "OPENCODE_TAG=$target" -t "$IMAGE" .
}

update_openchamber() {
  openchamber_changed=no
  [ "$OPENCHAMBER" = yes ] || return 0
  local current=$OPENCHAMBER_VERSION latest
  latest=$(curl --disable -fsSL --max-time 15 \
    'https://registry.npmjs.org/@openchamber%2Fweb/latest' 2>/dev/null |
    sed -n 's/.*"version":"\([0-9][^"]*\)".*/\1/p') || latest=
  if [ -z "$latest" ]; then
    warn "could not resolve the OpenChamber version; keeping $current"
    return 0
  fi
  case "$latest" in
    *[!0-9.]*) warn "invalid OpenChamber version: $latest"; return 0 ;;
  esac
  if [ "$latest" = "$current" ] ||
    [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)" != "$latest" ]; then
    return 0
  fi
  OPENCHAMBER_VERSION=$latest
  write_config
  openchamber_changed=yes
  printf 'OpenChamber updated to %s.\n' "$latest"
}

import_auth() {
  require_mount_paths "$DATA" "$DATA/share"
  command -v opencode >/dev/null || { warn "host OpenCode is missing"; return 1; }
  if { [ "$service_active" = yes ] && opencode auth export | podman exec -i opencave opencode auth import; } ||
    opencode auth export | podman run --rm -i --entrypoint opencode \
      -v "$DATA/share:/root/.local/share/opencode:z" "$IMAGE" --standalone auth import; then
    return 0
  else
    warn "credential import failed; use OpenCode to log in or run 'opencave import-auth'"
    return 1
  fi
}

ask() {
  local answer
  read -r -p "$1 [$2]: " answer || answer=""
  printf '%s\n' "${answer:-$2}"
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
    exec 8< "$DATA/share"
    flock -x -w "${1:-0}" 8 || die "OpenCave data is in use. Close any OpenCave sessions and retry."
  fi
}

require_idle_data() {
  local containers container details
  local -a sessions=()
  # Containers started by older versions did not take the shared lock.
  containers=$(podman ps --all --filter status=running --filter status=paused \
    --filter volume=/root/.local/share/opencode --format '{{.ID}}')
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

uninstall() {
  [ -f "$ENV_FILE" ] || { printf 'OpenCave is already uninstalled.\n'; return 0; }
  local delete_data=no
  printf 'OpenCave will remove the service, CLI, and .env.\n'
  if [ -f "$DATA/.opencave-owner" ] && [ "$(< "$DATA/.opencave-owner")" = "$SCRIPT_DIR" ] &&
    ! contains_path "$DATA" "$WORKSPACE" && ! contains_path "$DATA" "$SCRIPT_DIR" &&
    ! contains_path "$DATA" "$(realpath -m -- "$HOME")"; then
    delete_data=yes
    printf 'Data to remove: %s\n' "$DATA"
  else
    printf 'Data kept: %s (shared or unmarked)\n' "$DATA"
  fi
  printf 'Kept: workspace, image, checkout.\n'
  if [ "$yes_flag" = no ]; then
    [ -t 0 ] && ask_yes "Uninstall OpenCave?" no || die "cancelled (use --yes for unattended uninstall)"
  fi

  remove_service
  require_idle_data stop
  # An attached TUI or shell may need a moment to release its lock.
  lock_data 5
  require_idle_data
  if [ "$delete_data" = yes ]; then
    rm -rf --one-file-system -- "$DATA"
  fi
  if [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ]; then
    rm -f -- "$CLI"
  fi
  rm -f -- "$ENV_FILE"
  if command -v restorecon >/dev/null; then
    if [ -d "$WORKSPACE" ]; then
      if is_home_subdirectory "$WORKSPACE"; then
        restorecon -R -F "$WORKSPACE" || warn "could not restore SELinux labels on $WORKSPACE"
      else
        warn "restore SELinux labels manually for this workspace: $WORKSPACE"
      fi
    fi
    printf '%s\n' \
      'Other project folders opened with OpenCave keep their SELinux labels.' \
      'If you want to reset a project folder to policy defaults, close any containers still using it' \
      'and run restorecon -R -F <project-folder>.'
  fi
  printf 'OpenCave uninstalled.\n'
}

open_session() {
  require_install
  local mode=$1 dir name workdir=/root
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
    require_mount_paths "$dir"
    name=${dir##*/}
    workdir=/workspace/${name:-workspace}
    mounts=( -v "$dir:$workdir:z" "${mounts[@]}" )
  fi

  [ -d "$DATA/share" ] || die "OpenCave data is missing; run ./setup.sh"
  mkdir -p -- "$DATA/agents" || die "could not create $DATA/agents"
  # Keep the lock in this process until Podman exits.
  exec 8< "$DATA/share"
  flock -sn 8 || die "OpenCave data is being removed"
  [ -f "$ENV_FILE" ] || die "OpenCave was uninstalled"
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
  shell|creds|--service-up|--service-ready|--service-down|service-start|service-stop|service-restart|service-status|service-logs|service-remove|update|version|import-auth|reconfigure|uninstall)
    shift ;;
  '')
    if [ "${0##*/}" = opencave ]; then cmd=session; else cmd=setup; fi ;;
  -*) cmd=setup ;;
  *) cmd=session ;;
esac
[ "$EUID" -ne 0 ] || die "run OpenCave as your regular user"
HOME_DIR=$(absolute_path "$HOME")

# Serialize configuration and service changes. The unit's callbacks run
# while systemctl is waiting, so they don't acquire this lock.
case "$cmd" in
  setup|service-start|service-stop|service-restart|update|reconfigure|service-remove|uninstall|import-auth)
    exec 9< "$SCRIPT_DIR"
    flock -x 9 ;;
esac
first_install=no
[ -f "$ENV_FILE" ] || first_install=yes
load_config
if [ "$cmd" != shell ] && [ "$cmd" != session ]; then
  WORKSPACE=$(absolute_path "${WORKSPACE:-$HOME/opencave}" "$SCRIPT_DIR")
fi
DATA=$(absolute_path "${DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data}" "$SCRIPT_DIR")

if [ "$cmd" = creds ]; then
  [ "$#" -eq 0 ] || die "usage: opencave creds"
  require_service
  printf 'OpenCode\n'
  printf '  URL:      %s\n' "$(service_url)"
  printf '  Username: opencode\n'
  printf '  Password: %s\n' "${OPENCODE_SERVER_PASSWORD:-not set}"
  printf '\nOpenChamber\n'
  if [ "$OPENCHAMBER" = yes ]; then
    printf '  URL:      http://127.0.0.1:%s/\n' "$OPENCHAMBER_PORT"
    printf '  Password: %s\n' "${OPENCHAMBER_UI_PASSWORD:-not set}"
  else
    printf '  off\n'
  fi
  exit 0
fi

command -v podman >/dev/null || die "install rootless Podman first"

case "$cmd" in
  session|shell) open_session "$cmd" "$@"; exit ;;
  --service-up)
    require_install
    require_service_mounts
    compose up --no-build --abort-on-container-exit opencave
    exit ;;
  --service-ready)
    require_install
    wait_for_http
    if [ "$OPENCHAMBER" = yes ]; then
      require_service_mounts
      if [ -z "$OPENCHAMBER_UI_PASSWORD" ]; then
        warn "set an OpenChamber password with 'opencave reconfigure'"
      elif ! compose --profile openchamber up -d --no-deps --no-build openchamber; then
        warn "OpenChamber could not start. OpenCode is available."
      fi
    fi
    exit ;;
  --service-down) compose --profile openchamber down; exit ;;
esac

workspace_flag= port_flag= yes_flag=no import_first=yes
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace|--port)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
      case "$1" in --workspace) workspace_flag=$2 ;; --port) port_flag=$2 ;; esac
      shift ;;
    --workspace=*) workspace_flag=${1#*=}; [ -n "$workspace_flag" ] || die "--workspace requires a value" ;;
    --port=*) port_flag=${1#*=}; [ -n "$port_flag" ] || die "--port requires a value" ;;
    --no-import-auth) import_first=no ;;
    --yes) yes_flag=yes ;;
    -h|--help) show_usage; exit 0 ;;
    *) die "unexpected argument: $1 (see opencave help)" ;;
  esac
  shift
done
if [ -n "$workspace_flag$port_flag" ] || [ "$import_first" = no ]; then
  case "$cmd" in setup|reconfigure|service-start) ;; *) die "setup flags are unavailable for $cmd" ;; esac
fi
[ "$yes_flag" = no ] || [ "$cmd" = uninstall ] || die "--yes is for uninstall"

service_active=no
if [ -f "$UNIT_FILE" ] && systemctl --user is-active --quiet "$SERVICE"; then
  service_active=yes
fi
unit_changed=no
case "$cmd" in
  service-status)
    require_service
    systemctl --user status "$SERVICE" --no-pager || true
    podman ps -a --filter 'name=^opencave(-openchamber)?$'
    exit ;;
  service-logs) require_service; exec journalctl --user -u "$SERVICE" -f --no-pager ;;
  service-stop) require_service; stop_service; printf 'OpenCave stopped (data kept). Start again with opencave service-start.\n'; exit ;;
  service-remove) remove_service; printf 'Service removed; using on-demand. Data kept.\n'; exit ;;
  uninstall) uninstall; exit ;;
  import-auth) require_install; import_auth; exit ;;
  version) require_install; image_version; exit ;;
  service-restart)
    require_service
    require_service_mounts
    require_service_deps
    setup_unit
    systemctl --user restart "$SERVICE"
    print_access
    exit ;;
  update)
    require_install
    if [ "$service_active" = yes ]; then require_service_mounts; fi
    build_image
    update_openchamber
    if [ "$service_active" = yes ]; then
      require_service_deps
      setup_unit
      current_image=$(podman container inspect --format '{{.Image}}' opencave 2>/dev/null) || current_image=
      built_image=$(podman image inspect --format '{{.Id}}' "$IMAGE")
      if [ "$unit_changed" = yes ] || [ "${current_image#sha256:}" != "${built_image#sha256:}" ]; then
        systemctl --user restart "$SERVICE"
      elif [ "$openchamber_changed" = yes ]; then
        compose --profile openchamber up -d --no-deps --no-build --force-recreate openchamber ||
          warn "OpenChamber could not be updated; run opencave service-restart"
      fi
    fi
    exit ;;
esac

mode=ondemand had_unit=no config_changed=no
if [ -f "$UNIT_FILE" ]; then mode=service; had_unit=yes; fi
if [ "$cmd" = service-start ] || [ -n "$workspace_flag$port_flag" ]; then mode=service; fi

if [ -t 0 ] && [ -z "$workspace_flag$port_flag" ] &&
  { [ "$first_install" = yes ] || [ "$cmd" = reconfigure ] ||
    { [ "$cmd" = service-start ] && [ ! -f "$UNIT_FILE" ]; }; }; then
  if [ "$cmd" != service-start ]; then
    default=no
    if [ "$mode" = service ]; then default=yes; fi
    if ask_yes "Run OpenCode as a background service on 127.0.0.1:$PORT?" "$default"; then
      mode=service
    else
      mode=ondemand
    fi
  fi
  if [ "$mode" = service ]; then
    WORKSPACE=$(ask "Workspace folder to mount" "$WORKSPACE")
    if port_busy "$PORT"; then PORT=$(ask "Port $PORT is in use; use host port" "$PORT"); fi
    if ask_yes "Add the OpenChamber web UI on 127.0.0.1:$OPENCHAMBER_PORT (separate password)?" "$OPENCHAMBER"; then
      OPENCHAMBER=yes
    else
      OPENCHAMBER=no
    fi
  fi
fi
WORKSPACE=$(absolute_path "${workspace_flag:-$WORKSPACE}")
PORT=${port_flag:-$PORT}

if [ "$mode" = service ]; then
  require_service_mounts
  require_service_deps
  validate_port "$PORT"
  if [ "$OPENCHAMBER" = yes ]; then
    validate_port "$OPENCHAMBER_PORT"
    [ "$OPENCHAMBER_PORT" != "$PORT" ] || die "OpenCode and OpenChamber need different host ports"
  fi
  if { [ "$first_install" = yes ] || [ "$cmd" = reconfigure ] || [ "$cmd" = service-start ]; } && port_busy "$PORT"; then
    die "port $PORT is already in use; pass --port to choose another"
  fi
else
  require_data_mounts
fi

if contains_path "$DATA" "$WORKSPACE" || contains_path "$DATA" "$SCRIPT_DIR"; then
  die "DATA must not contain the workspace or checkout"
fi
if [ -e "$CLI" ] || [ -L "$CLI" ]; then
  [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ] ||
    die "$CLI belongs to another install or command"
fi

umask 077
if ! podman image exists "$IMAGE"; then build_image; fi
prepare_data
if [ "$mode" = service ]; then
  mkdir -p -- "$WORKSPACE" "$DATA/openchamber/config/chats"
  if [ "$OPENCHAMBER" = yes ]; then mkdir -p -- "$DATA/openchamber/npm"; fi
fi
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD:-$(password)}
if [ "$OPENCHAMBER" = yes ]; then
  OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD:-$(password)}
fi
if [ "$first_install" = yes ] && [ "$import_first" = yes ] && command -v opencode >/dev/null; then
  import_auth || true
fi
write_config
if [ ! -L "$CLI" ]; then
  mkdir -p -- "$(dirname -- "$CLI")"
  ln -s -- "$SCRIPT_DIR/setup.sh" "$CLI"
fi

if [ "$mode" = ondemand ]; then
  remove_service
  printf 'OpenCave is ready (on-demand). Start with opencave or opencave shell.\n'
  exit
fi

setup_unit
if { [ "$cmd" = service-start ] || [ "$had_unit" = no ]; } &&
  ! systemctl --user is-enabled --quiet "$SERVICE"; then
  systemctl --user enable "$SERVICE" >/dev/null
  configure_linger
fi
if [ "$service_active" = yes ] && { [ "$config_changed" = yes ] || [ "$unit_changed" = yes ]; }; then
  systemctl --user restart "$SERVICE"
  print_access
elif [ "$cmd" = service-start ] || [ "$had_unit" = no ] ||
  { [ "$service_active" = no ] && systemctl --user is-enabled --quiet "$SERVICE"; }; then
  systemctl --user start "$SERVICE"
  if [ "$service_active" = yes ]; then wait_for_http; fi
  print_access
else
  printf 'OpenCave is already set up. Use opencave reconfigure to change settings.\n'
  print_status
fi
