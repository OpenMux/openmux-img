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
# located dynamically as the uid-1000 user, so any buildspec works. A few
# expectations below come from what a spec may ASK for rather than from what an
# image must always have, so they are opt-out with the spec in hand:
#   EXPECT_SSH_KEY=0       spec sets neither ssh_key nor key_file
#   EXPECT_POST_INSTALL=0  spec leaves post_install out (no /usr/local/openmux marker)
#   EXPECT_ADD_PKGS=       spec leaves additional_packages out (the fixture used curl git)
#   EXPECT_QA1=0           spec has no `qa1` in additional_accounts
# The medium's identity file is expected or forbidden by the same rule, driven by
# what the build was given:
#   OPENMUX_ENV_REF=<file> the `./build.sh --openmux-env` file this medium was
#                          built with; it must be on the FAT partition
#   unset / empty          the medium must carry no such file - and if it does
#                          carry one, that is a FAIL, not a skip: the expectation
#                          is unknown exactly when a leftover is dangerous
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
is_absent() { # is_absent <path>  (a dangling symlink counts as present: a broken
              # unit or .network link is exactly the thing being checked for)
  [ ! -e "$1" ] && [ ! -L "$1" ]
}
is_masked() { # is_masked <path>  - systemd's mask is a symlink to /dev/null
  [ "$(readlink "$1" 2>/dev/null)" = /dev/null ]
}
is_wanted() { # is_wanted <root> <target> <unit>  - enabled = a .wants symlink.
              # A symlink test, never an existence test: the entry's target is an
              # absolute in-root path (/usr/lib/systemd/system/X), so -e follows it
              # out of the root and answers about the host doing the inspecting.
  [ -L "$1/etc/systemd/system/$2.target.wants/$3" ]
}

# The wired port as the image ships it: the key of the netdef in
# /etc/netplan/01-openmux.yaml, which is also the name udev gives this board's
# port. The two names pinned below - that key, and the file set-ip derives from it -
# are built from this value, so a rename is one line here rather than an agreement
# between checks. The name itself belongs to the hardware and cannot be observed in
# an image: what is asserted is that the shipped config keys one name consistently
# and that the generator was run over it.
WIRED=end0

