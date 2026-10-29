# kuma-heartbeat

Sends a heartbeat to an [Uptime Kuma](https://github.com/louislam/uptime-kuma)
**Push** monitor every minute, so Uptime Kuma alerts you when a host stops
reporting (powered off, offline, crashed, no network). Packaged as `.deb` for
Debian/Ubuntu (systemd) and for [Termux](https://termux.dev) (Android).

Each heartbeat is one request:

```
GET <KUMA_HOST>/api/push/<KUMA_TOKEN>?status=up&msg=OK&ping=<ms>
```

`ping` is the round trip of the previous heartbeat (the first one after a
start has no `ping`). The token is never printed: it is masked in every error
message and passed to `curl` through stdin, so it does not show in `ps`.

## Create the Push monitor in Uptime Kuma

1. **Add New Monitor** → type **Push**.
2. Copy the token: it is the last part of the Push URL
   (`https://kuma.example.com/api/push/<TOKEN>?status=up&msg=OK&ping=`).
3. Set **Heartbeat Interval** to about 1.5–2× the push interval: **90–120 s**
   for the default of 60 s. Too close to 60 s causes false alerts from timer
   jitter.

## Configuration

`/etc/kuma-heartbeat/kuma-heartbeat.conf` (Termux:
`$PREFIX/etc/kuma-heartbeat/kuma-heartbeat.conf`), shell syntax, mode `0600`.
The package ships it with empty values and never overwrites your edits on
upgrade.

| Key | Default | Meaning |
| --- | --- | --- |
| `KUMA_HOST` | – (required) | Base URL, e.g. `https://kuma.example.com` |
| `KUMA_TOKEN` | – (required) | Push token of the monitor |
| `KUMA_STATUS` | `up` | `up` or `down` |
| `KUMA_MSG` | `OK` | Message shown in Uptime Kuma |
| `KUMA_TIMEOUT` | `10` | Per-request timeout, seconds |
| `KUMA_INTERVAL` | `60` | Seconds between heartbeats, minimum `10` |

Command line: `kuma-heartbeat [--config FILE] [--check-config] [--help] [--version]`.
Exit codes: `0` ok, `1` push failed, `2` configuration problem.

**`KUMA_INTERVAL` on systemd:** a systemd timer cannot read the config file,
so it fires every minute and the script skips the run when less than
`KUMA_INTERVAL − 15` s have passed since the last one. The effective minimum
on Debian/Ubuntu is therefore 60 s (smaller values behave like 60), and larger
values (120, 300, …) work in one-minute steps. On Termux any value ≥ 10 works
and edits apply without restarting. Running `kuma-heartbeat` by hand always
sends immediately.

## Debian / Ubuntu

```sh
curl -LO https://github.com/swrh/kuma-heartbeat/releases/latest/download/kuma-heartbeat_<version>_amd64.deb
sudo apt install ./kuma-heartbeat_<version>_amd64.deb
```

Use `arm64` on ARM and the full version (e.g. `0.1.0-1`) for `<version>`. Then:

```sh
sudoedit /etc/kuma-heartbeat/kuma-heartbeat.conf      # set KUMA_HOST and KUMA_TOKEN
sudo systemctl enable --now kuma-heartbeat.timer
```

The timer is enabled and started automatically only if the config is already
filled in when the package is installed (otherwise the maintainer script tells
you what to do). The service is skipped, not failed, while the config is
incomplete. Check it with `systemctl list-timers kuma-heartbeat.timer` and
`journalctl -u kuma-heartbeat`.

The service runs as a systemd `DynamicUser` with a locked-down sandbox; the
root-only config is handed over with `LoadCredential=` (needs systemd ≥ 247:
Debian 12+, Ubuntu 22.04+; the script finds it via `$CREDENTIALS_DIRECTORY`). `apt remove` keeps the config, `apt purge` deletes it.

## Termux (Android)

```sh
pkg install termux-services curl
curl -LO https://github.com/swrh/kuma-heartbeat/releases/latest/download/kuma-heartbeat-termux_<version>_aarch64.deb
apt install ./kuma-heartbeat-termux_<version>_aarch64.deb      # x86_64 on x86 devices/emulators
nano $PREFIX/etc/kuma-heartbeat/kuma-heartbeat.conf            # set KUMA_HOST and KUMA_TOKEN
sv-enable kuma-heartbeat
```

Restart Termux once after installing `termux-services` for the first time so
`runsvdir` starts. Logs: `$PREFIX/var/log/sv/kuma-heartbeat/current`; status:
`sv status kuma-heartbeat`; stop: `sv-disable kuma-heartbeat`.

For Android to keep it running:

- Run `termux-wake-lock` (or enable "Acquire wakelock" in the Termux
  notification).
- Disable battery optimisation for Termux (and Termux:Boot) in Android settings.
- To start at boot, install **Termux:Boot** and create
  `~/.termux/boot/kuma-heartbeat`:

  ```sh
  #!/data/data/com.termux/files/usr/bin/sh
  termux-wake-lock
  . "$PREFIX/etc/profile.d/start-services.sh"
  ```

**Why runit and not cron?** The service is a `sleep` loop under
`termux-services`' runit: supervised, restarted on crash, logged, and needs no
extra daemon. If you prefer cron, `pkg install cronie`, run `crond`, skip
`sv-enable`, and add `* * * * * kuma-heartbeat` to `crontab -e`. `cronie` is
not a hard dependency for that reason.

## Architectures and file names

| Release file | Platform |
| --- | --- |
| `kuma-heartbeat_<ver>_amd64.deb`, `_arm64.deb` | Debian/Ubuntu |
| `kuma-heartbeat-termux_<ver>_x86_64.deb`, `_aarch64.deb` | Termux (its dpkg calls them `x86_64` / `aarch64`) |

The script is architecture-independent. Per-arch packages are a deliberate
choice for unambiguous downloads (and Termux 32-bit `arm`/`i686` is not
published). Inside Termux the package is still named `kuma-heartbeat`.

## Versioning and release

Tags are `vX.Y.Z`; package versions are `X.Y.Z-N` (`N` = packaging revision),
release tags `vX.Y.Z-N`. Release with:

```sh
git tag v0.1.0 && git push --tags
```

`release.yml` builds, tests, and publishes. `workflow_dispatch` can re-publish
a version with a new revision.

## Development

- `scripts/build-deb.sh <version> <arch> [revision] [debian|termux]` – needs
  only Docker (runs `dpkg-deb` in `debian:13`).
- `scripts/test-deb.sh <deb> <version>` – run as root in a Debian/Ubuntu
  container with the repo mounted; includes functional tests against
  `scripts/stub-server.py`.
- `scripts/test-termux.sh <deb> <version>` – run in `termux/termux-docker`.
- `ci.yml` runs shellcheck, yamllint, and the same build and tests on every
  push/PR.

### What is tested

| Environment | Where |
| --- | --- |
| Debian 12/13, Ubuntu 24.04, arm64 and amd64 (emulated) | locally and in CI |
| Ubuntu 22.04/26.04 | CI only |
| Termux (`termux-docker`) aarch64 and x86_64, including a real runit service | locally and in CI |
| Real systemd: timer firing, `DynamicUser`/`LoadCredential` | **not tested** (containers run without systemd as PID 1); units are checked with `systemd-analyze verify` only |
| Real Android device, Termux:Boot, battery optimisation | **not tested** |

## License

[MIT](./LICENSE) — Copyright (c) 2026 Fernando Silveira.
