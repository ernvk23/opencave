#!/usr/bin/env bash
# Fetch OpenCave and run setup. One-liner: curl -fsSL .../bootstrap.sh | bash
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  printf '%s\n' 'error: run OpenCave as your regular user' >&2
  exit 1
fi
for tool in curl tar podman flock; do
  if ! command -v "$tool" >/dev/null; then
    printf 'error: install %s before running the OpenCave bootstrap\n' "$tool" >&2
    exit 1
  fi
done

archive=${OPENCAVE_ARCHIVE_URL:-https://github.com/ernvk23/opencave/archive/refs/heads/main.tar.gz}
src=${OPENCAVE_SRC:-$HOME/.local/share/opencave/src}

mkdir -p "$src"
tmp=$(mktemp) || exit 1
trap 'rm -f -- "$tmp"' EXIT
if ! curl -fsSL --max-time 60 "$archive" -o "$tmp"; then
  printf 'error: could not download %s\n' "$archive" >&2
  exit 1
fi
if ! tar -xzf "$tmp" -C "$src" --strip-components=1; then
  printf 'error: could not extract OpenCave into %s\n' "$src" >&2
  exit 1
fi

# setup.sh prompts only on a TTY; a curl pipe is not one.
if (exec </dev/tty) 2>/dev/null; then
  exec "$src/setup.sh" "$@" </dev/tty
fi
exec "$src/setup.sh" "$@"