# The network stack the openmux-network layer builds, asserted on the finished
# image. File state is the only thing observable without booting, and the halves
# have to be checked together: netplan states the configuration, the renderer key
# names the daemon that applies it, and the daemon named for the shipped config
# (systemd-networkd) has to be reachable - not masked, not shadowed, and not wanted
# by anything either, since the generator asks for it per boot from the config.
network_stack() { # network_stack <root> <label>
  local r=$1 t=$2 u p state wanted renderers
  echo "  -- network stack: netplan rendered by systemd-networkd ($t)"
  [ -x "$r/usr/sbin/NetworkManager" ] && ok "$t: NetworkManager installed" \
    || bad "$t: /usr/sbin/NetworkManager missing"
  is_wanted "$r" multi-user NetworkManager.service \
    && ok "$t: NetworkManager enabled" || bad "$t: NetworkManager not enabled"
  # The two decisions the layer owns, and the backend it depends on.
  chk "$t: NM settings store is keyfile" "$r/etc/NetworkManager/conf.d/10-openmux.conf" '^plugins=keyfile$'
  chk "$t: NM delegates DNS to resolved" "$r/etc/NetworkManager/conf.d/10-openmux.conf" '^dns=systemd-resolved$'
  chk "$t: NM Wi-Fi backend is iwd" "$r/etc/NetworkManager/conf.d/iwd.conf" '^wifi\.backend=iwd$'
  [ -f "$r/var/lib/dpkg/info/iwd.list" ] && ok "$t: iwd installed" \
    || bad "$t: iwd missing, so Wi-Fi has no supplicant (wpa_supplicant is not installed either)"
  # The same three absences the build hook asserts, read off the image. Each is a
  # different way for /etc to outrank the renderer key, and none of them is visible
  # in the YAML that outranking it defeats: a symlink to /dev/null makes the daemon
  # unstartable (netplan still writes the wired port's .network, systemd still refuses to run
  # it, the port comes up with no address); any other symlink in that directory
  # replaces or aliases the unit; and a .wants entry - from a hand `systemctl
  # enable` or from 90-systemd.preset, which ships `enable systemd-networkd.service`
  # - starts it on every boot even for config that named another renderer.
  for u in systemd-networkd.service systemd-networkd.socket \
           systemd-networkd-wait-online.service systemd-network-generator.service \
           dbus-org.freedesktop.network1.service; do
    p="$r/etc/systemd/system/$u"
    state=$(readlink "$p" 2>/dev/null || true)
    wanted=$(ls "$r"/etc/systemd/system/*.wants/"$u" 2>/dev/null | tr '\n' ' ')
    if is_masked "$p"; then
      bad "$t: $u is masked, so the renderer in /etc/netplan names a daemon systemd will not start"
    elif [ -L "$p" ]; then
      bad "$t: $u is a symlink in /etc/systemd/system (-> $state), which outranks the unit in /usr/lib"
    elif [ -n "$wanted" ]; then
      bad "$t: $u is wanted by $wanted with nothing in netplan asking for it"
    else
      ok "$t: $u reaches systemd with no opinion from /etc"
    fi
  done
  # Absent from both trees means the package set changed under the layer: the
  # renderer would name a daemon the image does not ship. The D-Bus alias unit is
  # not in /usr/lib on Debian, so it is excluded from this half of the check.
  for u in systemd-networkd.service systemd-networkd.socket \
           systemd-networkd-wait-online.service systemd-network-generator.service; do
    [ -e "$r/etc/systemd/system/$u" ] || [ -e "$r/usr/lib/systemd/system/$u" ] \
      && ok "$t: $u exists for systemd to start" \
      || bad "$t: $u is in neither /etc nor /usr/lib - systemd-networkd ships it, so the renderer has no daemon behind it"
  done
  # NetworkManager's [Install] has Also=NetworkManager-wait-online.service, so
  # enabling NM links a 60 s boot-stall unit into network-online.target; the layer
  # drops that link (it is not masked: a masked unit someone still wants fails the
  # job). rescue-ssh.target in /usr/lib does Require network-online.target, which
  # is why reaching that target must not wait for a cable.
  is_absent "$r/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service" \
    && ok "$t: NetworkManager-wait-online is not wanted (no 60 s boot ceiling)" \
    || bad "$t: NetworkManager-wait-online.service is wanted by network-online.target"
  # The .network files the engine's device layer generates have to be gone as well.
  # /etc/systemd/network is networkd's own config source, read directly rather than
  # through netplan, so one of those files describes the same port as netplan's
  # generated /run/systemd/network/10-netplan-$WIRED.network: two DHCP clients, two
  # sets of routes, and `netplan apply` neither reads nor removes the /etc one. The
  # two names below are the engine's, fixed in layer/rpi/device/family-base.yaml, and
  # are not the board's - which is why both go.
  for u in 01-eth0.network 02-wlan0.network; do
    is_absent "$r/etc/systemd/network/$u" && ok "$t: /etc/systemd/network/$u removed" \
      || bad "$t: /etc/systemd/network/$u still present"
  done
  # The engine's null .link pair, kept as it shipped them: masked, udev parses no
  # NamePolicy from them, so a USB adapter or gadget keeps the name it arrived with -
  # the state a provisioning adapter has to keep for whoever plugs it in. The wired
  # port's name is not one of the things they produce, and $WIRED is pinned from the
  # YAML rather than from here.
  for u in 99-default.link 73-usb-net-by-mac.link; do
    is_masked "$r/etc/systemd/network/$u" && ok "$t: $u still disabled (udev names nothing from it)" \
      || bad "$t: /etc/systemd/network/$u is not a null link - the names it does cover will change"
  done
  # DNS: NM's conf names resolved, so resolved has to be there and own the file.
  is_wanted "$r" sysinit systemd-resolved.service \
    && ok "$t: systemd-resolved enabled" || bad "$t: systemd-resolved not enabled but NM is told to use it"
  [ "$(readlink "$r/etc/resolv.conf" 2>/dev/null)" = "../run/systemd/resolve/stub-resolv.conf" ] \
    && ok "$t: /etc/resolv.conf is the resolved stub" \
    || bad "$t: /etc/resolv.conf is not the resolved stub ($(readlink "$r/etc/resolv.conf" 2>/dev/null || echo 'not a symlink'))"
  # Wiring is configured in netplan, so this file is load-bearing in a way it is not
  # for a daemon that reads its own config directory: everything it says reaches the
  # daemon through the generator, at boot, into /run. If the generator is missing, or
  # the file does not name a renderer for the wired port, nothing configures it - and
  # nothing in /etc betrays it, because netplan's output is a tmpfs by the time anyone
  # can look. The layer's cleanup20-netplan-render runs the generator at build time;
  # what is pinned here is what survived into the image:
  #   * netplan.io and netplan-generator present, and reachable under the generator
  #     directory. netplan.io is a Depends of the Raspberry Pi build of
  #     network-manager, not of ours, so a future upstream change could drop it and
  #     leave /etc/netplan as decoration;
  #   * the renderer at network level says networkd. Comments stripped, and the indent
  #     is the point: netplan merges files per key and the lexically later file wins,
  #     so a second two-space `renderer:` in this directory has moved the whole image
  #     to another daemon. A renderer deeper in the tree belongs to one netdef, which
  #     is how a wlan0 or a modem entry is added, and is deliberately not constrained
  #     here;
  #   * mode 0600. netplan(5) asks for it and warns otherwise, and the warning comes
  #     from a generator that runs on every boot, so it would sit in the journal of
  #     every device forever. It is also the mode a file holding a Wi-Fi passphrase or
  #     a WireGuard private key needs.
  is_absent "$r/var/lib/dpkg/info/netplan.io.list" \
    && bad "$t: netplan.io is not installed, so /etc/netplan renders into nothing" \
    || ok "$t: netplan.io installed (it is what turns the YAML into daemon config)"
  # The unit-directory name is the mode switch: the same binary run any other way
  # refuses or reads a file argument, and writes no wants entry. systemd only ever
  # runs it as a generator, so this path is the only one that matters at boot.
  [ -x "$r/usr/lib/systemd/system-generators/netplan" ] \
    && ok "$t: netplan is installed where systemd runs generators" \
    || bad "$t: $r/usr/lib/systemd/system-generators/netplan is missing or not executable - /etc/netplan would never be read at boot"
  chk "$t: $WIRED declared in netplan"      "$r/etc/netplan/01-openmux.yaml" "^[[:space:]]{4}${WIRED}:\$"
  chk "$t: $WIRED takes its address from DHCP" "$r/etc/netplan/01-openmux.yaml" '^[[:space:]]{6}dhcp4:[[:space:]]*true$'
  [ "$(stat -c '%a' "$r/etc/netplan/01-openmux.yaml" 2>/dev/null)" = 600 ] \
    && ok "$t: the netplan file is 0600 (netplan warns at boot on any looser mode)" \
    || bad "$t: /etc/netplan/01-openmux.yaml is not mode 600"
  renderers=$(cat "$r"/etc/netplan/*.yaml "$r"/etc/netplan/*.yml 2>/dev/null \
                | sed 's/#.*//' | grep -E '^  renderer:' \
                | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//' | LC_ALL=C sort -u)
  [ "$renderers" = "networkd" ] \
    && ok "$t: network level renderer is networkd" \
    || bad "$t: network level renderer keys are [$(printf '%s' "$renderers" | tr '\n' ' ')], want networkd alone - empty means no file says who owns $WIRED, and the answer is then a default defined outside this image"
  # WireGuard is the reason a renderer switch costs nothing here: netplan renders a
  # `tunnels:` entry of mode wireguard into a .netdev for networkd or a wireguard
  # profile for NetworkManager, with no plugin on either side. What has to exist in
  # the image is the key tool and the kernel module the .netdev opens.
  [ -x "$r/usr/bin/wg" ] \
    && ok "$t: wireguard-tools installed (wg genkey makes the keys a tunnels: entry holds)" \
    || bad "$t: /usr/bin/wg is missing, so a netplan WireGuard tunnel cannot be created or inspected on the device"
  wgko=$(find "$r/usr/lib/modules" -name 'wireguard.ko*' -print 2>/dev/null | LC_ALL=C sort | head -1)
  [ -n "$wgko" ] \
    && ok "$t: kernel WireGuard module present (${wgko#"$r"})" \
    || bad "$t: no wireguard.ko under /usr/lib/modules - a tunnels: netdef would be configured by networkd into a device the kernel cannot create"
  # Exactly the one file the build intends to ship. NetworkManager writes a netplan
  # file of its own, 90-NM-<uuid>.yaml, for any connection it is asked to keep, and
  # it states the renderer for its device inside that file - so a root that carries
  # one does not prove the shipped YAML works, and a profile for a site's old wiring
  # would otherwise travel into every image built from this tree. NetworkManager is
  # never started during a build, hence: never expected. The layer's cleanup hook
  # refuses the same files, so this is the same rule read off the finished image.
  stray=$(find "$r/etc/netplan" -maxdepth 1 -name '90-NM-*' -print 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
  [ -z "$stray" ] \
    && ok "$t: no NM-generated netplan file in the image ($WIRED is configured by the YAML alone)" \
    || bad "$t: image ships an NM-generated netplan file: $stray"
  # Recommends are off build-wide (APT::Install-Recommends=false), which is what
  # keeps a second supplicant, a second DHCP client and the captive-portal helper
  # out of the image. Pinned because they are Recommends of network-manager: one
  # changed apt mode and two programs would answer for one interface.
  for p in wpasupplicant isc-dhcp-client dhcpcd-base dnsmasq-base; do
    is_absent "$r/var/lib/dpkg/info/$p.list" && ok "$t: $p absent" \
      || bad "$t: $p is installed (only Recommends-off keeps the stack single)"
  done
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
# Read-only-by-default belongs to the INSTALL MEDIUM alone (its layer owns the
# overlayroot cmdline fragment). If it ever reached the target, every CM5 the
# stick installs would discard its own writes - apt, keys, logs, everything.
chk_not   "target cmdline: no overlayroot (target must stay writable)" \
  "$B/cmdline.txt" 'overlayroot='
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
if [ "${EXPECT_QA1-1}" = "1" ]; then
chk   "qa1 account present"              "$R/etc/passwd" '^qa1:'
chk   "qa1 password set"                 "$R/etc/shadow" '^qa1:[^:*!]'
chk   "qa1 NOPASSWD sudoers"             "$R/etc/sudoers.d/openmux-qa1" 'qa1 .*NOPASSWD'
awk -F: '$1=="qa1" {exit !($3>=1000 && $3<65534)}' "$R/etc/passwd" \
  && ok "qa1 uid in user range" || bad "qa1 uid out of range"
chk   "qa1 member of sudo group" "$R/etc/group" '^sudo:.*qa1'
fi
chk   "admin member of adm group" "$R/etc/group" '^adm:.*'"$admin"

# SSH keys. A spec hands the admin key over as key_file (cross-checked against
# $SPEC/keys/admin.pub) or as ssh_key (only its arrival in the image is checkable),
# or not at all - password-only then, and there is no authorized_keys to inspect, so
# EXPECT_SSH_KEY=0 skips the group instead of failing it.
[ -n "$admin" ] && {
 if [ ! -f "$SPEC/keys/admin.pub" ] && [ "${EXPECT_SSH_KEY-1}" != 1 ]; then
  echo "  SKIP  admin SSH key group (spec sets neither key_file nor ssh_key)"
 else
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
 fi
}
# additional-account qa1 .ssh checks (fixture-specific; EXPECT_QA1=0 to skip)
if [ "${EXPECT_QA1-1}" = "1" ]; then
[ -s "$R/home/qa1/.ssh/authorized_keys" ] \
  && ok "qa1 authorized_keys non-empty" || bad "qa1 authorized_keys missing/empty"
# qa1's uid/gid come from the image (useradd assigned 1001/1001 here)
qa1_owner=$(awk -F: '$1=="qa1" {print $3":"$4; exit}' "$R/etc/passwd")
[ "$(stat -c '%u:%g' "$R/home/qa1/.ssh/authorized_keys" 2>/dev/null)" = "$qa1_owner" ] \
  && ok "qa1 .ssh owned by qa1 ($qa1_owner)" || bad "qa1 .ssh ownership wrong (want $qa1_owner)"
fi
# `${VAR-1}` and not `${VAR:-1}`: an EMPTY value must mean "this spec does not ask
# for it", and the `:-` form substitutes the default for empty as well as for unset,
# which would make EXPECT_ADD_PKGS= run the default list anyway.
if [ "${EXPECT_POST_INSTALL-1}" = 1 ]; then
  chk "post_install marker /usr/local/openmux/marker.txt" "$R/usr/local/openmux/marker.txt" 'extra'
fi
# `additional_packages` installs distro packages by name; the fixture asked for
# curl and git, so those two are the default list to look for in /usr/bin.
for p in ${EXPECT_ADD_PKGS-curl git}; do
  [ -x "$R/usr/bin/$p" ] && ok "additional_packages: $p installed" \
    || bad "additional_packages: /usr/bin/$p missing"
done

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
[ -f "$R/var/lib/dpkg/info/openmux-net-tools.list" ] && ok "deb openmux-net-tools installed" || bad "openmux-net-tools missing"
# The same layer's distro operator tools. Read from dpkg's own file list rather
# than from `/usr/bin/vi`: that path is a symlink whose target is an absolute
# in-root path (/etc/alternatives/vi), so a -x test on it answers about the host.
# vim.basic is the real binary and -L proves the alternative is wired up.
for p in vim less; do
  [ -f "$R/var/lib/dpkg/info/$p.list" ] && ok "operator package $p installed" \
    || bad "$p missing: an operator on the serial console has no $( [ "$p" = vim ] && echo editor || echo pager )"
done
[ -x "$R/usr/bin/vim.basic" ] && ok "vim.basic present" || bad "/usr/bin/vim.basic missing (vim's Depends, the binary vim installs)"
[ -L "$R/usr/bin/vi" ] && ok "/usr/bin/vi wired through update-alternatives" \
  || bad "/usr/bin/vi is not the alternatives symlink - vi would not be on PATH"
# set-ip is how an operator points the wired port at a fixed address, and the mode
# is pinned rather than only tested for -x: dpkg ships whatever mode the package
# tree holds, and a tool that lost its exec bit says so only when someone needs it
# at a console.
[ -x "$R/usr/local/sbin/set-ip" ] && ok "set-ip installed and executable" \
  || bad "/usr/local/sbin/set-ip missing or not executable (openmux-net-tools)"
[ "$(stat -c '%a' "$R/usr/local/sbin/set-ip" 2>/dev/null)" = 755 ] \
  && ok "set-ip mode 755" \
  || bad "set-ip is mode $(stat -c '%a' "$R/usr/local/sbin/set-ip" 2>/dev/null || echo absent), not 755"
# A shipped image configures $WIRED in 01-openmux.yaml and in nothing else.
# 90-openmux-$WIRED.yaml is what set-ip writes on a box that was told otherwise, so
# one in a fresh build has carried a single device's address into every device -
# and the build-time generator gate would have merged it into its own verdict, so
# this absence is what keeps that gate's answer true of the image as shipped.
[ ! -e "$R/etc/netplan/90-openmux-${WIRED}.yaml" ] \
  && ok "no operator-written address file in the image" \
  || bad "/etc/netplan/90-openmux-${WIRED}.yaml is in the image: $WIRED's address would be one box's, not this build's"
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
# The serial sub-menu's header IS `scan-ftdi-adapters.py --summary`, and it is read
# over a serial line, so a row that wraps is a table an operator cannot use while
# deciding what to flash. Width is a property of the strings production firmware
# writes, not of the code, so this runs the shipped scanner against a bus carrying
# them: two console chips on the internal paths, and one card - three chips under its
# own hub, one base.
# The fixture is nested real directories with top-level symlinks, because a device's
# parent is resolved through realpath(): a flat tree would report every chip as an
# adapter hanging off a hub that is not there.
FTF="$V/ftdi"; rm -rf "$FTF"
ftf() { # ftf <bus-port> <vid> <pid> <manufacturer> <product> <serial> <busnum> <devnum>
  local d
  case $1 in
    *.*) d="$FTF/_real/${1%.*}/$1" ;;   # inside the parent port's own directory
    *)   d="$FTF/_real/$1" ;;
  esac
  mkdir -p "$d"
  printf '%s\n' "$2"          > "$d/idVendor"
  printf '%s\n' "$3"          > "$d/idProduct"
  printf '%s\n' "$4"          > "$d/manufacturer"
  printf '%s\n' "$5"          > "$d/product"
  printf '%s\n' "$7"          > "$d/busnum"
  printf '%s\n' "$8"          > "$d/devnum"
  [ -z "$6" ] || printf '%s\n' "$6" > "$d/serial"
  ln -s "$d" "$FTF/$1"
}
ftf 2-1   1d6b 0002 'Linux 6.6.87 xhci-hcd' 'xHCI Host Controller' '' 2 1
ftf 2-1.1 0403 6011 'OpenMux' 'OpenMux Console HW8, Internal FTDI' OMC0003-A 1 2
ftf 2-1.2 0403 6011 'OpenMux' 'OpenMux Console HW8, Internal FTDI' OMC0003-B 1 3
ftf 1-1   1d6b 0002 'Linux 6.6.87 xhci-hcd' 'xHCI Hub' '' 1 4
ftf 1-1.2 0403 6011 'OpenMux' 'OpenMux eXtention EX-12' OMX9999-A 1 6
ftf 1-1.3 0403 6011 'OpenMux' 'OpenMux eXtention EX-12' OMX9999-B 1 7
ftf 1-1.4 0403 6011 'OpenMux' 'OpenMux eXtention EX-12' OMX9999-C 1 8
# The three environment variables the tool reads are pinned here rather than
# inherited: whichever console paths, maker or product the machine running this
# happens to export would move the fixture chips into another role, and the report
# below asserts one specific shape. An empty value counts as unset.
if SUM=$(OPENMUX_FTDI_INTERNAL_PATHS=2-1.1,2-1.2 OPENMUX_MANUFACTURER= \
         OPENMUX_PRODUCT_INTERNAL= OPENMUX_PRODUCT_EXTERNAL= \
         python3 "$FT/scan-ftdi-adapters.py" --devices-dir "$FTF" --env-file /dev/null \
           --summary 2>&1) && [ -n "$SUM" ]; then
  ok "shipped scanner renders --summary for that bus"
