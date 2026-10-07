#!/usr/bin/env bash
# make-deb.sh - build the local OpenMux .deb packages from package/<name>/ trees.
#
# Usage: make-deb.sh [out-dir]
# Default out-dir: dist/pkgs
#
# Each package/<name>/ is a standard Debian binary package tree: a file tree
# rooted at the package root plus a DEBIAN/ control dir (control, conffiles,
# maintainer scripts). We build with --root-owner-group so the debs install
# into the chroot without needing fakeroot.

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/dist/pkgs}"

command -v dpkg-deb >/dev/null 2>&1 || { echo "ERROR: dpkg-deb is required" >&2; exit 1; }

mkdir -p "$OUT"

for src in "$REPO_ROOT"/package/*/; do
    name="$(basename "$src")"
    tree="${src%/}"
    [ -f "$tree/DEBIAN/control" ] || { echo "ERROR: $tree has no DEBIAN/control; skipping" >&2; continue; }

    version="$(sed -n 's/^Version:[[:space:]]*//p' "$tree/DEBIAN/control" | head -n1)"
    arch="$(sed -n 's/^Architecture:[[:space:]]*//p' "$tree/DEBIAN/control" | head -n1)"
    [ -n "$version" ] && [ -n "$arch" ] || { echo "ERROR: $tree DEBIAN/control missing Version/Architecture" >&2; exit 1; }

    dest="$OUT/${name}_${version}_${arch}.deb"
    echo ">> building $name $version ($arch)"
    dpkg-deb --build --root-owner-group -z9 --uniform-compression "$tree" "$dest"

    # Sanity + separation check for the install menu: it must carry the menu
    # script only - no autologin drop-ins, no /root/.bash_profile, no unit
    # enablement (those live in the openmux-install-medium layer).
    if [ "$name" = openmux-install-menu ]; then
        content="$(dpkg-deb --contents "$dest" | awk '{print $NF}')"
        bad="$(printf '%s\n' "$content" | grep -E 'autologin|\.bash_profile|systemd' || true)"
        if [ -n "$bad" ]; then
            echo "ERROR: openmux-install-menu contains factory/autologin content (must stay neutral):" >&2
            printf '%s\n' "$bad" >&2
            exit 1
        fi
    fi
done

echo ">> debs in $OUT"