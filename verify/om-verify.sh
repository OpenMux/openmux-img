#!/bin/bash
# om-verify.sh - post-build sanity checks for the OpenMux images in dist/.
#
# Runs INSIDE the build container with privileges (it needs loop devices to
# mount the partitions of the raw images):
#
#   docker run --rm --privileged \
#     -v $REPO_ROOT:/src:ro \
#     -v /path/to/buildspec-dir:/om/spec:ro \
#     openmux/img:latest bash -lc 'bash /src/verify/om-verify.sh'
#
# $SPEC is the build spec's directory (used to cross-check the admin SSH key
# from keys/admin.pub when the spec used key_file). The admin account is
# located dynamically as the uid-1000 user, so any buildspec works; the
# "qa1" expectations below match the fixture in /tmp/om-buildspec-test.
set -u

DIST="${DIST:-/src/dist}"
SPEC="${SPEC:-/om/spec}"
TART_XZ="$DIST/openmux-cm5.img.xz"
MED_IMG="$DIST/openmux-install-medium-cm5.img"

V=/tmp/ov; rm -rf "$V"; mkdir -p "$V/boot" "$V/root" "$V/mboot" "$V/mroot"
LOOPS=()
cleanup() {
  umount "$V/root" "$V/boot" "$V/mroot" "$V/mboot" 2>/dev/null
  for d in "${LOOPS[@]:-}"; do [ -n "$d" ] && losetup -d "$d" 2>/dev/null; done
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
chk() { # chk <desc> <file> <egrep pattern>
  # `--` terminates option parsing so a pattern that starts with '-' (e.g.
  # '--autologin root') is treated as a pattern, not a grep flag.
  if [ -f "$2" ] && grep -Eq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}
chk_not() { # chk_not <desc> <file> <egrep pattern>  (pass = NOT found)
  if [ -f "$2" ] && grep -Eq -- "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi
}

# --- loop devices (privileged container) ------------------------------------
# The container /dev may lack /dev/loopN node files the kernel has in /sys
# (losetup --find then fails with ENOENT), so pre-create the whole range and
# attach to an EXPLICIT device: `losetup -o OFF /dev/loopN FILE` (note:
# `losetup --show -o OFF FILE` without --find is rejected by util-linux).
[ -b /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null
for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i 2>/dev/null; done

# first partition start (bytes) for fdisk type <type> (c=fat32, 83=ext4...).
# sfdisk -d prints `start=       16384` (spaces after =) - awk strips them.
part_off() {
  sfdisk -d "$1" 2>/dev/null | awk -v tt="$2" '
    /start=/ {
      s=""; t=""
      if (match($0, /start=[ ]*[0-9]+/)) { s=substr($0,RSTART,RLENGTH); sub(/start=[ ]*/,"",s); s+=0 }
      if (match($0, /type=[0-9a-f]+/))   { t=substr($0,RSTART,RLENGTH); sub(/type=/,"",t) }
      if (t == tt) print s*512
    }' | head -n1
}

attach_off() { # attach_off <offset> <img>  -> prints /dev/loopN
  local off=$1 img=$2 n
  for n in $(seq 0 63); do
    if losetup -o "$off" "/dev/loop$n" "$img" 2>/dev/null; then
      echo "/dev/loop$n"; return 0
    fi
  done
  return 1
}

mount_img() { # mount_img <img> <c|83> <mountpoint>
  local off d
  off=$(part_off "$1" "$2")
  [ -n "$off" ] || { bad "partition (type $2) not found in $1"; return 1; }
  d=$(attach_off "$off" "$1") || { bad "losetup ($2) $1"; return 1; }
  LOOPS+=("$d")
  if [ "$2" = 83 ]; then mount -t ext4 -o ro "$d" "$3"
  else mount -t vfat -o ro "$d" "$3"; fi || { bad "mounting $2 partition of $1"; return 1; }
  ok "mounted $2 partition of $(basename "$1") via $d"
}

[ -f "$TART_XZ" ] || { echo "missing $TART_XZ"; exit 1; }
[ -f "$MED_IMG" ] || { echo "missing $MED_IMG"; exit 1; }

# ============================= TARGET IMAGE =================================
echo "== TARGET: $(basename "$TART_XZ") =="
xz -d -T0 -c "$TART_XZ" > "$V/t.img" || { echo "decompress target failed"; exit 1; }
mount_img "$V/t.img" c  "$V/boot" || true
mount_img "$V/t.img" 83 "$V/root" || true
R="$V/root"

# serial console configuration (openmux-serial-console layer).
# Boot vfat layout: firmware contents live at the PARTITION ROOT (no
# `firmware/` subdir) - genimage mcopy's the chroot's /boot/firmware/* onto
# the vfat root, so cmdline.txt / config.txt / kernel_* are directly under
# $V/boot. B points at that root.
B="$V/boot"
chk       "cmdline.txt: serial console present"  "$B/cmdline.txt" 'console=serial0,115200'
chk       "cmdline.txt: first console is serial" "$B/cmdline.txt" '^console=serial0,115200'
chk       "cmdline.txt: tty1 (VGA) console kept" "$B/cmdline.txt" 'console=tty1'
chk_not   "cmdline.txt: no stale root=ROOTDEV"   "$B/cmdline.txt" 'ROOTDEV'
chk_not   "cmdline.txt: single root= token"      "$B/cmdline.txt" 'root=.*root='
chk       "cmdline.txt: real root device"        "$B/cmdline.txt" 'root=/dev/disk/by-slot/system'
chk       "config.txt: enable_uart=1"            "$B/config.txt"  'enable_uart=1'
chk       "config.txt: dtparam=uart0=on"         "$B/config.txt"  'dtparam=uart0=on'
chk       "config.txt: dtparam=uart0_console=on" "$B/config.txt"  'dtparam=uart0_console=on'
ls "$V/boot" | grep -Eq 'kernel_[0-9]+\.img' && ok "kernel present in boot vfat" || bad "kernel missing in boot vfat"

# accounts (device-user-credentials + generated users hook)
admin=$(awk -F: '$3==1000 {print $1; exit}' "$R/etc/passwd")
[ -n "$admin" ] && ok "admin account present (uid 1000): $admin" || bad "no uid-1000 account"
[ -n "$admin" ] && \
  awk -F: -v u="$admin" '$1==u {print $3"-"$4}' "$R/etc/passwd" | grep -q '^1000-1000' \
  && ok "admin uid/gid = 1000:1000" || bad "admin uid/gid wrong (should be 1000:1000)"
grep -Eq "^${admin}:x:1000:" "$R/etc/group" 2>/dev/null && ok "admin group (gid 1000) exists" || bad "admin group missing"
chk   "admin password set (shadow hash)" "$R/etc/shadow" "^${admin}:[^:*!]"
chk   "root locked (no password)"        "$R/etc/shadow" '^root:\*'
chk   "admin sudo (passwd mode)"         "$R/etc/sudoers.d/010_rpi-passwd" "$admin .*ALL"
# additional-account checks (fixture: qa1; EXPECT_QA1=0 to skip)
if [ "${EXPECT_QA1:-1}" = "1" ]; then
chk   "qa1 account present"              "$R/etc/passwd" '^qa1:'
chk   "qa1 password set"                 "$R/etc/shadow" '^qa1:[^:*!]'
chk   "qa1 NOPASSWD sudoers"             "$R/etc/sudoers.d/openmux-qa1" 'qa1 .*NOPASSWD'
awk -F: '$1=="qa1" {exit !($3>=1000 && $3<65534)}' "$R/etc/passwd" \
  && ok "qa1 uid in user range" || bad "qa1 uid out of range"
chk   "qa1 member of sudo group" "$R/etc/group" '^sudo:.*qa1'
fi
chk   "admin member of adm group" "$R/etc/group" '^adm:.*'"$admin"

# SSH keys
[ -n "$admin" ] && {
  if [ -f "$SPEC/keys/admin.pub" ]; then
    k=$(head -n1 "$SPEC/keys/admin.pub")
    chk "admin authorized_keys matches key_file" \
      "$R/home/$admin/.ssh/authorized_keys" "^${k}"
  else
    k=""
    [ -s "$R/home/$admin/.ssh/authorized_keys" ] \
      && ok "admin authorized_keys non-empty" || bad "admin authorized_keys missing/empty"
  fi
  # numeric uid compare: the container's /etc/passwd lacks the image users,
  # so %U (name) resolves to a number - compare the uid (1000) instead.
  [ "$(stat -c '%u' "$R/home/$admin/.ssh/authorized_keys" 2>/dev/null)" = "1000" ] \
    && ok "admin .ssh owned by admin (uid 1000)" || bad "admin .ssh ownership wrong (want uid 1000)"
  [ "$(stat -c '%a' "$R/home/$admin/.ssh/authorized_keys")" = 600 ] \
    && ok "admin authorized_keys mode 600" || bad "admin authorized_keys mode"
}
# additional-account qa1 .ssh checks (fixture-specific; EXPECT_QA1=0 to skip)
if [ "${EXPECT_QA1:-1}" = "1" ]; then
[ -s "$R/home/qa1/.ssh/authorized_keys" ] \
  && ok "qa1 authorized_keys non-empty" || bad "qa1 authorized_keys missing/empty"
# qa1's uid/gid come from the image (useradd assigned 1001/1001 here)
qa1_owner=$(awk -F: '$1=="qa1" {print $3":"$4; exit}' "$R/etc/passwd")
[ "$(stat -c '%u:%g' "$R/home/qa1/.ssh/authorized_keys" 2>/dev/null)" = "$qa1_owner" ] \
  && ok "qa1 .ssh owned by qa1 ($qa1_owner)" || bad "qa1 .ssh ownership wrong (want $qa1_owner)"
fi
chk   "post_install marker /usr/local/openmux/marker.txt" "$R/usr/local/openmux/marker.txt" 'extra'

# packages (local debs from dist/pkgs via openmux-packages layer)
[ -f "$R/var/lib/dpkg/info/openmux-hardware.list" ] && ok "deb openmux-hardware installed" || bad "openmux-hardware missing"
[ -f "$R/var/lib/dpkg/info/openmux-factory-tools.list" ] && ok "deb openmux-factory-tools installed" || bad "openmux-factory-tools missing"
[ -x "$R/usr/bin/curl" ] && ok "distro package curl" || bad "curl missing"
[ -x "$R/usr/bin/git" ] && ok "distro package git" || bad "git missing"
[ -L "$R/etc/systemd/system/sysinit.target.wants/openmux-detect-hardware.service" ] \
  && ok "openmux-detect-hardware.service enabled" || bad "hw-detect service not enabled"
chk   "hostname" "$R/etc/hostname" '^openmux$'

umount "$V/root" "$V/boot" 2>/dev/null
for d in "${LOOPS[@]:-}"; do [ -n "$d" ] && losetup -d "$d" 2>/dev/null; done; LOOPS=()
rmdir "$V/root" "$V/boot" 2>/dev/null; mkdir -p "$V/root" "$V/boot"

# ============================== MEDIUM IMAGE ================================
echo "== INSTALL MEDIUM: $(basename "$MED_IMG") =="
mount_img "$MED_IMG" c  "$V/mboot" || true
mount_img "$MED_IMG" 83 "$V/mroot" || true
M="$V/mroot"

chk   "medium hostname" "$M/etc/hostname" '^openmux-install-medium$'
# passwd -d yields `root::` (empty field) followed by the remaining shadow
# fields (e.g. root::20733:0:99999:7:::), so the pattern must not be
# anchored at end-of-line.
chk   "root password BLANK (passwd -d)" "$M/etc/shadow" '^root::'
chk   "PAM nullok on tty (blank root login)" "$M/etc/pam.d/common-auth" 'pam_unix\.so .*nullok'
chk   "getty@tty1 autologin drop-in (menu)" "$M/etc/systemd/system/getty@tty1.service.d/autologin.conf" '--autologin root'
chk   "serial-getty autologin drop-in" "$M/etc/systemd/system/serial-getty@.service.d/autologin.conf" '--autologin root'
[ -L "$M/etc/systemd/system/getty.target.wants/getty@tty1.service" ] \
  && ok "getty@tty1.service enabled" || bad "getty@tty1 not enabled"
chk   "root .bash_profile execs the menu" "$M/root/.bash_profile" 'openmux-menu\.sh'
[ -x "$M/usr/local/sbin/openmux-menu.sh" ] && ok "openmux-menu.sh installed+exec" || bad "openmux-menu.sh missing"
[ -f "$M/var/lib/dpkg/info/openmux-install-menu.list" ] && ok "deb openmux-install-menu installed" || bad "install-menu missing"
[ -f "$M/var/lib/dpkg/info/overlayroot.list" ] && ok "overlayroot installed (menu option 9)" || bad "overlayroot missing"
# medium boot vfat also has contents at the partition root (no firmware/)
chk   "medium cmdline: first console is serial" "$V/mboot/cmdline.txt" '^console=serial0,115200'
chk   "medium cmdline: tty1 console kept"       "$V/mboot/cmdline.txt" 'console=tty1'
chk   "medium config.txt: dtparam=uart0 lines"  "$V/mboot/config.txt"  'dtparam=uart0_console=on'

# embedded target image must be the exact target artefact from dist/
EMB=$(ls "$M/opt/openmux-installer/images/" 2>/dev/null | head -n1)
if [ -n "$EMB" ] && [ -f "$M/opt/openmux-installer/images/$EMB" ]; then
  a=$(md5sum < "$M/opt/openmux-installer/images/$EMB" | cut -d' ' -f1)
  b=$(md5sum < "$TART_XZ" | cut -d' ' -f1)
  [ "$a" = "$b" ] && ok "embedded target image = dist target xz ($EMB)" \
                 || bad "embedded target image MISMATCH (md5 $a != $b)"
else
  bad "no embedded target image under /opt/openmux-installer/images"
fi

# ============================== SUMMARY =====================================
echo
echo "== RESULT: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