else
  bad "shipped scanner --summary failed:"; printf '%s\n' "$SUM" | sed 's/^/        /'
fi
# The console chips have to be ROWS of the same table (that is what the header was
# changed to show), with the manufacturer beside the product - a card reflashed by a
# site carries both, and it is the only way to see it without a cable.
chk_summary() { # chk_summary <desc> <egrep>
  if printf '%s\n' "$SUM" | grep -Eq -- "$2"; then ok "$1"
  else bad "$1"; printf '%s\n' "$SUM" | sed 's/^/        | /'; fi
}
chk_summary "--summary lists the console chip, with its maker" \
            'OMC0003-A[ ]+console[ ]+OpenMux[ ]+OpenMux Console HW8, Internal FTDI'
chk_summary "--summary rolls a card up to one line" \
            '^  1-1[ ]+OMX9999[ ]+3 ABC[ ]+/dev/openmux/OMX9999/port1-12$'
# The two hubs in the fixture are USB devices too, and are filtered out by id. When
# a row appears for something that is not an FTDI, the summary is no longer a list of
# the chips the options can program, and the operator reads a hub as a card.
if printf '%s\n' "$SUM" | grep -qi 'xhci'; then
  bad "--summary lists a non-FTDI device"; printf '%s\n' "$SUM" | sed 's/^/        | /'
