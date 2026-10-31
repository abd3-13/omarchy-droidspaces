# Droidspaces for Omarchy

A bar widget and panel for the containers managed by
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS/) on this machine.

- Live count on the bar (`running` or `running/total`)
- List of configured containers with OS, hostname, IP, uptime, CPU and RAM
- Create a container from a downloaded rootfs tarball into a sparse ext4 image
- Start, stop and restart
- Open a shell in a running container
- Details: rootfs, network mode, ports, memory/CPU/PID limits, bind mounts,
  DNS and privileged flags
- Warns when a container's rootfs image or directory is missing: the row says
  `rootfs missing`, Start is disabled, and the helper refuses to start it
- Refresh and `droidspaces check` from the panel
- Keyboard: arrows move, Enter/Space expands, `n` new container,
  `s` start/stop, `r` refresh, `c` check, `d` disconnect, Esc collapses/closes

**New container** installs a rootfs tarball (`.tar`, `.tar.xz`, `.tar.gz`,
`.tar.zst`, …) into a sparse ext4 image. The panel asks for a name, the tarball
path (or **Browse**), an image size (default `16G`) and an optional image path;
by default the image goes to
`<workspace>/Containers/<name>/rootfs.img`. Creation formats the image,
extracts the tarball, verifies `/sbin/init` or `/usr/sbin/init`, and writes
the container config. It can optionally start the container afterwards.
Editing an existing container's configuration still stays in the terminal.

## Why a helper

Droidspaces needs root even to read live status (`show`, `check`) and for every
action (`start`, `stop`, `restart`). Prompting for every tick would be
unusable, so the widget starts one long-lived root bridge through `pkexec`:

1. `bin/ensure-helper` compares `bin/droidspaces-bridge` with the installed
   copy at `/usr/local/libexec/droidspaces-omarchy/bridge`.
2. If missing or different, it installs it with
   `/usr/bin/install -D -m 0755 -o root -g root` through `pkexec`. The root
   bridge is therefore root-owned, not a user-writable script.
3. It then `exec`s `pkexec /usr/local/libexec/droidspaces-omarchy/bridge --replace`.

The bridge streams one JSON object per line and accepts a small command set on
stdin (`refresh`, `watch`, `start`, `stop`, `restart`, `logs`, `check`,
`create`, `exit`). Creation streams `progress` messages while it prepares,
formats, mounts and extracts. Container names must match
`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` and no shell is ever invoked. It ticks
every 6 s while closed and 2 s while the panel is open.

Two lifecycle rules keep exactly one helper alive: a newly started bridge
stops older copies of itself (`--replace`), and every bridge exits when the
shell process that started it disappears. Plugin reloads and shell restarts
therefore do not leave root helpers behind. **Disconnect** stops it
immediately; otherwise it stays connected until you log out.

The first connect on a machine (or after a plugin update) may ask twice: once
to install the bridge and once to start it. Later sessions ask once, on the
first panel open, and every action after that is prompt-free until logout.

## Install

The plugin lives in the user plugin directory:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/local.droidspaces
omarchy plugin enable local.droidspaces right
```

`right` is only an example placement; use whichever bar section you prefer.
The widget is enabled from the normal Omarchy plugin/bar settings too.

Settings (plugin settings in `~/.config/omarchy/shell.json`):

| Key | Default | Meaning |
| --- | --- | --- |
| `showCount` | `true` | Show the number next to the bar icon |
| `connectOnStartup` | `false` | Authenticate when the shell starts instead of on first open |

## Files

```
local.droidspaces/
  manifest.json          plugin metadata and settings
  Panel.qml              bar widget + popup panel
  ContainerRow.qml       one container row and its details
  bin/droidspaces-bridge root helper (Python 3, installed by pkexec)
  bin/ensure-helper      install-if-needed + launch (called by the widget)
  bin/install-helper     install/refresh only (asks for authentication)
  bin/uninstall          remove the installed bridge
```

The bridge is standalone Python 3 with the standard library only. It can be
exercised without root against a fake workspace:

```sh
bin/droidspaces-bridge --workspace /tmp/ds-test --allow-nonroot --once
```

## Uninstall

```sh
omarchy plugin disable local.droidspaces
~/.config/omarchy/plugins/local.droidspaces/bin/uninstall
```

The second command removes `/usr/local/libexec/droidspaces-omarchy/bridge`
after one authentication prompt. Removing the plugin folder alone leaves the
installed helper behind.

To reinstall or refresh the helper manually (for example after editing
`bin/droidspaces-bridge`), run `bin/install-helper`; it asks for
authentication once and then returns.

## Troubleshooting

- Shell logs: `journalctl --user -t omarchy-shell -f`
- Validate the manifest: `omarchy plugin validate <plugin-folder>`
- `pkexec` exit codes: `126` means the prompt was dismissed, `127` means the
  action was not authorized or the helper could not be started.
- The panel shows the last action error and the last `show` error. Use
  **Check** to run `droidspaces check` as root.
- If a plugin update changed the bridge, the next connect asks for
  authentication again to refresh the installed copy.
- After editing the QML, a full shell restart (`omarchy restart shell`) may be
  needed: hot reload can keep an older compiled component even when the file
  on disk has changed. The bridge is not affected by this.

## Security notes

- The helper is root-owned and only accepts the fixed command set above; it
  never passes a container name through a shell.
- Creation only runs the fixed tools `mkfs.ext4`/`mke2fs`, `mount`, `tar` and
  `umount` with validated paths; it refuses to overwrite an existing image or
  container config.
- It runs the system `/usr/bin/droidspaces` as root. Keep that binary and the
  container root filesystems trusted: a writable container rootfs is, by
  design, a way to run code as root inside that container.
- Starting the helper stops older copies of this bridge (matched by their
  exact root-owned path), so reloading the plugin cannot accumulate root
  processes.
- Opening a shell uses a new `pkexec` in a terminal, so it asks for
  authentication separately from the persistent helper.
- The helper exits when the shell exits; **Disconnect** stops it immediately.
