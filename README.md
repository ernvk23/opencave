# OpenCave

A rootless Podman container for [OpenCode](https://opencode.ai). By default, host file access is scoped to the mounted project. Optional [OpenChamber](https://openchamber.dev) web UI.

## Overview

![OpenCave overview](assets/overview.png)

**Motivation:** ask your host agent whether it can read your browser's passwords, history, SSH keys, or anything — and see...

## Prerequisites

```sh
# Fedora / RHEL
sudo dnf install podman curl util-linux tar
# Ubuntu / Debian
sudo apt install podman uidmap curl util-linux tar
```

## Install

```sh
curl -fL --progress-bar https://raw.githubusercontent.com/ernvk23/opencave/main/bootstrap.sh | bash
```

Or run `./setup.sh` from a checkout.

## Usage

```sh
opencave [DIR]                   # OpenCode in a project
opencave shell                   # Open Bash in the container's /root (no project needed)
opencave serve [DIR]             # Start OpenCode web UI
opencave serve [DIR] --openchamber # Add the OpenChamber UI
opencave import-skills [DIR]     # Import host skills
opencave help                    # List commands

opencave update                  # Update OpenCode and OpenChamber
opencave update --system         # Also upgrade Alpine packages in OpenCave
opencave reset                   # Clear chats and packages, keep provider logins
```

More commands: `opencave help`.

### Host Podman socket (optional)

If the socket isn’t active, run `systemctl --user enable --now podman.socket` on the host.

```sh
opencave --socket [DIR]           # OpenCode in a project with host Podman access
opencave shell --socket           # Open Bash in the container's /root (no project needed), with host Podman access
opencave serve --socket [DIR]     # Start OpenCode web UI with host Podman access
```

`docker`, `docker compose`, `podman`, and `podman compose` all use host Podman. Older installs can add the clients with `opencave update --system`.

**Trusted sessions only:** `--socket` grants access to host files and the host Podman engine. Resources it creates survive OpenCave uninstall.

## Uninstall

```sh
opencave uninstall
```

Removes OpenCave’s containers, images, CLI, local data, and the entire bootstrap-managed install directory. Mounted project folders are kept.

[MIT license](LICENSE)
