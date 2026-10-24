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
# The LAST console= token is the one that becomes /dev/console, and the
# initramfs linuxrc plus PID 1 write only to /dev/console. Shipping the engine
# default "console=serial0 console=tty1" sent early boot (and the login prompt)
# to HDMI from the moment the initrd brought up a framebuffer, so the layer
# asserts serial-only: exactly one console= token, and it is the UART. The
# token COUNT is the load-bearing assertion - the defaults reappear whenever
# openmux-serial-console stops being planned after rpi-device-base (cmdline.d
# fragments are applied in plan order), and they are invisible to a
# "is console=serial0 present" check. See the layer header.
chk       "cmdline.txt: serial console present"  "$B/cmdline.txt" 'console=serial0,115200'
chk_not   "cmdline.txt: no console=tty1 (HDMI)"  "$B/cmdline.txt" 'console=tty1'
[ "$(grep -Eo 'console=[^ ]+' "$B/cmdline.txt" | wc -l)" -eq 1 ] \
  && ok "cmdline.txt: exactly one console= token" \
  || bad "cmdline.txt: $(grep -Eo 'console=[^ ]+' "$B/cmdline.txt" | wc -l) console= tokens, want 1 (serial only)"
chk_not   "cmdline.txt: no stale root=ROOTDEV"   "$B/cmdline.txt" 'ROOTDEV'
chk_not   "cmdline.txt: single root= token"      "$B/cmdline.txt" 'root=.*root='
# The target boots from eMMC (firmware boot-mode 1), so the by-slot symlinks DO
# exist here - unlike the USB medium, see the medium section below.
chk       "cmdline.txt: real root device"        "$B/cmdline.txt" 'root=/dev/disk/by-slot/system'
# fstab must agree, and must NOT reference PARTUUID: that is what lets the installer
# leave a freshly written disk's signature alone (openmux-menu.sh regenerate_disk_ids).
chk       "fstab root is by-slot/system"   "$R/etc/fstab" '^/dev/disk/by-slot/system[ ]+/'
chk       "fstab boot is by-slot/boot"     "$R/etc/fstab" '^/dev/disk/by-slot/boot[ ]+/boot/firmware'
chk_not   "fstab has no PARTUUID reference" "$R/etc/fstab" 'PARTUUID='
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

# first-boot filesystem extension (openmux-extend-filesystem layer, target only)
chk   "extend-filesystem script installed" "$R/usr/local/sbin/openmux-extend-filesystem.sh" 'growpart'
[ -x "$R/usr/local/sbin/openmux-extend-filesystem.sh" ] && ok "extend-filesystem script executable" || bad "extend-filesystem script not executable"
[ -f "$R/lib/systemd/system/openmux-extend-filesystem.service" ] && ok "extend-filesystem unit present" || bad "extend-filesystem unit missing"
[ -L "$R/etc/systemd/system/multi-user.target.wants/openmux-extend-filesystem.service" ] \
  && ok "extend-filesystem.service enabled" || bad "extend-filesystem not enabled"
[ -f "$R/var/lib/dpkg/info/cloud-guest-utils.list" ] && ok "deb cloud-guest-utils (growpart) installed" || bad "cloud-guest-utils missing"

# packages (local debs from dist/pkgs via openmux-packages layer)
[ -f "$R/var/lib/dpkg/info/openmux-hardware.list" ] && ok "deb openmux-hardware installed" || bad "openmux-hardware missing"
[ -f "$R/var/lib/dpkg/info/openmux-factory-tools.list" ] && ok "deb openmux-factory-tools installed" || bad "openmux-factory-tools missing"
# The flashers and the shell wrappers exec five programs: ftdi_eeprom, sudo,
# python3, bash and coreutils. bash/coreutils are Essential: yes and present by
# policy; the other three are Priority: optional, so only the deb's Depends can
# promise them, and a Depends that does not resolve fails the BUILD (apt non-zero
# + the set -eu hook) rather than shipping a broken image. Pinned at the artifact
# anyway: it is three stats, and it answers the question an operator actually has
# - can this image flash a card - independently of why the build succeeded.
for b in ftdi_eeprom sudo python3; do
  [ -x "$R/usr/bin/$b" ] && ok "$b present (tools can exec it)" \
    || bad "$b missing: flashers would refuse to run"
done
# The FTDI tools are the field-service path onto every unit, and the field-service
# story depends on one fact the console cannot be trusted to remember: the
# console's own FTDI chips stay on the bus while a card is being programmed. Pin
# the files, and run the shipped scanner here (it is pure stdlib, so the build
# host's python3 executes it fine even though these are aarch64 roots) against a
# tree that does not exist: it must answer, not crash and not need hardware.
FT="$R/opt/openmux-factory-tools"
for t in scan_ftdi.py scan-ftdi-adapters.py program-ftdi-internal.py \
         program-ftdi-external.py run-board-tests.sh serial-test.py; do
  [ -f "$FT/$t" ] && ok "factory tool $t" || bad "factory tool $t missing"
