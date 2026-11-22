# AGENTS.md

OpenCave is a Bash CLI that runs OpenCode (and optionally OpenChamber) in rootless Podman containers. The implementation lives in `setup.sh`, `bootstrap.sh`, and `Containerfile`. There is no CI or test suite.

## Verify changes

- Run `bash -n setup.sh && bash -n bootstrap.sh` to check shell syntax.
- `./setup.sh help` checks help output without installing anything.
- Real verification needs a non-root host with local rootless Podman and subordinate UID/GID ranges. `setup.sh` refuses root and container environments (`/run/.containerenv`, `/.dockerenv`).
- Do not run install, reset, or uninstall against someone's real install without asking; they build images, create data, stop containers, and delete state.
- To test the curl installer from a branch, set `OPENCAVE_ARCHIVE_URL` (and optionally `OPENCAVE_SRC`) before running `bootstrap.sh`.

## Architecture and state

- `setup.sh` is both installer and installed CLI: `~/.local/bin/opencave` is a symlink to it. Dispatch depends on `$0` basename and first arg, so bare `./setup.sh` installs while bare `opencave` opens a TUI session.
- Runtime state defaults to `${XDG_DATA_HOME:-$HOME/.local/share}/opencave/data` (`DATA`), with the shared filesystem at `$DATA/rootfs`. Containers run against that extracted rootfs (`--rootfs`), not the image directly. Use `podman unshare` for host operations that need access to files with mapped ownership.
- OpenChamber is a second container sharing OpenCode's network namespace; OpenCode comes from the pinned upstream image, OpenChamber is installed by `npx` at start.
- `.env` is generated, gitignored, chmod 600, and holds server passwords; `.env.base-images` tracks image IDs for cleanup; `$DATA/.opencave-owner` records the owning checkout. Image/container label `io.opencave.checkout` backs the same ownership checks. Don't edit or delete these by hand.
- Commands that mutate config/server state serialize on fd 9 locked at the checkout; data work locks fd 8 at `$DATA`. Long-lived `podman` children must close them (`8<&- 9<&-`) or they inherit the locks.
- Project paths must resolve below `$HOME`, must not overlap the checkout or `$DATA`, and cannot contain `:` or line breaks. Project mounts are read-write; runtime containers use `label=disable` and do not restore old labels.
- `--socket` is a trusted-session opt-in: pass the rootless Podman socket only to the opted-in container. In this mode, the TUI and server mount the project at its host path. Both shell modes start in the container's `/root` without a project mount. Docker CLI, Compose, and Podman remote ship in the image; `update --system` adds them to existing rootfs installs under the data lock.

## Change map

- New subcommand: update `usage()`, the first-arg dispatch, and the command `case` block near the bottom of `setup.sh`. Add it to the fd-9 lock list if it changes configuration or server state.
- New config key: add the default and key whitelist in `load_config`, plus `write_config`, or it will not persist.
- Version bumps: update `OPENCODE_TAG` in `load_config` and keep the `Containerfile` ARG default in sync; `OPENCHAMBER_VERSION` lives only in `setup.sh`.
- Container packages: edit `Containerfile` for fresh installs; `opencave update --system` applies `apk upgrade` to an existing rootfs.
- Users install from the `main` tarball, so shipped changes must land on `main`.

## Style

Bash with `set -euo pipefail`, lowercase function names, `die`/`warn` for diagnostics, and quoted paths. Keep the existing structure rather than extracting helpers.
