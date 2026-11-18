# OpenCave

Run [OpenCode](https://opencode.ai/) in rootless Podman. Open a terminal session
with one project mounted, or run a persistent local server with an optional
[OpenChamber](https://openchamber.dev/) web UI.

## Install

Use Linux with rootless Podman. Service mode also needs a systemd user session,
`curl`, and a `podman compose` provider with profiles and
`up --abort-on-container-exit` support.

```sh
curl -fsSL https://raw.githubusercontent.com/ernvk23/opencave/main/bootstrap.sh | bash
```

Or clone the repository and run `./setup.sh`. Choose on-demand or service mode
at the prompt. Unattended setup defaults to on-demand. Use
`./setup.sh --workspace ~/projects --port 4096` for an unattended service install.
The installer links `opencave` into `~/.local/bin`. Add that directory to your
`PATH` if needed.

If host OpenCode supports `auth export`, setup attempts a one-time import of
provider credentials. Use `--no-import-auth` to skip it, `opencave import-auth`
to run it later, or log in from an OpenCave session. Re-running setup on an
existing install shows the current status; use `opencave reconfigure` to change
settings.

## Use

```sh
opencave                     # TUI in the current folder
opencave ../project          # TUI in another folder
opencave shell               # Bash with shared tools and config
opencave help                # show commands
opencave creds               # show service URLs and passwords
opencave service-start       # enable and start the systemd user service
opencave service-stop        # stop and disable the service
opencave service-restart
opencave service-status
opencave service-logs
opencave reconfigure         # change mode, workspace, or OpenChamber
opencave service-remove      # return to on-demand and keep data
opencave update              # rebuild the image and refresh a running service
opencave version             # version in the installed image
opencave uninstall           # prompts before removal
```

Service mode mounts `~/opencave` by default. OpenCode listens at
<http://127.0.0.1:4096/> with username `opencode`. If enabled, OpenChamber
listens at <http://127.0.0.1:3000/> and uses a separate UI password. Its first
launch downloads the pinned npm package. `opencave update` also updates
OpenChamber to the latest version when it is enabled; `OPENCAVE_PIN=1` keeps
the pinned version. If the service is running, the UI container is recreated.
Set `OPENCHAMBER_VERSION` in `.env` and run `opencave service-restart` to pin or
change it manually. Use `opencave service-status` and `opencave service-logs`
for OpenCode, or `podman logs opencave-openchamber` for the UI.

In service mode, `opencave creds` prints the URLs and passwords. Setup,
`service-start`, and `service-restart` also show them when their output goes to
a terminal.
Passwords and settings also live in the checkout's mode-0600 `.env`
(`~/.local/share/opencave/src/.env` for the one-line install). Read
`OPENCODE_SERVER_PASSWORD` and `OPENCHAMBER_UI_PASSWORD` there. The file
accepts literal `KEY=value` lines. Use `opencave service-restart` after
changing it.

## Data and isolation

On-demand sessions mount the folder you select. Service mode mounts the
configured workspace. Both use a writable mount at `/workspace/<folder>` and
share OpenCave's data directory, which defaults to
`~/.local/share/opencave/data` or `$XDG_DATA_HOME/opencave/data`.

| Under `DATA` | What persists |
| --- | --- |
| `share`, `state` | OpenCode database, sessions, credentials, and state |
| `config` | OpenCode configuration, skills, and MCP definitions |
| `agents` | Global skills installed with `npx skills add -g` |
| `bin`, `cache` | Tools on `PATH` and files under `/root/.cache` |
| `openchamber` | OpenChamber configuration and npm cache |

The image includes Git, Bash, Node.js, npm, Python, ripgrep, jq, curl, file,
xz, unzip, tree, and less. Use `opencave shell`
to add tools under `/root/.local/bin` and global OpenCode config under
`/root/.config/opencode`. Global skills installed with `npx skills add -g`
persist under `/root/.agents`. The shell starts in `/root` with only the shared
`$DATA` bind mounts. Use `opencave DIR` for a project TUI. For system packages,
edit the `Containerfile` and run `opencave update`.

The containers run rootless and keep separate configuration from host OpenCode.
An agent can modify its mounted workspace and access the shared OpenCave data.
Choose folders accordingly, especially on SELinux systems where Podman
relabels bind mounts. OpenCave refuses to mount a directory that contains your
home directory.

`opencave uninstall` closes OpenCave sessions and removes the CLI link,
service, settings, and any data directory marked as belonging to that
checkout. The workspace, image, checkout, and unmarked data from older
installs are kept. Back up `.env`, `DATA/share`, `DATA/config`, and
`DATA/agents` if you plan to reuse them.
Pass `--yes` for unattended uninstall.
On SELinux systems, uninstall attempts to restore the configured workspace's
labels. For other mounted folders, use `restorecon -R -F <folder>` after
closing sessions that use them.

## MCPs

Install local MCPs from `opencave shell`. For example, [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)
builds a reusable index for navigating a codebase.

```sh
opencave shell
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash
```

The binary in `/root/.local/bin`, the OpenCode registration in
`/root/.config/opencode`, and the default index in
`/root/.cache/codebase-memory-mcp` survive container recreation. Check the
registration with `opencode mcp list` inside the shell. If the entry is missing,
register it with the OpenCode v2 command below.

```sh
opencode mcp add codebase-memory-mcp --global -- /root/.local/bin/codebase-memory-mcp
```

Start a new session or run `opencave service-restart` for the service. Index
the repo at its path under `/workspace/<folder>` to avoid needing approval for
a top-level root.

Files written to the container's own filesystem disappear when the container
is removed. If an MCP lets you choose its state directory, point it at
`/root/.cache/<tool>`. Use `/root/.local/bin` for standalone executables or
install system dependencies in the `Containerfile`.

For a tool with a fixed path such as `/root/.local/share/my-mcp`, create
`$DATA/mcp/my-mcp` on the host using the `DATA` path from `.env`. Copy any
existing state there before removing the old container. In service mode, add
the following bind mount under `services.opencave.volumes` in `compose.yaml`.

```yaml
- "${DATA}/mcp/my-mcp:/root/.local/share/my-mcp:z"
```

For on-demand sessions and `opencave shell`, the `mounts` array in `setup.sh`
takes the equivalent Podman flag.

```bash
-v "$DATA/mcp/my-mcp:/root/.local/share/my-mcp:z"
```

Restart the service or start a new session to use the mount.

## Updating

Setup and `opencave update` look for a stable OpenCode v2 release. `update` also
bumps OpenChamber to the latest npm version when it is enabled. If release
lookup fails, first install uses the tag in the `Containerfile`. An existing
installation keeps its image. To keep the pinned versions deliberately, run
`OPENCAVE_PIN=1 opencave update`. Before downgrading, stop sessions and back up
`DATA/share` because database migrations may be irreversible.

[MIT license](LICENSE)
