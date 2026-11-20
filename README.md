# OpenCave

Run [OpenCode](https://opencode.ai/) in rootless Podman, with an optional
[OpenChamber](https://openchamber.dev/) web UI. Podman runs both directly.

## Install

Use local rootless Podman, `curl`, `tar`, and `flock` from `util-linux`.

```sh
# Fedora / RHEL
sudo dnf install podman curl util-linux tar
# Debian / Ubuntu
sudo apt install podman uidmap curl util-linux tar
```

```sh
curl -fL --progress-bar https://raw.githubusercontent.com/ernvk23/opencave/main/bootstrap.sh | bash
```

From a local checkout, run `./setup.sh`. Add `~/.local/bin` to `PATH` if needed.

## Run

```sh
opencave [DIR]               # TUI, defaults to the current folder
opencave shell               # Bash in the shared environment
opencave serve [DIR]         # OpenCode server
opencave serve --openchamber # Add the web UI
opencave serve-stop
opencave serve-restart
opencave serve-status
opencave serve-logs [openchamber]
opencave creds
opencave help
```

OpenCode starts at <http://127.0.0.1:4096/> with username `opencode`.
OpenChamber uses <http://127.0.0.1:3000/>. Starting or restarting the server
shows its passwords in your terminal. `opencave creds` shows them on demand.

## Storage and maintenance

The shell, TUI, and server share an OpenCave-owned Linux filesystem under
`${XDG_DATA_HOME:-~/.local/share}/opencave/data/rootfs`. OpenCode uses its normal
`~/.local/share/opencode` database. Package installs and configuration changes
persist across launches. npm uses its defaults. For Python, use Alpine packages
or a virtual environment you create with `python3 -m venv`.

The selected project is the writable host directory. Keep the host home and
system directories outside the mount, and leave SELinux or AppArmor enabled.
Each container has a private `/tmp`. Close other sessions before changing shared
system packages.

- `opencave import-auth` imports host provider logins. Setup does this by
  default. Use `./setup.sh --no-import-auth` to skip it.
- `opencave import-skills [DIR]` copies host skills into OpenCave.
- `opencave --update` refreshes the system outside `/root` after confirmation.
  It keeps the container home and may require reinstalling system packages.
  `--no-cache` rebuilds without cached layers.
- `opencave --reset` recreates the filesystem, clears chats, skills, packages,
  and settings, keeps provider logins, and offers to import host skills again.
- `opencave --uninstall` removes the CLI, owned data, OpenCave images, and
  bootstrap source. It removes the install directory once empty and keeps
  manual checkouts.
  It also restores project SELinux labels recorded by OpenCave. If a restore
  needs attention, it prints the manual steps.

Stop the server and close sessions before updating or resetting. Updates,
resets, and uninstall preserve project files.

[MIT license](LICENSE)
