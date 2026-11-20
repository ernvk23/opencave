# OpenCave

Run OpenCode in rootless Podman, with optional OpenChamber web access.

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

## Commands

```sh
opencave [DIR]                   # OpenCode in a project
opencave shell                   # Open a shell
opencave serve [DIR]             # Start the server
opencave serve --openchamber     # Include the web UI
opencave help                    # List commands

opencave update                  # Update OpenCode and OpenChamber
opencave update --system         # Also upgrade Alpine packages in OpenCave
opencave reset                   # Clear chats and packages, keep provider logins
opencave uninstall               # Remove OpenCave
```

[MIT license](LICENSE)
