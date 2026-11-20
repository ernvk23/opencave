# OpenCave

A convenient rootless container for [OpenCode](https://opencode.ai). Agent access is scoped to the mounted folder, keeping the rest of the machine out of reach. Optional [OpenChamber](https://openchamber.dev) web UI.

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
opencave shell                   # Open a shell
opencave serve [DIR]             # Start the server
opencave serve --openchamber     # Include the web UI
opencave import-skills [DIR]     # Import host skills
opencave help                    # List commands

opencave update                  # Update OpenCode and OpenChamber
opencave update --system         # Also upgrade Alpine packages in OpenCave
opencave reset                   # Clear chats and packages, keep provider logins
```

## Uninstall

```sh
opencave uninstall
```

Removes its containers, images, CLI, and local data. Mounted project folders are never touched.

[MIT license](LICENSE)
