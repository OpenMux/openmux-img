#!/bin/bash
# entry.sh - OpenMux build entry point, runs INSIDE the build container.
#
# Called by /build.sh (outside) after the repo is mounted at /src and the
# customer build spec (when this is a target build) at /om/buildspec.yaml.
#
# Flow:
#   1. build the 3 local debs
#   2. binfmt (arm64 target on amd64 host; no-op on arm64)
#   3. parse the build spec -> IGconf_* overrides (+ generated users hook,
#      and the materialized post_install hook in the source-tree hooks dir)
#   4. build the target image  (rpi-image-gen build -c config/openmux-cm5.yaml)
#   5. xz the target image
#   6. build the install medium (embeds the target; no build spec)
#   7. collect the artefacts
#
# Env (set by build.sh):
#   SRC            repo root in the container (default /src)
#   BUILDSPEC      customer build spec path (default /om/buildspec.yaml)
#   SKIP_TARGET    1 -> skip the target build (then --target-image must be
#                  provided via TARGET_IMAGE)
#   SKIP_MEDIUM    1 -> skip the install medium build
#   TARGET_IMAGE   path to a pre-built target .img or .img.xz to embed
#                  instead of building one
#   REPO_URI       optional OpenMux APT repo URI (target repo layer)

set -euo pipefail

SRC="${SRC:-/src}"
BUILDSPEC="${BUILDSPEC:-/om/buildspec.yaml}"
TARGET_IMAGE="${TARGET_IMAGE:-}"
SKIPPED_TARGET="${SKIP_TARGET:-0}"
SKIPPED_MEDIUM="${SKIP_MEDIUM:-0}"
REPO_URI="${REPO_URI:-}"

cd "$SRC"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

echo "=============================================================="
echo " OpenMux image build (container)"
echo " source root: $SRC"
echo "=============================================================="

# ------------------------------------------------------------- 1. debs
echo
echo ">> [1/5] building local debs -> dist/pkgs"
bash build/make-deb.sh

