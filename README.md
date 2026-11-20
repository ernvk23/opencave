# OpenCave

Run [OpenCode](https://opencode.ai/) in rootless Podman, with optional
[OpenChamber](https://openchamber.dev/) web access.

## Prerequisites

```sh
# Fedora / RHEL
sudo dnf install podman curl util-linux tar
# Debian / Ubuntu
sudo apt install podman uidmap curl util-linux tar
```

## Install

```sh
curl -fL --progress-bar https://raw.githubusercontent.com/ernvk23/opencave/main/bootstrap.sh | bash
```

From a local checkout, run `./setup.sh`.

**Note** If `~/.local/bin` is missing from `PATH`, run once and reopen your terminal. Use `~/.zshrc` for Zsh.

```sh
printf '\n%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## Run

```sh
opencave [DIR]               # TUI, defaults to the current folder
opencave shell               # Bash in OpenCave
opencave serve [DIR]         # OpenCode at http://127.0.0.1:4096
opencave serve --openchamber # Add the web UI at http://127.0.0.1:3000
opencave serve-stop
opencave creds               # Show server URLs and credentials
opencave help                # List all commands
```

OpenCave sessions share an internal Linux filesystem. The selected project is
the writable host directory.

## Maintenance

Stop the server and close other sessions before updating or resetting.

- `opencave update` updates OpenCode and OpenChamber. Keeps your data untouched.
- `opencave update --system` also upgrades Alpine packages inside OpenCave.
- `opencave reset` clears chats, settings, and installed packages. It keeps
  provider logins and offers to import host skills again.
- `opencave uninstall` removes OpenCave’s CLI, data, images, and bootstrap
  source, and restores the SELinux labels it changed.

[MIT license](LICENSE)