else
  ok "--summary lists only the 0403:6011 chips"
fi
n_card=$(printf '%s\n' "$SUM" | sed -n '/EX-12 CARDS/,/^$/p' | grep -cE '^  [0-9]')
[ "$n_card" = "1" ] && ok "--summary prints one card row for three chips" \
  || bad "--summary printed $n_card card rows for one card"
too_wide=$(printf '%s\n' "$SUM" | awk 'length($0)>80 {print length($0)": "$0}' | head -3)
[ -z "$too_wide" ] && ok "--summary fits an 80-column console" \
  || { bad "--summary exceeds 80 columns:"; printf '        %s\n' "$too_wide"; }
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

[ -L "$R/etc/systemd/system/sysinit.target.wants/openmux-detect-hardware.service" ] \
  && ok "openmux-detect-hardware.service enabled" || bad "hw-detect service not enabled"
chk   "hostname" "$R/etc/hostname" '^openmux$'

network_stack "$R" target

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
# overlayroot is not optional here any more: the image boots read-only BY
# DEFAULT (cmdline fragment in openmux-install-medium), and this package's
# initramfs hook is what puts the overlay machinery into the initrd.
[ -f "$M/var/lib/dpkg/info/overlayroot.list" ] \
  && ok "overlayroot installed (default read-only root)" \
  || bad "overlayroot missing: the medium cannot boot its read-only overlay root"
