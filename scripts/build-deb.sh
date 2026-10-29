#!/usr/bin/env bash
# Build a .deb package for kuma-heartbeat.
#
# Usage: build-deb.sh <version> [package_revision] [target]
#   <version>           upstream tag, e.g. v0.1.0
#   [package_revision]  our packaging revision for this upstream version
#                        (Debian "debian_revision" convention). Defaults to 1.
#   [target]            debian (default) | termux
#
# Output (in dist/):
#   debian: kuma-heartbeat_<ver>_all.deb
#   termux: kuma-heartbeat-termux_<ver>_all.deb
#           (the package itself is still called kuma-heartbeat inside)
# Both are architecture-independent: the payload is a shell script.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <version> [package_revision] [target]" >&2
  exit 1
fi

version="$1"
package_revision="${2:-1}"
target="${3:-debian}"
deb_arch=all

# Image used only to run dpkg-deb so package building is reproducible
# regardless of host OS (this script is expected to work from macOS too).
build_image="${BUILD_IMAGE:-debian:13}"

case "$target" in
  debian) file_prefix="kuma-heartbeat" ;;
  termux) file_prefix="kuma-heartbeat-termux" ;;
  *)
    echo "Unsupported target: $target (expected debian or termux)" >&2
    exit 1
    ;;
esac

version_number="${version#v}"
deb_version="${version_number}-${package_revision}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Building package root for kuma-heartbeat ${deb_version} (${target}, ${deb_arch})"
pkgroot="$work_dir/pkgroot"

if [[ "$target" == termux ]]; then
  prefix_rel="data/data/com.termux/files/usr"
  prefix="/$prefix_rel"
  sh_path="$prefix/bin/sh"
else
  prefix_rel="usr"
  prefix=""
  sh_path="/bin/sh"
fi

bin_dir="$pkgroot/$prefix_rel/bin"
doc_dir="$pkgroot/$prefix_rel/share/doc/kuma-heartbeat"
if [[ "$target" == termux ]]; then
  conf_dir="$pkgroot/$prefix_rel/etc/kuma-heartbeat"
  conf_path="$prefix/etc/kuma-heartbeat/kuma-heartbeat.conf"
else
  conf_dir="$pkgroot/etc/kuma-heartbeat"
  conf_path="/etc/kuma-heartbeat/kuma-heartbeat.conf"
fi
mkdir -p "$bin_dir" "$conf_dir" "$doc_dir"

# Script: version placeholder, shebang and (Termux) path prefix.
sed -e "s|__VERSION__|${deb_version}|g" \
    -e "1s|.*|#!${sh_path}|" \
    -e "s|^PKG_PREFIX=\"\"\$|PKG_PREFIX=\"${prefix}\"|" \
    "$repo_root/kuma-heartbeat.sh" > "$bin_dir/kuma-heartbeat"
chmod 755 "$bin_dir/kuma-heartbeat"

# The shipped config is the example with empty host/token; owner-only
# because it will hold the push token.
cp "$repo_root/kuma-heartbeat.conf.example" "$conf_dir/kuma-heartbeat.conf"
chmod 600 "$conf_dir/kuma-heartbeat.conf"
cp "$repo_root/kuma-heartbeat.conf.example" "$doc_dir/kuma-heartbeat.conf.example"
cp "$repo_root/debian/copyright" "$doc_dir/copyright"

if [[ "$target" == debian ]]; then
  mkdir -p "$pkgroot/lib/systemd/system"
  cp "$repo_root/kuma-heartbeat.service" "$repo_root/kuma-heartbeat.timer" \
     "$pkgroot/lib/systemd/system/"
  chmod 644 "$pkgroot/lib/systemd/system/"kuma-heartbeat.*
else
  svc="$pkgroot/$prefix_rel/var/service/kuma-heartbeat"
  mkdir -p "$svc/log"
  cp "$repo_root/debian/termux-service-run" "$svc/run"
  cp "$repo_root/debian/termux-service-log-run" "$svc/log/run"
  chmod 755 "$svc/run" "$svc/log/run"
  # The "down" file is not shipped: termux-postinst creates it on a fresh
  # install only, so upgrades never change whether the service is enabled.
fi

changelog="$work_dir/changelog.Debian"
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__UPSTREAM_TAG__/${version}/g" \
    -e "s/__ARCH__/${deb_arch}/g" \
    -e "s/__DATE__/$(date -R)/g" \
    "$repo_root/debian/changelog.template" > "$changelog"
gzip -9n -c "$changelog" > "$doc_dir/changelog.Debian.gz"

chmod 644 "$doc_dir"/*
find "$pkgroot" -type d -exec chmod 755 {} +

installed_size="$(du -sk "$pkgroot" | cut -f1)"

echo "Writing control files"
mkdir -p "$pkgroot/DEBIAN"
if [[ "$target" == termux ]]; then
  control_template="$repo_root/debian/control-termux.template"
  for s in postinst prerm postrm; do
    cp "$repo_root/debian/termux-$s" "$pkgroot/DEBIAN/$s"
    chmod 755 "$pkgroot/DEBIAN/$s"
  done
else
  control_template="$repo_root/debian/control.template"
  for s in postinst prerm postrm; do
    cp "$repo_root/debian/$s" "$pkgroot/DEBIAN/$s"
    chmod 755 "$pkgroot/DEBIAN/$s"
  done
fi
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__ARCH__/${deb_arch}/g" \
    -e "s/__INSTALLED_SIZE__/${installed_size}/g" \
    "$control_template" > "$pkgroot/DEBIAN/control"
echo "$conf_path" > "$pkgroot/DEBIAN/conffiles"

deb_name="${file_prefix}_${deb_version}_${deb_arch}.deb"

echo "Building ${deb_name} inside ${build_image}"
docker run --rm \
  -v "$work_dir:/work" \
  "$build_image" \
  dpkg-deb --root-owner-group --build /work/pkgroot "/work/${deb_name}"

mkdir -p "$dist_dir"
cp "$work_dir/$deb_name" "$dist_dir/$deb_name"

echo "Done: ${dist_dir}/${deb_name}"
