#!/usr/bin/env bash
# Fetch OpenCave and run setup. One-liner: curl -fsSL .../bootstrap.sh | bash
set -euo pipefail

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