# The package is necessary but NOT sufficient: overlayroot detects its driver by
# grepping /proc/filesystems (once before modprobe -qb, once after), and a minbase
# initrd built with --no-install-recommends contains no grep at all, so the probe
# cannot succeed and overlayroot logs a failure and exits 0 on a read-write root.
# This hook puts grep/sed and a usable mount into the initrd; the build itself
# asserts the RESULT inside the finished boot.vfat (postimage30-overlayroot-check,
# which is the check that matters), so pin the hook here and the artifacts there.
chk "medium ships the initrd grep/sed hook" \
  "$M/etc/initramfs-tools/hooks/openmux-overlayroot-tools" 'copy_exec /usr/bin/grep'
# Same hook, second requirement: the initrd's own mount comes from klibc and
# takes no long options, so overlayroot's `mount --move` needs util-linux's there.
chk "medium initrd hook also installs util-linux mount" \
  "$M/etc/initramfs-tools/hooks/openmux-overlayroot-tools" 'copy_exec /bin/mount'
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
# The sub-menu's header is the scanner's report (--summary, checked against a fake
# bus in the target section above), not a summary the menu builds out of the tsv. Two
# answers to "which of these chips is the console" is precisely how a chip gets
# flashed by the wrong option, so a menu that starts deciding for itself fails here.
chk     "sub-menu header comes from the scanner" "$M/usr/local/sbin/openmux-menu.sh" '--summary'
chk_not "sub-menu builds no device summary itself" "$M/usr/local/sbin/openmux-menu.sh" 'Console chips :'
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
# The medium's root is READ-ONLY BY DEFAULT: the openmux-install-medium layer
# adds overlayroot=tmpfs, so the initramfs mounts the stick's ext4 read-only at
# /media/root-ro and runs the whole session in a tmpfs overlay. The line-count
# pin below is what proves the token is on line 1: the firmware appends
# cmdline.txt but ignores everything after the first line, so a token anywhere
# else is silently dropped.
chk     "medium cmdline: read-only overlay root"  "$V/mboot/cmdline.txt" '(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)'
n_mcmd=$(grep -c '' "$V/mboot/cmdline.txt")
[ "$n_mcmd" = "1" ] && ok "medium cmdline: exactly one line" \
  || bad "medium cmdline: $n_mcmd lines, want 1 (firmware reads only the first)"
