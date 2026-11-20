#!/usr/bin/env bash
set -euo pipefail

CALL_DIR=$PWD
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
cd "$SCRIPT_DIR"

ENV_FILE=$SCRIPT_DIR/.env
BASE_IMAGES_FILE=$ENV_FILE.base-images
IMAGE=localhost/opencave:latest
BASE_IMAGE=ghcr.io/anomalyco/opencode
IMAGE_OWNER=io.opencave.checkout
CONTAINER_OWNER='{{.Label "io.opencave.checkout"}}'
CLI=$HOME/.local/bin/opencave
ROOTFS_PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROOTFS_OPTIONS=(--security-opt no-new-privileges:true --tmpfs /tmp:exec,nodev,nosuid)

diagnostic() {
  local level=$1 color=$2
  shift 2
  if [ -t 2 ]; then
    printf '\033[%sm%s:\033[0m %s\n' "$color" "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi >&2
}

die() { diagnostic error 31 "$@"; exit 1; }
warn() { diagnostic warning 33 "$@"; }

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
opencave update             Update OpenCode and OpenChamber versions
opencave update --system    Also upgrade Alpine packages
opencave reset              Start over and keep provider logins
opencave version            Show the installed OpenCode version
opencave uninstall [--yes] [--keep-labels]
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
  require_mount_paths "$DATA" "$ROOTFS"
  [ ! -L "$ROOTFS" ] || die "the shared filesystem must not be a symlink: $ROOTFS"
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
  fi
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

server_running() {
  local name=${1:-opencave}
  [ "$(podman ps --filter "name=^$name\$" --filter status=running \
    --format "$CONTAINER_OWNER" 2>/dev/null)" = "$SCRIPT_DIR" ]
}

openchamber_running() {
  server_running opencave-openchamber
}

server_containers() {
  [ -n "$(podman ps -aq --filter 'name=^opencave(-openchamber)?$' 2>/dev/null)" ]
}

stop_server() {
  local containers entry name id
  local -a ids=()
  containers=$(podman ps -a --filter 'name=^opencave(-openchamber)?$' \
    --format "{{.Names}} {{.ID}} $CONTAINER_OWNER") ||
    die "could not check for OpenCave containers"
  [ -n "$containers" ] || return 0
  while IFS= read -r entry; do
    name=${entry%% *}
    entry=${entry#* }
    id=${entry%% *}
    [ "${entry#* }" = "$SCRIPT_DIR" ] ||
      die "container $name does not belong to this OpenCave checkout"
    if [[ "$name" = *-openchamber ]]; then
      ids=("$id" "${ids[@]}")
    else
      ids+=("$id")
    fi
  done <<< "$containers"
  for id in "${ids[@]}"; do
    podman rm --force --ignore "$id" >/dev/null || die "could not stop container $id"
  done
}

start_server() (
  local mount_mode name=${WORKSPACE##*/} workdir bind=$BIND_ADDR
  case "$bind" in
    \[*\]) ;;
    *:*) bind="[$bind]" ;;
  esac
  local -a ports=(-p "$bind:$PORT:4096")
  export OPENCODE_SERVER_PASSWORD OPENCHAMBER_UI_PASSWORD
  command -v curl >/dev/null || die "install curl first"
  require_project_mount "$WORKSPACE"
  require_rootfs
  workdir=/workspace/${name:-workspace}
  mount_mode=$(project_mount_mode "$WORKSPACE") || exit 1
  if [ "$OPENCHAMBER" = yes ] && [ -n "$OPENCHAMBER_UI_PASSWORD" ]; then
    ports+=(-p "127.0.0.1:$OPENCHAMBER_PORT:3000")
  fi
  printf 'Starting OpenCode…\n'
  podman run -d --name opencave --restart unless-stopped \
    --label "$IMAGE_OWNER=$SCRIPT_DIR" \
    "${ROOTFS_OPTIONS[@]}" "${ports[@]}" --env "PATH=$ROOTFS_PATH" \
    --env OPENCODE_SERVER_PASSWORD \
    -v "$WORKSPACE:$workdir:$mount_mode" -w "$workdir" --rootfs "$ROOTFS" \
    opencode serve --hostname 0.0.0.0 --port 4096 8<&- 9<&- >/dev/null ||
    die "could not start OpenCode"
  if ! wait_for_http; then
    stop_server
    return 1
  fi
  if [ "$OPENCHAMBER" = yes ]; then
    if [ -z "$OPENCHAMBER_UI_PASSWORD" ]; then
      warn "set an OpenChamber password with 'opencave serve'"
    elif ! podman run -d --name opencave-openchamber --network container:opencave --restart unless-stopped \
      --label "$IMAGE_OWNER=$SCRIPT_DIR" \
      "${ROOTFS_OPTIONS[@]}" --env "PATH=$ROOTFS_PATH" \
      --env OPENCODE_HOST=http://127.0.0.1:4096 --env OPENCODE_SKIP_START=true \
      --env OPENCODE_SERVER_PASSWORD --env OPENCHAMBER_HOST=0.0.0.0 \
      --env OPENCHAMBER_UI_PASSWORD \
      -v "$WORKSPACE:$workdir:$mount_mode" -w "$workdir" --rootfs "$ROOTFS" \
      npx --yes "@openchamber/web@$OPENCHAMBER_VERSION" --foreground --port 3000 8<&- 9<&- >/dev/null; then
      warn "OpenChamber could not start. OpenCode is available."
    fi
  fi
  print_status passwords
)