done
chk "scanner names the console guard"     "$FT/scan_ftdi.py" "console's own internal FTDI chip"
chk "flasher refuses a card's own hub"    "$FT/scan_ftdi.py" "program-ftdi-external.py for a card"
chk "audit derives ports from sysfs"      "$FT/scan_ftdi.py" "numbering_audit"
chk "runner prints the plug plan"         "$FT/run-board-tests.sh" "Loopback connections required"
chk "card profile crosses the chip seams" "$FT/run-board-tests.sh" "8:9,10:11,12:1"
if python3 "$FT/scan-ftdi-adapters.py" --devices-dir /nonexistent \
     --check-base OMX000042 >/dev/null 2>&1; then
  ok "shipped scanner runs and accepts a base"
else
  bad "shipped scanner refused to run (--check-base OMX000042)"
fi
# A dash is the one character a base must not contain: the rules and the hardware
# identity both split the serial at the first dash, so a base holding one makes
# ports nothing can name. Cheaper to refuse at the keyboard than to explain later.
if python3 "$FT/scan-ftdi-adapters.py" --devices-dir /nonexistent \
     --check-base 'OMX-1' >/dev/null 2>&1; then
  bad "scanner accepted a serial base containing a dash"
else
  ok "scanner refuses a dash in a serial base"
fi
# The serial prefix is MATCHED, not displayed, in three files that ship from two
# packages: the udev rules and the boot-time identity script (openmux-hardware),
# and the factory tools' default (openmux-factory-tools). They have to move in
# step, and nothing fails if they do not: the flash reports success, the chip
# re-enumerates with a serial no rule claims, and the unit simply has no
# /dev/openmux ports forever - which reads as a dead card, not as a wrong file.
# Each prefix is read out of the shipped file here, not repeated as a literal, so
# a file that stops matching the documented shape reports "could not read" rather
# than falsely confirming agreement.
RU="$R/etc/udev/rules.d/99-openmux-ftdi.rules"
HW="$R/usr/lib/openmux-hardware/openmux-detect-hardware.sh"
# The role is the shape of the symlink: the console's ports are flat
# (openmux/portN), a card's live in a folder named after its base (openmux/%c/...).
# grep -E, not BRE sed: the serial pattern in the rules is a udev glob whose
# literal "[0-9]*" BRE escaping gets wrong silently, and an empty result here is
# the one outcome this check must never confuse with agreement. Verified against
# the good file, the pre-migration file, a half-migrated file and /dev/null.
prefix_of() { # <file> <symlink shape> -> the serial prefixes on matching rules
  grep -E "$2" "$1" 2>/dev/null | grep -oE 'ATTRS\{serial\}=="[A-Z]+' | sed 's/.*"//' | sort -u
}
p_flat=$(prefix_of "$RU" 'SYMLINK\+="openmux/port[0-9]+"')
p_fold=$(prefix_of "$RU" 'SYMLINK\+="openmux/%c/port[0-9]+"')
p_hw=$(sed -n 's/^[[:space:]]*\([A-Z][A-Z]*\)\*-[AB]) found=.*/\1/p' "$HW" 2>/dev/null | sort -u)
p_int=$(sed -n 's/^PREFIX_INTERNAL_DEFAULT = "\([A-Z]*\)".*/\1/p' "$FT/scan_ftdi.py" 2>/dev/null)
p_ext=$(sed -n 's/^PREFIX_EXTERNAL_DEFAULT = "\([A-Z]*\)".*/\1/p' "$FT/scan_ftdi.py" 2>/dev/null)
if [[ "$p_flat" =~ ^[A-Z]+$ ]] && [[ "$p_fold" =~ ^[A-Z]+$ ]] && [[ "$p_hw" == "$p_flat" ]] \
   && [[ "$p_int" == "$p_flat" ]] && [[ "$p_ext" == "$p_fold" ]]; then
  ok "serial prefixes agree: rules $p_flat/$p_fold, hardware script, tools default"
else
  bad "serial prefixes DISAGREE (flashing a chip would leave it with no ports)"
  printf '        rules, ports flat  : [%s]\n' "${p_flat:-unreadable}" >&2
  printf '        rules, per-card    : [%s]\n' "${p_fold:-unreadable}" >&2
  printf '        detect-hardware    : [%s]\n' "${p_hw:-unreadable}" >&2
  printf '        scan_ftdi internal : [%s]\n' "${p_int:-unreadable}" >&2
  printf '        scan_ftdi external : [%s]\n' "${p_ext:-unreadable}" >&2
fi
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
[ -f "$M/var/lib/dpkg/info/overlayroot.list" ] && ok "overlayroot installed (menu option 8)" || bad "overlayroot missing"
# The factory flash menu (serial sub-menu options 1 and 2) is the primary way to
# program a card, so what its scripts exec is pinned here too. Same deb feeds both
# images, but the images are built separately - one build reaching a mirror that
# lacks a package says nothing about the other.
for b in ftdi_eeprom sudo python3; do
  [ -x "$M/usr/bin/$b" ] && ok "$b on medium (menu can flash)" \
    || bad "$b missing on medium: menu options 1/2 would refuse"