# `ro` is NOT the harmless-looking default it appears to be on an appliance:
# overlayroot turns it into cmdline_ro, which remounts the OVERLAY read-only, so
# apt / passwd / the EEPROM staging the menu performs mid-session would fail.
# The read-only LOWER layer comes from Debian's initramfs `export readonly=y`,
# not from this parameter, so the image must ship neither ro nor rw.
chk_not "medium cmdline: no ro (session must stay writable)" "$V/mboot/cmdline.txt" '(^|[[:space:]])ro([[:space:]]|$)'
# The overlay is created at boot, so the built image must carry no leftovers of
# one: a baked-in /overlay workdir or a populated /media would shadow or confuse
# the mounts the initramfs sets up (verified against the staged rootfs).
if [ ! -e "$M/overlay" ] && [ -z "$(ls -A "$M/media" 2>/dev/null)" ]; then
  ok "medium rootfs has no baked-in overlay leftovers"
else
  bad "medium rootfs carries overlay leftovers (/overlay present, or /media not empty)"
fi
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

# --- the optional site identity file ----------------------------------------
# Checked in BOTH directions: with OPENMUX_ENV_REF the file must be on the FAT
# partition and resolve to the requested strings, without it the medium must NOT
# carry one. The absence direction is the one that matters - the partition is
# pass-through and the file is read by path, so a stale openmux.env (left by an
# earlier site, or hand-edited in the field) would keep programming chips long
# after the build stopped asking for it, and nothing on the stick would say so.
# The name is case-checked by the path itself: vfat stores an 8.3-compatible name
# uppercase and mounts it lowercase, which is why cmdline.txt is readable by that
# exact name above - the reader uses the lowercase literal, so this pins it.
OM_FAT="$V/mboot/openmux.env"
if [ -n "${OPENMUX_ENV_REF:-}" ]; then
  if [ ! -f "$OPENMUX_ENV_REF" ]; then
    bad "OPENMUX_ENV_REF is not readable: $OPENMUX_ENV_REF"
  elif [ ! -f "$OM_FAT" ]; then
    bad "medium FAT has no openmux.env, but the build asked for $OPENMUX_ENV_REF"
  else
    ok "medium FAT carries openmux.env"
    # The shipped reader decides what gets flashed, so agreement is judged by the
    # copy INSIDE the image rather than by a second parser on the build host.
    resolve_env() { # resolve_env <file> -> sorted KEY=value as scan_ftdi reads it
      python3 - "$M/opt/openmux-factory-tools" "$1" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import scan_ftdi as F
for k, v in sorted(F.load_env_file(sys.argv[2]).items()):
    print(f"{k}={v}")
PY
    }
    want_env=$(resolve_env "$OPENMUX_ENV_REF")
    got_env=$(resolve_env "$OM_FAT")
    # Both sides empty compares equal, and empty is what the reader produces when
    # it cannot be imported at all - so the vacuous case is named rather than
    # allowed to pass. (A key-less file cannot reach here: check-openmux-env.py
    # refuses one long before the image is built.)
    if [ -z "$want_env" ]; then
      bad "shipped reader resolved no values at all (no $M/opt/openmux-factory-tools?)"
    elif [ "$want_env" = "$got_env" ]; then
      ok "medium openmux.env resolves to the requested values (shipped reader)"
    else
      bad "medium openmux.env resolves DIFFERENTLY than $OPENMUX_ENV_REF"
      printf '        requested: %s\n        on medium: %s\n' \
        "$(printf '%s' "$want_env" | tr '\n' ' ')" \
        "$(printf '%s' "$got_env" | tr '\n' ' ')"
    fi
    cmp -s "$OM_FAT" "$OPENMUX_ENV_REF" \
      && ok "medium openmux.env is byte-identical to the requested file" \
      || bad "medium openmux.env is not byte-identical to the requested file"
  fi
else
  if is_absent "$OM_FAT"; then
    ok "medium carries no openmux.env (none requested: tools keep their defaults)"
  else
    # Not "expected none": the expectation is unknown here, which is exactly when a
    # leftover file is dangerous, so this refuses rather than skipping.
    bad "medium carries openmux.env ($(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$OM_FAT" | tr '\n' ' ')) but OPENMUX_ENV_REF was not set - pass the file this medium was built with, or delete the file from the stick"
  fi
fi

network_stack "$M" medium

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
