# kuma-heartbeat

POSIX `sh` script (`kuma-heartbeat.sh`) packaged as `.deb` for Debian/Ubuntu
(systemd timer) and Termux (runit service). See README.md for behaviour.

## Commands
- Lint: `shellcheck -s sh kuma-heartbeat.sh debian/postinst debian/prerm debian/postrm debian/termux-*; shellcheck scripts/*.sh`
- Build: `scripts/build-deb.sh v0.1.0 amd64 1 debian|termux` (Docker only)
- Test Debian: `docker run --rm -v "$PWD:/w" -w /w debian:13 ./scripts/test-deb.sh ./dist/kuma-heartbeat_0.1.0-1_arm64.deb 0.1.0`
- Test Termux: `docker run --rm -v "$PWD:/w" -w /w termux/termux-docker:aarch64 bash ./scripts/test-termux.sh ./dist/kuma-heartbeat-termux_0.1.0-1_aarch64.deb 0.1.0`
- yamllint is not installed locally: `docker run --rm -v "$PWD:/w" -w /w python:3-alpine sh -c 'pip install -q yamllint && yamllint .'`

## Pitfalls
- The Termux package rewrites the script's shebang and `PKG_PREFIX=""` at build time (sed in build-deb.sh); keep that line format.
- Termux names architectures `aarch64`/`x86_64`; `dpkg-deb` in debian:13 warns about `_` in x86_64 but builds fine.
- `sv-enable` needs `SVDIR` set (Termux login shells set it; tests export it).
- `ping=` is the previous push's round trip, because a request can't carry its own timing.
- Commits: English, Conventional Commits; work on the current branch.
