#!/bin/sh
# 50-openmux-repo.sh - configure the OpenMux APT repository inside the chroot.
#
# Invoked by the openmux-repo layer as:
#     sh 50-openmux-repo.sh <target-dir>
#
# Files expected next to this script (in sources/):
#   openmux.sources   - DEB822 repo definition, may reference ${OPENMUX_REPO_URI}
#   openmux.gpg       - ASCII-armoured public key for a signed repo (optional)
#
# The build system exports OPENMUX_REPO_URI (the build wrapper passes the
# customer value from the buildspec / --repo-uri). When it is empty the
# repository is NOT configured at all: no sources file, no key, no
# full-upgrade - the script only refreshes the base package lists, so a
# medium build without a customer repo stays clean.

set -eu

TARGET="$1"
REPO_URI="${OPENMUX_REPO_URI:-}"
SRC_DIR=$(dirname "$0")

if [ -n "$REPO_URI" ]; then
  echo "openmux-repo: configuring ${REPO_URI}"

  # --- Repo definition ------------------------------------------------------
  mkdir -p "$TARGET/etc/apt/sources.d"
  sed "s|\${OPENMUX_REPO_URI}|${REPO_URI}|g" \
    "$SRC_DIR/openmux.sources" > "$TARGET/etc/apt/sources.d/openmux.sources"
  chmod 0644 "$TARGET/etc/apt/sources.d/openmux.sources"

  # --- GPG key (only when a key is actually shipped) ------------------------
  # The repo definition (openmux.sources) references
  # /etc/apt/keyrings/openmux.gpg via Signed-By.
  if [ -f "$SRC_DIR/openmux.gpg" ]; then
    mkdir -p "$TARGET/etc/apt/keyrings"
    cp "$SRC_DIR/openmux.gpg" "$TARGET/etc/apt/keyrings/openmux.gpg"
    chmod 0644 "$TARGET/etc/apt/keyrings/openmux.gpg"
  else
    echo "openmux-repo: WARNING: repo configured but sources/openmux.gpg is" \
           "missing - if the repository is signed, apt will reject it." >&2
  fi

  # --- Upgrade against the new repo ------------------------------------------
  chroot "$TARGET" apt-get update
  DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get -y \
    --allow-unauthenticated=false full-upgrade
else
  echo "openmux-repo: no repo URI configured - skipping repository setup"
  chroot "$TARGET" apt-get update
fi