# ---------------------------------------------------- 2. binfmt (cross)
echo
echo ">> [2/5] cross-build binfmt (no-op on arm64)"
if [ "$(uname -m)" != "aarch64" ]; then
    # Building an arm64 chroot from an amd64 host: mmdebstrap runs the chroot
    # commands via qemu-user-static, which must be registered in binfmt_misc.
    # The container is --privileged so we can mount it if the host didn't.
    if ! mountpoint -q /sys/fs/binfmt_misc 2>/dev/null; then
        mkdir -p /sys/fs/binfmt_misc
        mount -t binfmt_misc binfmt_misc /sys/fs/binfmt_misc 2>/dev/null ||
            echo "NOTE: could not mount binfmt_misc (continuing)"
    fi
    # Register qemu-aarch64 (idempotent) via binfmt-support if present, else
    # write the binfmt_misc entry directly.
    # binfmt_misc lives in /sys - make sure the handler is registered (it is
    # set up at qemu-user-static install time, but a container may need it
    # re-registered at runtime under --privileged).
    if [ -e /sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "      qemu-aarch64 binfmt already registered"
    elif command -v update-binfmts >/dev/null 2>&1 && update-binfmts --enable qemu-aarch64 2>/dev/null; then
        echo "      qemu-aarch64 binfmt registered (update-binfmts)"
    elif printf ':qemu-aarch64:M:::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x64\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static' > /sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        echo "      qemu-aarch64 binfmt registered (direct)"
    else
        echo "WARNING: no qemu-aarch64 binfmt handler; the arm64 build will likely fail." >&2
    fi
fi

# -------------------------------------------- 3. build spec -> overrides
OVERRIDES_ARGS=()
GENERATED_HOOKS=()

build_target() {
    [ -f "$BUILDSPEC" ] || \
        die "target build requires a build spec (BUILDSPEC=$BUILDSPEC, set by build.sh)"

    echo
    echo ">> [3/5] parsing build spec: $BUILDSPEC"
    local parse_out="$SRC/work/buildspec"
    # Fresh every build: a stale overrides.env, generated hook or key file from
    # a PREVIOUS (customer) spec must never leak into this one.
    rm -rf "$parse_out"
    mkdir -p "$parse_out/hooks"
    # key_file / post_install are customer paths, resolved relative to the
    # build spec's own directory; the ABS path emitted into overrides.env is
    # the one valid inside the container (the buildspec is mounted read-only
    # at $BUILDSPEC, so its files live next to it and survive into the build).
    # --repo-uri (optional) is forwarded only when set.
    if [ -n "$REPO_URI" ]; then
        python3 build/parse-buildspec.py "$BUILDSPEC" "$parse_out" --repo-uri "$REPO_URI"
    else
        python3 build/parse-buildspec.py "$BUILDSPEC" "$parse_out"
    fi

    # admin-user had no password or hash -> the account will be LOCKED.
    # Allowed (key-only setups) but warned about.
    if ! grep -q '^IGconf_device_user1pass=' "$parse_out/overrides.env" && \
       ! grep -q '^IGconf_device_user1passhash=' "$parse_out/overrides.env"; then
        echo "WARNING: the build spec has no admin-user password (or hash) - the" \
             "primary account will be LOCKED (no password login). SSH keys in the" \
             "spec, or on-device setup, will be the only way in." >&2
    fi

    # Inline keys are materialized to $parse_out/keys/<name>.pub and the
    # override carries that PATH. If the file were missing, the generator's
    # ssh hook would take its [ -f ] test as false and fall through to the
    # echo branch, writing the PATH STRING into authorized_keys - silently
    # broken SSH. Check instead of shipping a bad image.
    ssh_line="$(grep -m1 '^IGconf_ssh_pubkey_user1=' "$parse_out/overrides.env" || true)"
    ssh_key="${ssh_line#IGconf_ssh_pubkey_user1=}"
    ssh_key="${ssh_key#\'}"; ssh_key="${ssh_key%\'}"
    case "$ssh_key" in
        "$parse_out"/keys/*)
            [ -f "$ssh_key" ] || die "generated key file is missing: $ssh_key"
            echo ">> admin SSH key file: $ssh_key ($(wc -l < "$ssh_key") key(s))"
            ;;
    esac

    # Overrides as KEY=VALUE args (secrets never reach argv beyond these vars;
    # they are parsed here from the mounted file, exactly per the plan).
    mapfile -t OVERRIDES_ARGS < "$parse_out/overrides.env"

    # Generated users hook -> source-tree hooks dir (auto-discovered as a
    # customize hook by rpi-image-gen, see bin/runner: SRCROOT:hooks).
    if [ -f "$parse_out/hooks/customize94-openmux-users" ]; then
        install -m 0755 "$parse_out/hooks/customize94-openmux-users" \
            "$SRC/hooks/customize94-openmux-users"
        GENERATED_HOOKS+=("customize94-openmux-users")
    fi

    # post_install -> materialized as a source-tree customize hook (runs after
    # all layer hooks AND after the users hook, before genimage writes the
    # image).
    post="$(python3 - "$BUILDSPEC" <<'PY'
import os, sys, yaml
spec_path = sys.argv[1]
spec = yaml.safe_load(open(spec_path, encoding="utf-8")) or {}
post = (spec.get("post_install") or "").strip()
if post and not os.path.isabs(post):
    # post_install is relative to the BUILD SPEC's directory (the customer's
    # scripts live next to the spec), not the repo root.
    post = os.path.join(os.path.dirname(os.path.abspath(spec_path)), post)
print(post)
PY
)"
    if [ -n "$post" ]; then
        [ -f "$post" ] || die "post_install script not found: $post (relative to the build spec's directory)"
        install -m 0755 "$post" "$SRC/hooks/customize95-openmux-postinstall"
        GENERATED_HOOKS+=("customize95-openmux-postinstall")
        echo ">> post_install hook: hooks/customize95-openmux-postinstall (from $(basename "$post"))"
    fi
}

# ---------------------------------------------------------- 4. target build
if [ "$SKIPPED_TARGET" = "1" ]; then
    [ -n "$TARGET_IMAGE" ] || die "SKIP_TARGET=1 requires TARGET_IMAGE"
    [ -f "$TARGET_IMAGE" ] || die "TARGET_IMAGE not found: $TARGET_IMAGE"
    echo ">> [4/5] skipping target build; using provided $TARGET_IMAGE"
    TART="$(basename "$TARGET_IMAGE")"
    cp -f "$TARGET_IMAGE" "$SRC/dist/$TART"
    case "$TART" in
        *.xz) TARGET_XZ="$SRC/dist/$TART" ;;
        # NO -c: that would stream the compressed bytes to STDOUT (see
        # below); xz <file> writes <file>.xz, -k keeps the original,
        # -f overwrites any existing <file>.xz from a previous run (the
        # dist/ artefact is a normal build output, safe to replace).
        *)    TARGET_XZ="$SRC/dist/$TART.xz"; xz -T0 -6 -kf "$SRC/dist/$TART" ;;
    esac
else
    build_target
    echo
    echo ">> [4/5] building TARGET image (config/openmux-cm5.yaml)"
    rpi-image-gen build -S "$SRC" -c "$SRC/config/openmux-cm5.yaml" \
        -- "${OVERRIDES_ARGS[@]}"

    # Locate the produced image (work/image-<name>/<name>.img).
    TGT_IMG="$(find "$SRC/work" -name 'openmux-cm5.img' -type f 2>/dev/null | head -n1 || true)"
    [ -n "$TGT_IMG" ] || die "target image not found under $SRC/work (build failed?)"
    echo "      target image: $TGT_IMG"
    # NO -c (which would stream to STDOUT and never create the file):
    # xz <img> writes <img>.xz, -k keeps the original .img, -f overwrites
    # <img>.xz if a previous run already left one in work/ (work/ persists
    # across builds; refusing to overwrite is the default which would kill
    # the whole build with 'File exists').
    TARGET_XZ="$TGT_IMG.xz"
    xz -T0 -6 -kf "$TGT_IMG"
fi

# ------------------------------------------------------ 5. install medium
if [ "$SKIPPED_MEDIUM" = "1" ]; then
    echo ">> [5/5] skipping install medium build"
else
    echo
    echo ">> [5/5] building INSTALL MEDIUM (config/openmux-install-medium.yaml)"
    rpi-image-gen build -S "$SRC" -c "$SRC/config/openmux-install-medium.yaml" \
        -- "IGconf_om_target_image=$TARGET_XZ"
    MED_IMG="$(find "$SRC/work" -name 'openmux-install-medium-cm5.img' -type f 2>/dev/null | head -n1 || true)"
    [ -n "$MED_IMG" ] && [ -f "$MED_IMG" ] || die "install medium image not found under $SRC/work"
    echo "      install medium: $MED_IMG"
fi

# ------------------------------------------------------------ 6. artefacts
DIST="$SRC/dist"
mkdir -p "$DIST"
[ -f "$TARGET_XZ" ] && cp -f "$TARGET_XZ" "$DIST/" 2>/dev/null || true
MED_IMG="${MED_IMG:-}"
[ -n "$MED_IMG" ] && [ -f "$MED_IMG" ] && cp -f "$MED_IMG" "$DIST/" || true

# Remove materialized source-tree hooks (they are git-ignored regenerables).
for h in "${GENERATED_HOOKS[@]:-}"; do
    [ -n "$h" ] && rm -f "$SRC/hooks/$h"
done

# Remove the key file generated from inline build-spec keys (public keys only,
# and work/ is git-ignored - this only keeps out customer-specific material).
rm -rf "$SRC/work/buildspec/keys"

echo
echo "=============================================================="
echo " Done."
echo " Target image:        $DIST/$(basename "${TARGET_XZ:-<skipped>}")"
[ -n "${MED_IMG:-}" ] && echo " Install medium:      $DIST/$(basename "$MED_IMG")"
echo
echo " Flash the INSTALL MEDIUM to a USB stick and boot the CM5 from it"
echo " (screenless: serial console 115200 8N1 on /dev/ttyAMA0). Menu"
echo " option 1 writes the target image to eMMC."
echo "=============================================================="
