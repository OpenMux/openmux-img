#!/usr/bin/env bash
# build.sh - the single OpenMux image build entry point (runs OUTSIDE docker).
#
# Builds both images from source with rpi-image-gen inside a reproducible
# Docker container:
#   - the TARGET image (openmux-cm5)  - account settings come from the
#     customer build spec (./build.sh --buildspec my.yaml)
#   - the install medium (openmux-install-medium-cm5) - the fixed factory
#     appliance (root, blank pw, boot menu, embedded target image)
#
# Everything that touches the images runs inside the container; this script
# only (1) builds the docker image if needed, (2) runs entry.sh inside it
# with the repo mounted at /src (+ the build spec), and (3) prints hints.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------- defaults ------------------------------------
BUILDSPEC=""
REPO_URI=""
REPO_GPG=""
TARGET_IMAGE=""
SKIP_TARGET=0
SKIP_MEDIUM=0
RIG_REF="${RPI_IMAGE_GEN_REF:-}"
DOCKER_IMAGE="${OPENMUX_BUILD_IMAGE:-openmux/img:latest}"
FORCE_DOCKER=0
GENPASSWD=""
OUT="$REPO_ROOT/dist"
DOCKERCMD="${DOCKER:-docker}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./build.sh --buildspec <file> [options]

Options:
  --buildspec <file>   Customer build spec (YAML), REQUIRED for a target build.
                       Copy buildspec.example.yaml and fill it in: `admin-user`
                       (primary account), optional `users` list, optional
                       `post_install`. The file is git-ignored; never commit it.
  --repo-uri <uri>     OpenMux APT repo URI substituted into the target repo.
  --repo-gpg <file>    ASCII-armoured GPG key for a signed repo (copied in).
  --target-image <p>   Embed an existing target .img/.img.xz instead of building
                       one (with or without --skip-target).
  --skip-target        Skip the target image build (requires --target-image).
  --skip-install-medium Skip the install medium build.
  --rig-ref <ref>      Pin a different rpi-image-gen commit in the Dockerfile.
  --docker-image <t>   Build image name/tag (default: openmux/img:latest).
  --force-docker       Rebuild the docker image even if it already exists.
  --genpasswd <pass>   Print an SHA-512 hash (usable as `password_hash`), exit.
  --out <dir>          Artefact output dir (default: ./dist).
  -h, --help           This help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --buildspec)            BUILDSPEC="$2"; shift 2 ;;
    --repo-uri)             REPO_URI="$2"; shift 2 ;;
    --repo-gpg)             REPO_GPG="$2"; shift 2 ;;
    --target-image)         TARGET_IMAGE="$2"; shift 2 ;;
    --skip-target)          SKIP_TARGET=1; shift ;;
    --skip-install-medium)  SKIP_MEDIUM=1; shift ;;
    --rig-ref)              RIG_REF="$2"; shift 2 ;;
    --docker-image)         DOCKER_IMAGE="$2"; shift 2 ;;
    --force-docker)         FORCE_DOCKER=1; shift ;;
    --genpasswd)            GENPASSWD="$2"; shift 2 ;;
    --out)                  OUT="$2"; shift 2 ;;
    -h|--help)              usage; exit 0 ;;
    *)                      usage; die "unknown argument: $1" ;;
  esac
done

# --------------------------------- --genpasswd -----------------------------
# Helper for `password_hash` fields: SHA-512 crypt hash, then exit.
if [ -n "$GENPASSWD" ]; then
  command -v openssl >/dev/null 2>&1 || die "openssl is required for --genpasswd"
  openssl passwd -6 "$GENPASSWD"
  exit 0
fi

# ---------------------------------- validation -----------------------------
command -v "$DOCKERCMD" >/dev/null 2>&1 || die "docker (or \$DOCKER) is required"

# A target build needs a buildspec unless it is fully skipped.
if [ "$SKIP_TARGET" -eq 1 ]; then
  [ -n "$TARGET_IMAGE" ] || die "--skip-target requires --target-image <path>"
  [ -f "$TARGET_IMAGE" ] || die "--target-image not found: $TARGET_IMAGE"
  # No buildspec needed when only the medium is produced.
