# OpenCave

Run [OpenCode](https://opencode.ai/) in rootless Podman: a terminal TUI, or a
local server with the optional [OpenChamber](https://openchamber.dev/) web UI.

## Prerequisites

Local rootless Podman, `curl`, `tar`, and `flock` (`util-linux`).

Fedora / RHEL:

```sh
sudo dnf install podman curl util-linux tar
```

Debian / Ubuntu:

```sh
sudo apt install podman uidmap curl util-linux tar
```

Server mode needs [podman-compose 1.3+](https://github.com/containers/podman-compose)
(RHEL: EPEL) or Docker Compose v2 with the Podman user socket.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ernvk23/opencave/main/bootstrap.sh | bash
```

Or run `./setup.sh` from a local copy. Add `~/.local/bin` to `PATH` if needed.

Rootless Podman only; Docker Engine is not supported. Tested on Fedora 44/45;
Debian, Ubuntu, and RHEL need end-to-end testing.

## Run

```sh
opencave [DIR]                    # TUI (defaults to the current folder)
opencave shell                    # Bash with shared tools and config
opencave serve [DIR]              # background server
opencave serve --openchamber      # also start the web UI
opencave serve-stop
opencave serve-restart
opencave serve-status
opencave serve-logs [openchamber]
opencave creds
opencave help
```

`serve` defaults to the current folder. OpenCode defaults to
<http://127.0.0.1:4096/> (`--port` to change), username `opencode`.
OpenChamber defaults to <http://127.0.0.1:3000/> with its own password; use
`--no-openchamber` to skip it. `serve` shows passwords in your terminal only.
`serve-stop` removes the containers; data and passwords survive.

> [!NOTE]
> The agent can write to the project and shared OpenCave data. Mount one
> project below `~`, not your home, a config directory, or the installed checkout.
> Keep SELinux or AppArmor enabled.

> [!NOTE]
> On SELinux hosts, stale container labels block `serve`. Fix with:
>
> ```sh
> restorecon -nRFvx <project>   # preview
> restorecon -RFvx <project>    # apply
> ```
>
> Serving a parent relabels everything under it and fails if any custom label
> is found. AppArmor-only hosts skip this.

## Data and updates

Data lives in `$XDG_DATA_HOME/opencave/data` (default:
`~/.local/share/opencave/data`). Passwords and version pins live in the
installed checkout's mode-0600 `.env`.

- **Tools and MCPs:** In `opencave shell`, use `/root/.local/bin` for tools,
  `/root/.config/opencode` for config, and `/root/.cache` for tool state.
  Register local MCPs there with `opencode mcp add`; project paths inside the
  container are under `/workspace/`.
- **Import:** Setup can import host credentials (`--no-import-auth` skips it)
  and offers to copy missing skills. To import later, stop the server and close
  sessions, then run `opencave import-auth` or `opencave import-skills [DIR]`.
  Only import trusted skills; confirmed overwrites have no backup.
- **Update:** `opencave update` bumps versions, rebuilds the image, and restarts
  a running server. The one-liner refreshes the scripts. `--no-cache` also
  refreshes Alpine packages in the image.

## Uninstall

`opencave uninstall` removes the server, CLI, `.env`, and owned data.
**Project files, the checkout, and the image stay.** `--yes` skips confirmation.

Uninstall resets shared `:z` labels only in projects recorded for cleanup.
Replaced folders and folders still mounted by your Podman containers are skipped.

[MIT license](LICENSE)