done
# the medium installs from a fixed-size USB stick - no first-boot resize
# Menu 1.1.0 merged the two BOOT_ORDER options into one sub-menu that reads the
# module first. Pin the shipped script to that version, and pin the two binaries
# its Depends declare, because both menu features degrade SILENTLY when absent:
# a missing sfdisk skips disk-id regeneration, a missing rpi-eeprom-config makes
# the boot-order option unreadable.
chk     "menu is the boot-order sub-menu build"   "$M/usr/local/sbin/openmux-menu.sh" 'boot_order_menu\(\)'
chk     "menu compares bootloader versions first" "$M/usr/local/sbin/openmux-menu.sh" 'eeprom_write_plan'
chk_not "menu has no blind BOOT_ORDER rewrite"    "$M/usr/local/sbin/openmux-menu.sh" "sed -i 's/\\^BOOT_ORDER"
# Menu 1.2.0 put the FTDI work behind one sub-menu instead of a single "set
# internal serial" prompt, because the console's chips and a plug-in EX-12 share a
# VID:PID and the menu must not be the thing that guesses. The top level is pinned
# at eight options: the sub-menu nests under option 2 precisely so this number,
# which the README and the bench instructions quote, does not move.
chk     "menu 2 is the serial sub-menu"        "$M/usr/local/sbin/openmux-menu.sh" 'serial_menu\(\)'
chk     "sub-menu can program a card"          "$M/usr/local/sbin/openmux-menu.sh" "Program an EX-12 adapter's serial number"
chk     "sub-menu tests console and card apart" "$M/usr/local/sbin/openmux-menu.sh" "--pairs card"
chk_not "menu never confirms a flash itself"   "$M/usr/local/sbin/openmux-menu.sh" 'program-ftdi[a-z-]*\.py.*--yes'
n_opts=$(sed -n '/^main_menu()/,/^  done/p' "$M/usr/local/sbin/openmux-menu.sh" |
         grep -cE '^  [0-9]\) ')
[ "$n_opts" = "8" ] && ok "main menu has 8 top-level options" \
  || bad "main menu has $n_opts top-level options, pinned at 8"
# Option 2 is dead weight without the tools it shells out to; they ship in the
# factory-tools deb, which the medium installs for exactly this reason.
[ -r "$M/opt/openmux-factory-tools/scan-ftdi-adapters.py" ] \
  && ok "medium ships the FTDI scanner (menu option 2)" \
  || bad "medium is missing the FTDI scanner - menu option 2 cannot see the bus"
[ -x "$M/opt/openmux-factory-tools/run-board-tests.sh" ] \
  && ok "medium ships the board test runner" \
  || bad "medium is missing run-board-tests.sh"
[ -x "$M/usr/sbin/sfdisk" ] \
  && ok "sfdisk present (regenerate_disk_ids)" \
  || bad "sfdisk missing - installs would keep the source image PARTUUIDs"
[ -x "$M/usr/bin/rpi-eeprom-config" ] \
  && ok "rpi-eeprom present (menu option 3)" \
  || bad "rpi-eeprom missing - menu option 3 cannot read the bootloader"
chk_not "medium has NO extend-filesystem unit" "$V/mroot/lib/systemd/system/openmux-extend-filesystem.service" 'openmux-extend-filesystem'
chk_not "medium has NO extend-filesystem script" "$V/mroot/usr/local/sbin/openmux-extend-filesystem.sh" 'growpart'
# medium boot vfat also has contents at the partition root (no firmware/)
# serial-only cmdline here too; the medium's HDMI menu does NOT come from
# console=tty1 but from the explicit getty@tty1.service enablement checked above
chk     "medium cmdline: serial console present" "$V/mboot/cmdline.txt" 'console=serial0,115200'
chk_not "medium cmdline: no console=tty1"        "$V/mboot/cmdline.txt" 'console=tty1'
# The medium boots from USB: /dev/disk/by-slot/* can never exist there
# (rpi-storage-binder maps firmware boot-mode 1=mmcblk0/6=nvme0n1 only, and
# image-rpios's rule matches no sdX). root= must therefore be PARTUUID-based,
# and the fstab has to agree with it - otherwise the medium boots to
# "ALERT! /dev/disk/by-slot/system does not exist".
chk       "medium cmdline root=PARTUUID"     "$V/mboot/cmdline.txt" 'root=PARTUUID=[0-9a-f]{8}-02'
chk_not   "medium cmdline has no by-slot ref" "$V/mboot/cmdline.txt" 'by-slot'
chk       "medium fstab root is PARTUUID"    "$M/etc/fstab" '^PARTUUID=[0-9a-f]{8}-02[ ]+/'
chk_not   "medium fstab has no by-slot ref"  "$M/etc/fstab" 'by-slot'
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