image_version() {
  require_rootfs
  exec 8< "$DATA"
  flock -sn 8 || die "OpenCave is busy. Retry after the current maintenance command finishes."
  podman run --rm --network=none --label "$IMAGE_OWNER=$SCRIPT_DIR" \
    "${ROOTFS_OPTIONS[@]}" --rootfs "$ROOTFS" opencode --version 8<&- 9<&-
}

pull_opencode_image() {
  local base=$BASE_IMAGE:$OPENCODE_TAG before pulled
  before=$(podman image ls --all --quiet --no-trunc) || die "could not list local images"
  printf 'Pulling OpenCode %s…\n' "$OPENCODE_TAG"
  podman pull "$base" || die "could not pull $base"
  pulled=$(podman image inspect --format '{{.Id}}' "$base") ||
    die "could not identify the base image for $base"
  pulled=${pulled#sha256:}
  [[ "$pulled" =~ ^[a-f0-9]{64}$ ]] || die "could not identify the base image for $base"
  if ! grep -Fxq -e "$pulled" -e "sha256:$pulled" <<< "$before"; then
    (umask 077; printf '%s %s\n' "$pulled" "$base" >> "$BASE_IMAGES_FILE")
  fi
}

build_image() {
  pull_opencode_image
  printf 'Building the OpenCave image…\n'
  podman build --pull=never --force-rm --label "$IMAGE_OWNER=$SCRIPT_DIR" \
    --build-arg "OPENCODE_TAG=$OPENCODE_TAG" -t "$IMAGE" . ||
    die "could not build OpenCode $OPENCODE_TAG"
}

install_opencode() (
  local rootfs=$1 base=$BASE_IMAGE:$OPENCODE_TAG binary
  if ! podman image exists "$base"; then pull_opencode_image; fi
  binary=$(mktemp "$DATA/.opencode.XXXXXX")
  trap 'rm -f -- "$binary"' EXIT
  podman run --rm --network=none --entrypoint /bin/cat "$base" \
    /usr/local/bin/opencode 8<&- 9<&- > "$binary" ||
    die "could not extract OpenCode $OPENCODE_TAG"
  podman run --rm -i --network=none "${ROOTFS_OPTIONS[@]}" --rootfs "$rootfs" /bin/sh -ec '
    candidate=$(mktemp /usr/local/bin/.opencode.XXXXXX)
    trap '\''rm -f -- "$candidate"'\'' EXIT
    cat > "$candidate"
    chmod 755 "$candidate"
    version=$("$candidate" --version)
    version=${version##* }
    [ "${version#v}" = "$1" ]
    mv -fT -- "$candidate" /usr/local/bin/opencode
  ' install-opencode "$OPENCODE_TAG" 8<&- 9<&- < "$binary" ||
    die "could not install OpenCode $OPENCODE_TAG"
)

rootfs_opencode_version() {
  local version
  version=$(podman run --rm --network=none "${ROOTFS_OPTIONS[@]}" --rootfs "$1" \
    opencode --version 8<&- 9<&-) || return 1
  version=${version##* }
  printf '%s\n' "${version#v}"
}

remove_owned_image() {
  local id=$1 expected_tag=$2 keep_tag=$3 tags status
  if podman image exists "$id"; then
    tags=$(podman image inspect --format '{{join .RepoTags " "}}' "$id") || return 1
  else
    status=$?
    [ "$status" -eq 1 ]
    return
  fi
  if [ -n "$tags" ] && [ "$tags" != "$expected_tag" ]; then
    printf 'Keeping image %s because it has other tags.\n' "${id:0:12}"
    return 0
  fi
  [ -n "$keep_tag" ] && [ "$tags" = "$keep_tag" ] && return 0
  podman image rm "$id"
}

remove_owned_images() {
  local keep_image=${1:-} keep_base=${2:-} ids id tag pending=0
  ids=$(podman image ls --all --quiet --no-trunc --filter "label=$IMAGE_OWNER=$SCRIPT_DIR") ||
    return 1
  for id in $ids; do
    remove_owned_image "$id" "$IMAGE" "$keep_image" || pending=1
  done
  if [ -f "$BASE_IMAGES_FILE" ]; then
    while read -r id tag; do
      [[ "$id" =~ ^[a-f0-9]{64}$ && "$tag" == "$BASE_IMAGE":* ]] || continue
      remove_owned_image "$id" "$tag" "$keep_base" || pending=1
    done < "$BASE_IMAGES_FILE"
  fi
  return "$pending"
}

import_auth() {
  command -v opencode >/dev/null || { warn "host OpenCode is missing"; return 1; }
  require_rootfs
  printf 'Importing provider logins…\n'
  if server_running &&
    opencode auth export | podman exec -i opencave opencode auth import; then
    return 0
  fi
  # Do not write shared data while a terminal session is using it.
  if (
    lock_data
    require_idle_data
    opencode auth export | podman run --rm -i --network=none "${ROOTFS_OPTIONS[@]}" \
      --rootfs "$ROOTFS" opencode --standalone auth import 8<&- 9<&-
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
  local root source target=$ROOTFS/root/.config/opencode/skills skill id old out unsafe answer
  local agent_skills=$ROOTFS/root/.agents/skills
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
  require_rootfs
  lock_data
  require_idle_data
  require_unmounted_path "$target"
  require_unmounted_path "$agent_skills"
  [ ! -e "$target" ] || [ -d "$target" ] || die "not a regular skills directory: $target"

  while IFS= read -r -d '' skill; do
    id=${skill##*/}
    [ -d "$skill" ] || id=${id%.md}
    old=${existing[$id]:-}
    if [[ "$skill" == "$target/"* && "$old" == "$target/"* ]]; then ambiguous["$id"]=yes; fi
    existing["$id"]=$skill
  done < <(skill_paths "$agent_skills"; skill_paths "$target")

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
  local new=no
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
}

lock_data() {
  if [ -d "$DATA" ]; then
    exec 8< "$DATA" || die "could not open $DATA to lock it"
    flock -x -w "${1:-0}" 8 || die "Close any other OpenCave sessions and retry."
  fi
}

require_unmounted_path() {
  local path=$1 mount
  [ ! -L "$path" ] && [ "$(realpath -m -- "$path")" = "$path" ] ||
    die "path must not be a symlink: $path"
  mount=$(project_mountpoint "$path") || die "could not check mounts under $path"
  [ -z "$mount" ] || die "path includes mountpoint $mount"
}

require_owned_data() {
  [ ! -L "$DATA/.opencave-owner" ] && [ -f "$DATA/.opencave-owner" ] &&
    [ "$(< "$DATA/.opencave-owner")" = "$SCRIPT_DIR" ] ||
    die "this install does not own $DATA"
}

unpack_image() (
  local destination=$1 seed
  mkdir -p -- "$destination"
  seed=$(podman create --pull=never "$IMAGE" 8<&- 9<&-) ||
    die "OpenCave image is missing. Run ./setup.sh"
  trap 'podman rm --force --ignore "$seed" >/dev/null' EXIT
  podman export "$seed" 8<&- 9<&- |
    podman unshare tar -xpf - -C "$destination" 8<&- 9<&-
)

restore_rootfs() {
  if [ -d "$stage/old" ]; then
    if [ -d "$ROOTFS" ]; then mv -T -- "$ROOTFS" "$stage/failed" || return 1; fi
    mv -T -- "$stage/old" "$ROOTFS"
  fi
}

replace_rootfs() (
  local mode=$1 stage path version committed=no
  require_owned_data
  lock_data
  if [ "$mode" = init ] && [ -d "$ROOTFS" ]; then return 0; fi
  if server_containers; then die "run opencave serve-stop before replacing the shared filesystem"; fi
  require_idle_data
  require_unmounted_path "$ROOTFS"
  if [ ! -d "$ROOTFS" ]; then
    for path in "$DATA"/.rootfs.*/old; do
      [ -d "$path" ] || continue
      die "the previous filesystem is at $path. Move it back to $ROOTFS and retry"
    done
  fi

  stage=$(mktemp -d "$DATA/.rootfs.XXXXXX")
  trap 'if [ "$committed" = yes ] || restore_rootfs; then
    podman unshare rm -rf --one-file-system -- "$stage" ||
      warn "Could not remove working files at $stage"
  else
    warn "Previous filesystem remains at $stage/old"
  fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  printf 'Preparing the shared filesystem…\n'
  unpack_image "$stage/new"
  # The extracted filesystem needs the shared SELinux label.
  if [ "$(podman_selinux)" = true ]; then
    printf 'Labeling the shared filesystem for SELinux…\n'
    podman unshare chcon -Rh -t container_file_t -l s0 -- "$stage/new"
  fi

  version=$(rootfs_opencode_version "$stage/new")

  if [ "$mode" = reset ]; then
    if [ "$version" != "$OPENCODE_TAG" ]; then install_opencode "$stage/new"; fi
    printf 'Preserving provider logins…\n'
    if ! podman run --rm --network=none "${ROOTFS_OPTIONS[@]}" --rootfs "$ROOTFS" \
      opencode --standalone auth export 2>/dev/null 8<&- 9<&- |
      podman run --rm -i --network=none "${ROOTFS_OPTIONS[@]}" --rootfs "$stage/new" \
        opencode --standalone auth import >/dev/null 2>&1 8<&- 9<&-; then
      die "could not preserve provider logins. OpenCave data was kept"
    fi
  fi

  if [ -d "$ROOTFS" ]; then mv -T -- "$ROOTFS" "$stage/old"; fi
  mv -T -- "$stage/new" "$ROOTFS"
  if [ "$mode" = reset ]; then reset_server_settings; fi
  committed=yes
)

require_rootfs() {
  require_data_mounts
  require_owned_data
  [ -d "$ROOTFS" ] || die "the shared filesystem is missing. Run ./setup.sh"
}

require_idle_data() {
  local owned
  local -a sessions=()
  owned=$(podman ps -aq --filter status=running --filter status=paused \
    --filter "label=$IMAGE_OWNER=$SCRIPT_DIR") || die "could not check active OpenCave containers"
  [ -n "$owned" ] || return 0
  [ "${1:-}" = stop ] || die "OpenCave is in use. Close its sessions and retry."
  mapfile -t sessions <<< "$owned"
  podman rm --force --ignore "${sessions[@]}" >/dev/null
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
      printf 'SELinux labels kept on %q. To preview a reset, run restorecon -nRFvx -- %q\n' "$1" "$1" >&2
      return 1 ;;
  esac
  command -v restorecon >/dev/null || die "install policycoreutils to check SELinux project labels"
  # Podman's relabel can cross mountpoints; our check and cleanup must not.
  mount=$(project_mountpoint "$1") || die "could not check mountpoints under $1"
  [ -z "$mount" ] || die "refusing to relabel $1: it includes mountpoint $mount"
  diagnostics=$(restorecon -nRFvxI -- "$1" 2>&1 | sed -n '1p') ||
    die "could not check SELinux labels under $1: $diagnostics"
  if [ -n "$diagnostics" ]; then
    printf 'SELinux labels kept under %q. To preview a reset, run restorecon -nRFvx -- %q\n' "$1" "$1" >&2
    return 1
  fi
  # Podman can relabel the project even if the container fails to start.
  record_labeled_project "$1" || die "could not record SELinux cleanup path: $1"
  printf '%s\n' z
}

read_labeled_projects() {
  local -n projects=$1
  local ledger=$DATA/.selinux-default-projects entry project identity
  [ ! -L "$ledger" ] && [ -f "$ledger" ] || return 0
  while IFS= read -r entry; do
    project=${entry#*$'\t'}
    identity=${entry%%$'\t'*}
    if [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] && is_home_subdirectory "$project"; then
      projects["$project"]=$identity
    fi
  done < "$ledger"
}

show_project_label_cleanup() {
  local -A recorded=()
  read_labeled_projects recorded || return 1
  [ "${#recorded[@]}" -gt 0 ] || return 0
  local -a projects=("${!recorded[@]}")
  printf 'Projects recorded for SELinux cleanup:\n'
  printf '  %q\n' "${projects[@]}"
  [ "${1:-}" = manual ] || return 0
  cat <<'HELP'
To handle labels manually, stop containers using the folder and unmount any nested mounts.
For each listed project, set project to its current path.
HELP
  printf '  project=%q\n' "${projects[0]}"
  cat <<'HELP'
  # Preview the label changes
  find "$project" -xdev -context '*:object_r:container_file_t:s0' -print0 | restorecon -nFv -0 -f -
  # Apply the changes after reviewing the preview
  find "$project" -xdev -context '*:object_r:container_file_t:s0' -print0 | restorecon -Fv -0 -f -
Then run opencave uninstall --keep-labels after handling all listed folders.
HELP
}

reset_project_labels() {
  local ledger=$DATA/.selinux-default-projects project ids mounts mount current busy diagnostics
  local -A recorded=()
  local -a containers=() active_mounts=() pending=()
  read_labeled_projects recorded || return 1
  [ "${#recorded[@]}" -gt 0 ] || return 0

  if ! command -v restorecon >/dev/null ||
    [ "$(podman_selinux)" != true ]; then
    printf 'SELinux cleanup needs restorecon and an SELinux-enabled host. Pending folders:\n' >&2
    printf '  %q\n' "${!recorded[@]}" >&2
    return 1
  fi

  ids=$(podman ps -q --all --filter status=running --filter status=paused) ||
    { printf 'SELinux cleanup pending. Could not check active Podman containers.\n' >&2; return 1; }
  if [ -n "$ids" ]; then
    mapfile -t containers <<< "$ids"
    mounts=$(podman container inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "${containers[@]}") ||
      { printf 'SELinux cleanup pending. Could not check active Podman mounts.\n' >&2; return 1; }
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
      printf 'SELinux cleanup pending for %q. If moved, return the original folder to this path and retry.\n' "$project" >&2
      pending+=("${recorded[$project]}"$'\t'"$project")
      continue
    fi
    busy=no
    for mount in "${active_mounts[@]}"; do
      if paths_overlap "$project" "$mount"; then busy=yes; break; fi
    done
    if [ "$busy" = yes ]; then
      printf 'SELinux cleanup pending for %q. Stop the container using it and retry.\n' "$project" >&2
      pending+=("${recorded[$project]}"$'\t'"$project")
      continue
    fi
    if ! mount=$(project_mountpoint "$project") || [ -n "$mount" ]; then
      printf 'SELinux cleanup pending for %q. Check for nested mounts and retry.\n' "$project" >&2
      pending+=("${recorded[$project]}"$'\t'"$project")
      continue
    fi
    # Leave any later non-:z labels alone.
    if ! diagnostics=$(
      { find "$project" -xdev -context '*:object_r:container_file_t:s0' -print0 |
        restorecon -F -0 -f -; } 2>&1
    ) || [ -n "$diagnostics" ]; then
      [ -z "$diagnostics" ] || printf '%s\n' "$diagnostics" >&2
      printf 'SELinux cleanup pending for %q. Label restoration did not complete.\n' "$project" >&2
      pending+=("${recorded[$project]}"$'\t'"$project")
    else
      printf 'Restored SELinux labels under %q.\n' "$project"
    fi
  done
  if [ "${#pending[@]}" -eq 0 ]; then
    rm -f -- "$ledger"
    return
  fi

  local tmp
  tmp=$(mktemp "$DATA/.selinux-default-projects.XXXXXX") || return 1
  if ! printf '%s\n' "${pending[@]}" > "$tmp" || ! mv -f -- "$tmp" "$ledger"; then
    rm -f -- "$tmp"
  fi
  return 1
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
  start_server
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

  latest=$(curl --disable -fsSL --max-time 15 \
    'https://api.github.com/repos/anomalyco/opencode/releases?per_page=100' 2>/dev/null |
    sed -n 's/.*"tag_name": *"v\(2\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' |
    sort -Vr | sed -n '1p') || latest=
  if [ -z "$latest" ]; then
    die "could not find an OpenCode v2 release; set a known-good OPENCODE_TAG in $ENV_FILE and retry"
  fi
  OPENCODE_TAG=$(printf '%s\n%s\n' "$OPENCODE_TAG" "$latest" | sort -V | tail -n1)

  latest=$(curl --disable -fsSL --max-time 15 \
    'https://registry.npmjs.org/@openchamber%2Fweb/latest' 2>/dev/null |
    sed -n 's/.*"version":"\([0-9][^"]*\)".*/\1/p') || latest=
  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "could not find an OpenChamber release; set a known-good OPENCHAMBER_VERSION in $ENV_FILE and retry"
  fi
  OPENCHAMBER_VERSION=$(printf '%s\n%s\n' "$OPENCHAMBER_VERSION" "$latest" | sort -V | tail -n1)
}

update_command() {
  local update_system=$1 before chamber_before=$OPENCHAMBER_VERSION
  require_rootfs
  if server_containers; then die "run opencave serve-stop before updating"; fi
  require_idle_data
  [ -t 0 ] || die "opencave update needs a terminal for confirmation"
  printf 'Updates OpenCode and OpenChamber versions. Keeps your data untouched.\n'
  if [ "$update_system" = yes ]; then printf 'Also upgrades Alpine packages in OpenCave.\n'; fi
  if ! ask_yes "Update OpenCave?" no; then
    printf 'Cancelled.\n'
    return 0
  fi

  printf 'Checking for releases…\n'
  resolve_versions
  lock_data
  require_idle_data
  if [ "$update_system" = yes ]; then
    podman run --rm "${ROOTFS_OPTIONS[@]}" --rootfs "$ROOTFS" \
      apk upgrade --no-cache 8<&- 9<&- || die "could not upgrade Alpine packages"
  fi
  before=$(rootfs_opencode_version "$ROOTFS") || die "could not check the installed OpenCode version"
  if [ "$OPENCODE_TAG" != "$before" ]; then
    printf 'Installing OpenCode %s…\n' "$OPENCODE_TAG"
    install_opencode "$ROOTFS"
  fi
  write_config
  if [ "$OPENCODE_TAG" = "$before" ]; then
    printf 'OpenCode has no newer release (%s).\n' "$OPENCODE_TAG"
  else
    printf 'OpenCode updated to %s.\n' "$OPENCODE_TAG"
  fi
  if [ "$OPENCHAMBER_VERSION" = "$chamber_before" ]; then
    printf 'OpenChamber has no newer release (%s).\n' "$OPENCHAMBER_VERSION"
  else
    printf 'OpenChamber will use %s the next time it starts.\n' "$OPENCHAMBER_VERSION"
  fi
  if ! remove_owned_images "$IMAGE" "$BASE_IMAGE:$OPENCODE_TAG"; then
    warn "Some old images remain. Cleanup will retry on the next update or uninstall."
  fi
}

reset_server_settings() (
  local config=$ENV_FILE data=$DATA opencode_tag=$OPENCODE_TAG chamber_version=$OPENCHAMBER_VERSION
  ENV_FILE=/dev/null
  load_config
  ENV_FILE=$config
  DATA=$data
  OPENCODE_TAG=$opencode_tag
  OPENCHAMBER_VERSION=$chamber_version
  OPENCODE_SERVER_PASSWORD=$(password)
  write_config
)

reset() {
  case "${1:-}" in
    -h|--help) printf 'Usage: opencave reset\n'; return ;;
  esac
  [ "$#" -eq 0 ] || die "usage: opencave reset"
  require_install
  [ -t 0 ] || die "opencave reset needs a terminal for confirmation"
  require_owned_data
  printf 'Reset deletes chats, settings, skills, and the internal Linux filesystem.\n'
  printf 'Provider logins and project files are kept. You can import host skills afterward.\n'
  if ! ask_yes "Reset OpenCave?" no; then
    printf 'Cancelled.\n'
    return 0
  fi
  require_rootfs
  replace_rootfs reset
  printf 'OpenCave reset complete.\n'
  import_skills setup || warn "skill import did not finish. Retry with opencave import-skills."
}

uninstall() {
  local delete_data=no delete_source=no app_dir=$HOME_DIR/.local/share/opencave marker=$ENV_FILE.bootstrap
  [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ] ||
    die "this is not the installed checkout; run 'opencave uninstall'"
  [ -f "$ENV_FILE" ] || die "settings are missing: $ENV_FILE; run ./setup.sh here and retry"

  printf 'OpenCave will remove its containers, tracked images, CLI, and settings.\n'
  if [ ! -L "$DATA/.opencave-owner" ] &&
    [ -f "$DATA/.opencave-owner" ] && [ "$(< "$DATA/.opencave-owner")" = "$SCRIPT_DIR" ] &&
    ! contains_path "$DATA" "$WORKSPACE" && ! contains_path "$DATA" "$SCRIPT_DIR" &&
    ! contains_path "$DATA" "$(realpath -m -- "$HOME")"; then
    delete_data=yes
    printf 'Data to remove: %s\n' "$DATA"
  else
    printf 'Data kept: %s (shared or unmarked)\n' "$DATA"
  fi
  if [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(< "$marker")" = "$SCRIPT_DIR" ] &&
    [ ! -e "$SCRIPT_DIR/.git" ] && [ ! -L "$SCRIPT_DIR/.git" ] &&
    ! contains_path "$SCRIPT_DIR" "$HOME_DIR" && ! contains_path "$SCRIPT_DIR" "$WORKSPACE" &&
    { [ "$delete_data" = yes ] || ! contains_path "$SCRIPT_DIR" "$DATA"; }; then
    delete_source=yes
    printf 'Bootstrap source to remove: %s\n' "$SCRIPT_DIR"
  fi
  if [ "$yes_flag" = no ]; then
    [ -t 0 ] || die "use --yes for unattended uninstall"
    if [ "$keep_labels" = no ]; then show_project_label_cleanup; fi
    if ! ask_yes "Uninstall OpenCave?" no; then
      printf 'Uninstall cancelled.\n'
      if [ "$keep_labels" = no ]; then show_project_label_cleanup manual; fi
      return 0
    fi
  fi

  stop_server
  require_idle_data stop
  # An attached TUI or shell may need a moment to release its lock.
  lock_data 5
  require_idle_data
  if [ "$delete_data" = yes ]; then require_unmounted_path "$DATA"; fi
  if [ "$delete_source" = yes ]; then require_unmounted_path "$SCRIPT_DIR"; fi
  if [ "$keep_labels" = no ] && ! reset_project_labels; then
    printf 'Uninstall paused. Rerun opencave uninstall to retry.\n' >&2
    show_project_label_cleanup manual >&2
    return 1
  fi
  if ! remove_owned_images; then
    printf 'Image cleanup pending. Check the Podman output and rerun opencave uninstall.\n' >&2
    return 1
  fi
  if [ "$delete_data" = yes ]; then
    podman unshare rm -rf --one-file-system -- "$DATA"
    if [[ "$DATA" == */opencave/data && "${DATA%/data}" != "$app_dir" ]]; then
      rmdir -- "${DATA%/data}" 2>/dev/null || true
    fi
  fi
  if [ "$delete_source" = yes ]; then rm -rf --one-file-system -- "$SCRIPT_DIR"; fi
  rm -f -- "$BASE_IMAGES_FILE" "$ENV_FILE" "$CLI"
  rmdir -- "$app_dir" 2>/dev/null || true
  printf 'OpenCave uninstalled.\n'
}

open_session() {
  require_install
  local mode=$1 dir name mount_mode workdir=/root
  shift
  local -a mounts=() args=(opencode --standalone)
  if [ "$mode" = shell ]; then
    [ "$#" -eq 0 ] || die "usage: opencave shell"
    args=(/bin/bash)
  else
    [ "$#" -le 1 ] || die "usage: opencave [DIR]"
    dir=$(absolute_path "${1:-$CALL_DIR}") || exit 1
    [ -d "$dir" ] || die "not a directory: $dir"
    require_project_mount "$dir"
    name=${dir##*/}
    workdir=/workspace/${name:-workspace}
  fi

  require_rootfs
  # Keep the lock in this process until Podman exits.
  exec 8< "$DATA"
  flock -sn 8 || die "OpenCave is busy. Retry after the current maintenance command finishes."
  [ -f "$ENV_FILE" ] || die "OpenCave was uninstalled"
  if [ "$mode" != shell ]; then
    mount_mode=$(project_mount_mode "$dir") || exit 1
    mounts=(-v "$dir:$workdir:$mount_mode")
  fi
  podman run --rm -it --label "$IMAGE_OWNER=$SCRIPT_DIR" "${ROOTFS_OPTIONS[@]}" --env "PATH=$ROOTFS_PATH" \
    "${mounts[@]}" -w "$workdir" --rootfs "$ROOTFS" "${args[@]}" 8<&-
}

case "${1:-}" in
  help|-h|--help) show_usage; exit 0 ;;
esac
if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then
  die "run OpenCave on the host"
fi

cmd=${1:-}
case "$cmd" in
  shell|creds|serve|serve-stop|serve-restart|serve-status|serve-logs|update|version|import-auth|import-skills|reset|uninstall)
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
  require_rootless_podman
fi
HOME_DIR=$(absolute_path "$HOME")

# Serialize configuration and server changes.
case "$cmd" in
  setup|serve|serve-stop|serve-restart|update|reset|uninstall|import-auth|import-skills)
    exec 9< "$SCRIPT_DIR"
    if ! flock -xn 9; then
      printf 'Waiting for another OpenCave command to finish…\n'
      flock -x 9
    fi ;;
esac

first_install=no
[ -f "$ENV_FILE" ] || first_install=yes
load_config
DATA=$(absolute_path "${DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data}" "$SCRIPT_DIR")
ROOTFS=$DATA/rootfs

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
  reset) reset "$@"; exit ;;
  session|shell) open_session "$cmd" "$@"; exit ;;
esac

yes_flag=no import_first=yes update_system=no keep_labels=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-import-auth) import_first=no ;;
    --yes) yes_flag=yes ;;
    --keep-labels)
      [ "$cmd" = uninstall ] || die "--keep-labels is for uninstall"
      keep_labels=yes ;;
    --system)
      [ "$cmd" = update ] || die "--system is for update"
      update_system=yes ;;
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
    update_command "$update_system"
    exit ;;
  setup) ;;
  *) die "unknown command: $cmd" ;;
esac

require_data_mounts
if contains_path "$DATA" "$SCRIPT_DIR"; then
  die "DATA must not contain the checkout"
fi
if [ -e "$CLI" ] || [ -L "$CLI" ]; then
  [ -L "$CLI" ] && [ "$(readlink -f -- "$CLI")" = "$SCRIPT_DIR/setup.sh" ] ||
    die "$CLI belongs to another install or command"
fi

umask 077
if podman image exists "$IMAGE"; then
  [ "$(podman image inspect --format "{{index .Labels \"$IMAGE_OWNER\"}}" "$IMAGE")" = "$SCRIPT_DIR" ] ||
    die "image $IMAGE does not belong to this OpenCave checkout"
else
  build_image
fi
if [ -f "$ENV_FILE" ]; then stop_server; fi
prepare_data
if [ ! -d "$ROOTFS" ]; then replace_rootfs init; fi
require_rootfs
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
printf 'OpenCave is ready.\n'
if ! command -v opencave >/dev/null; then
  printf '%s\n' 'Run this in your current shell to use opencave:' '  export PATH="$HOME/.local/bin:$PATH"'
fi
