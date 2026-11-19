#!/usr/bin/env bash
# Fetch OpenCave and run setup. One-liner: curl -fsSL .../bootstrap.sh | bash
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  printf '%s\n' 'error: run OpenCave as your regular user' >&2
  exit 1
fi
for tool in git curl podman flock; do
  if ! command -v "$tool" >/dev/null; then
    printf 'error: install %s before running the OpenCave bootstrap\n' "$tool" >&2
    exit 1
  fi
done

repo=${OPENCAVE_REPO_URL:-https://github.com/ernvk23/opencave.git}
src=${OPENCAVE_SRC:-$HOME/.local/share/opencave/src}

if [ -d "$src/.git" ]; then
  git -C "$src" pull --ff-only
else
  mkdir -p "$(dirname "$src")"
  git clone "$repo" "$src"
fi

# setup.sh prompts only on a TTY; a curl pipe is not one.
if (exec </dev/tty) 2>/dev/null; then
  exec "$src/setup.sh" "$@" </dev/tty
fi
exec "$src/setup.sh" "$@"