else
  [ -n "$BUILDSPEC" ] || die "a target build requires --buildspec <file> (see buildspec.example.yaml)"
  [ -f "$BUILDSPEC" ] || die "buildspec not found: $BUILDSPEC"
  # Mount the spec file's DIRECTORY (read-only), not the bare file: key_file / 
  # post_install are resolved relative to the spec's own directory, so their
  # companion files (keys/, scripts/ ...) must be available in-container too.
  BUILDSPEC_DIR="$(cd "$(dirname "$BUILDSPEC")" && pwd)"
  BUILDSPEC_NAME="$(basename "$BUILDSPEC")"
  BUILDSPEC_IN=/om/spec/$BUILDSPEC_NAME
fi

[ -z "$REPO_GPG" ] || { [ -f "$REPO_GPG" ] || die "--repo-gpg not found: $REPO_GPG"; }

# ------------------------------- repo GPG key ------------------------------
# Staged into the repo layer's sources dir (git-ignored). The openmux-repo
# layer ships the openmux.sources template + this key into the image.
if [ -n "$REPO_GPG" ]; then
  cp -f "$REPO_GPG" "$REPO_ROOT/layer/openmux-repo/sources/openmux.gpg"
  echo ">> repo GPG key staged: layer/openmux-repo/sources/openmux.gpg"
fi

# -------------------------------- docker image -----------------------------
build_docker_image() {
  echo ">> building docker image '$DOCKER_IMAGE' (first time / --force-docker; slow)"
  local args=()
  [ -n "$RIG_REF" ] && args+=("--build-arg" "RPI_IMAGE_GEN_REF=$RIG_REF")
  "$DOCKERCMD" build "${args[@]+"${args[@]}"}" -t "$DOCKER_IMAGE" "$REPO_ROOT"
}

if [ "$FORCE_DOCKER" -eq 1 ] || \
   ! "$DOCKERCMD" image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  [ -f "$REPO_ROOT/Dockerfile" ] || die "Dockerfile not found: $REPO_ROOT/Dockerfile"
  build_docker_image
else
  echo ">> reusing existing docker image '$DOCKER_IMAGE' (use --force-docker to rebuild)"
fi

# ---------------------------------- run build ------------------------------
# The repo root is mounted at /src. The build spec (when present) is mounted
# read-only at /om/buildspec.yaml so its credentials never travel on argv or
# env - they enter the container as one mounted file the parser reads.
# key_file / post_install paths from it are relative to the build spec's own
# directory and are resolved by entry.sh/build/parse-buildspec.py. When the
# spec is mounted at /om/buildspec.yaml, its companion files (keys/, scripts/
# ...) are NOT inside the image - see buildspec.example.yaml: mount the whole
# spec DIR (not a single file) if you use key_file / post_install.
echo ">> container: $DOCKER_IMAGE"
# TARGET_IMAGE: mount its parent dir read-only at /om/target and point the
# in-container var at the mounted copy.
TIMAGE_ARG=()
if [ -n "$TARGET_IMAGE" ]; then
  TIMAGE_ARG=(-v "$(dirname "$TARGET_IMAGE")":/om/target:ro \
              -e TARGET_IMAGE=/om/target/$(basename "$TARGET_IMAGE"))
fi

"$DOCKERCMD" run --rm --privileged \
  -e SRC=/src \
  -e BUILDSPEC="${BUILDSPEC_IN:-/om/buildspec.yaml}" \
  -e SKIP_TARGET="$SKIP_TARGET" \
  -e SKIP_MEDIUM="$SKIP_MEDIUM" \
  -e REPO_URI="$REPO_URI" \
  -v "$REPO_ROOT":/src \
  -v "$OUT":/src/dist \
  ${BUILDSPEC:+-v "$BUILDSPEC_DIR":/om/spec:ro} \
  ${TIMAGE_ARG[@]+"${TIMAGE_ARG[@]}"} \
  -w /src \
  "$DOCKER_IMAGE" \
  bash -lc "cd /src && bash build/entry.sh"

# --------------------------------- print out --------------------------------
echo
echo "Artefacts in: $OUT"
ls -lh "$OUT" 2>/dev/null | sed 's/^/  /' || true
echo
echo "Next steps:"
echo "  1. Flash the INSTALL MEDIUM to a USB stick, boot the CM5 from it."
echo "  2. Headless? Serial console 115200 8N1 on the CM5 UART (ttyAMA0)."
echo "     The factory menu autologins as root; option 1 writes the target"
echo "     image to eMMC."
echo "  3. After install + reboot, the target's accounts (from your buildspec)"
echo "     can log in on serial and/or SSH (password and/or key per your spec)."
