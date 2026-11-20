#!/usr/bin/env bash
# Fetch OpenCave and run setup. One-liner: curl -fL --progress-bar .../bootstrap.sh | bash
set -euo pipefail

die() {
  if [ -t 2 ]; then
    printf '\033[31merror:\033[0m %s\n' "$*"
  else
    printf 'error: %s\n' "$*"
  fi >&2
  exit 1
}

if [ "$EUID" -eq 0 ]; then
  die "run OpenCave as your regular user"
fi
for tool in curl tar podman flock; do
  command -v "$tool" >/dev/null || die "install $tool before running the OpenCave bootstrap"
done

archive=${OPENCAVE_ARCHIVE_URL:-https://github.com/ernvk23/opencave/archive/refs/heads/main.tar.gz}
src=${OPENCAVE_SRC:-$HOME/.local/share/opencave/src}

mkdir -p "$src"
src=$(realpath -e -- "$src")
if [ -z "$(find "$src" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  printf '%s\n' "$src" > "$src/.env.bootstrap"
fi
tmp=$(mktemp) || exit 1
trap 'rm -f -- "$tmp"' EXIT
printf 'Downloading OpenCave…\n'
progress=(--silent --show-error)
if [ -t 2 ]; then progress=(--progress-bar); fi
curl --fail --location "${progress[@]}" --max-time 60 "$archive" -o "$tmp" ||
  die "could not download $archive"
tar -xzf "$tmp" -C "$src" --strip-components=1 || die "could not extract OpenCave into $src"
rm -f -- "$tmp"

# setup.sh prompts only on a TTY; a curl pipe is not one.
if (exec </dev/tty) 2>/dev/null; then
  exec "$src/setup.sh" "$@" </dev/tty
fi
exec "$src/setup.sh" "$@"
