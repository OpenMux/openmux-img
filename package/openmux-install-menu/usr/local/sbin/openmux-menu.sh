#!/usr/bin/env bash
# Plain-text install/rescue menu shown on tty1 of the OpenMux USB install medium.
set -uo pipefail

IMAGES_DIR="/opt/openmux-installer/images"
PROVISIONING_DIR="/opt/openmux-factory-tools"

msg() { echo -e "$*"; }
pause() { read -rp "Press Enter to continue..." _; }

# Parent disk backing the running root filesystem (the USB stick itself), to exclude from install targets.
current_root_disk() {
  local src pk partuuid
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "overlay" ]]; then
    # overlayroot replaces / with an overlay mount (SOURCE isn't a real block device); the
    # real disk is remounted read-only at /media/root-ro underneath it.
    src="$(findmnt -no SOURCE /media/root-ro 2>/dev/null || true)"
  fi
  if [[ -z "$src" || ! -b "$src" ]]; then
    # Fall back to the kernel's root= parameter in case the source above isn't a block device.
    partuuid="$(grep -oE 'root=PARTUUID=[0-9a-fA-F-]+' /proc/cmdline 2>/dev/null | cut -d= -f3)"
    [[ -n "$partuuid" ]] && src="$(blkid -o device -t "PARTUUID=$partuuid" 2>/dev/null)"
  fi
  [[ -n "$src" ]] || return
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  [[ -n "$pk" ]] && echo "$pk" || basename "$src"
}

list_images() {
  find "$IMAGES_DIR" -maxdepth 1 -type f \( -name '*.img' -o -name '*.img.xz' -o -name '*.img.gz' -o -name '*.img.zst' -o -name '*.iso' \) 2>/dev/null | sort
}

list_target_disks() {
  local root_disk
  root_disk="$(current_root_disk)"
  # Parsing lsblk's plain columns with awk breaks once MODEL contains spaces, so filter
  # NAME/TYPE first and fetch SIZE/MODEL per device instead.
  local name type
  while IFS=' ' read -r name type; do
    [[ "$type" == "disk" ]] || continue
    [[ "$name" == "$root_disk" ]] && continue
    case "$name" in
      loop*|ram*|zram*|sr*|dm-*|md*|*boot0|*boot1|*rpmb) continue ;;
    esac
    local size model
    size="$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null)"
    model="$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null)"
    printf '%s %s %s\n' "$name" "$size" "$model"
  done < <(lsblk -dn -o NAME,TYPE 2>/dev/null)
}

do_install() {
  mapfile -t images < <(list_images)
  if [[ ${#images[@]} -eq 0 ]]; then
    msg "No install images found in $IMAGES_DIR"
    pause
    return
  fi

  local image
  if [[ ${#images[@]} -eq 1 ]]; then
    image="${images[0]}"
    msg "Only one install image found; auto-selecting: $(basename "$image")"
  else
    msg "Available images:"
    local i
    for i in "${!images[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "$(basename "${images[$i]}")"
    done
    local sel
    read -rp "Select image number (or 'q' to cancel): " sel
    [[ "$sel" == "q" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#images[@]} )); then
      msg "Invalid selection."; pause; return
    fi
    image="${images[$((sel - 1))]}"
  fi

  mapfile -t disks < <(list_target_disks)
  if [[ ${#disks[@]} -eq 0 ]]; then
    msg "No target disks found (eMMC/NVMe/SD)."; pause; return
  fi

  local disk_name
  if [[ ${#disks[@]} -eq 1 ]]; then
    disk_name="${disks[0]%% *}"
    msg "Only one target disk found; auto-selecting: ${disks[0]}"
  else
    msg "Available target disks:"
    for i in "${!disks[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${disks[$i]}"
    done
    read -rp "Select target disk number (or 'q' to cancel): " sel
    [[ "$sel" == "q" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#disks[@]} )); then
      msg "Invalid selection."; pause; return
    fi
    disk_name="${disks[$((sel - 1))]%% *}"
  fi
  local target="/dev/$disk_name"

  msg ""
  msg "!!! WARNING !!!"
  msg "This will ERASE ALL DATA on $target and write:"
  msg "  $(basename "$image")"
  local confirm
  read -rp "Type YES (uppercase) to continue: " confirm
  [[ "$confirm" == "YES" ]] || { msg "Aborted."; pause; return; }

  local part
  for part in "${target}"?*; do
    [[ -b "$part" ]] || continue
    umount "$part" 2>/dev/null || true
  done

  msg "Writing image to $target ..."
  local writer
  case "$image" in
    *.xz)  writer="xzcat" ;;
    *.gz)  writer="zcat" ;;
    *.zst) writer="zstdcat" ;;
    *)     writer="cat" ;;
  esac

  if ! command -v "$writer" >/dev/null 2>&1; then
    msg "Missing required command: $writer"; pause; return
  fi

  if command -v pv >/dev/null 2>&1; then
    "$writer" "$image" | pv | dd of="$target" bs=4M conv=fsync status=none
  else
    "$writer" "$image" | dd of="$target" bs=4M conv=fsync status=progress
  fi

  sync
  partprobe "$target" 2>/dev/null || true
  regenerate_disk_ids "$target"
  msg "Done. Image written to $target."
  pause
}

# Maps a disk device to one of its partition devices, handling both naming schemes
# (/dev/sda1 vs /dev/mmcblk0p1 / /dev/nvme0n1p1).
disk_part() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

# Units written from one source image all share the image's MBR disk signature and
# therefore the same PARTUUIDs. That is only a problem for images that ADDRESS their
# partitions by PARTUUID: the stick and a freshly installed disk (or two units on a QC
# bench) then present duplicate identifiers, the wrong device can be mounted, and it
# shows up as e.g. systemd-remount-fs.service failing. Such an image must also have its
# cmdline.txt/fstab rewritten to the new signature or it will not boot.
#
# Whether an installed disk needs any of this is a property of the IMAGE, not of the
# installer, so it is read off the disk we just wrote instead of being assumed: our
# target addresses root and boot through /dev/disk/by-slot/* (image-rpios' rule plus the
# rpi-storage-binder tag, both scoped to the BOOT device), which no second disk can
# shadow, and it carries no PARTUUID reference at all. Re-signing it would change an
# identifier nothing resolves and then end in two bogus warnings - "cmdline.txt /
# /etc/fstab does not reference the new PARTUUID" - because the rewrites below have
# nothing to match. That is the normal state of a by-slot image, not a fault.
regenerate_disk_ids() {
  local disk="$1"
  local boot_part root_part
  boot_part="$(disk_part "$disk" 1)"
  root_part="$(disk_part "$disk" 2)"

  # Partition device nodes can take a moment to reappear after writing a whole new image
  # and partprobe-ing; wait for them instead of skipping disk ID regeneration too eagerly.
  command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
  local tries
  for tries in 1 2 3 4 5; do
    [[ -b "$boot_part" && -b "$root_part" ]] && break
    sleep 1
  done

  if [[ ! -b "$boot_part" || ! -b "$root_part" ]]; then
    msg "WARNING: could not find partitions on $disk; skipping disk ID regeneration."
    return 0
  fi

  # Ask the installed image itself how it finds its root; the kernel takes the LAST root= token.
  local tmp_boot root_ref=""
  tmp_boot="$(mktemp -d)"
  if mount -o ro "$boot_part" "$tmp_boot" 2>/dev/null; then
    root_ref="$(grep -oE 'root=[^ ]+' "$tmp_boot/cmdline.txt" 2>/dev/null | tail -n1)"
    umount "$tmp_boot" 2>/dev/null || true
  fi
  rmdir "$tmp_boot" 2>/dev/null || true
  case $root_ref in
    root=PARTUUID=*) : ;;   # addressed by PARTUUID: re-signing and rewriting are required
    *)
      msg "Root is referenced by '${root_ref:-nothing}' rather than PARTUUID, so this disk shares no boot-critical identifier with other units; leaving its disk ID alone."
      return 0
      ;;
  esac

  if ! command -v sfdisk >/dev/null 2>&1; then
    msg "WARNING: this image boots by PARTUUID but sfdisk is unavailable, so the disk ID cannot be regenerated (PARTUUID will collide with other units)."
    return 0
  fi

  msg "Regenerating disk ID on $disk to avoid PARTUUID collisions with other devices ..."
  local new_id
  new_id="$(od -An -tx4 -N4 /dev/urandom | tr -d ' \n')"

  if ! sfdisk --disk-id "$disk" "0x$new_id" >/dev/null 2>&1; then
    msg "WARNING: sfdisk --disk-id failed on $disk (not an MBR disk?); skipping disk ID regeneration."
    return 0
  fi
  partprobe "$disk" 2>/dev/null || true
  command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

  # Partition device nodes can take a moment to reappear after partprobe; wait for them
  # instead of racing a mount that would otherwise fail silently.
  local tries
  for tries in 1 2 3 4 5; do
    [[ -b "$boot_part" && -b "$root_part" ]] && break
    sleep 1
  done

  local tmp_boot tmp_root
  tmp_boot="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  if mount "$boot_part" "$tmp_boot" 2>/dev/null && mount "$root_part" "$tmp_root" 2>/dev/null; then
    # cmdline.txt's root= line references the ROOT partition (-02), not the boot partition.
    sed -i -E "s/PARTUUID=[0-9a-fA-F]{8}-02/PARTUUID=${new_id}-02/g" "$tmp_boot/cmdline.txt" 2>/dev/null || true
    sed -i -E "s/PARTUUID=[0-9a-fA-F]{8}-01/PARTUUID=${new_id}-01/g; s/PARTUUID=[0-9a-fA-F]{8}-02/PARTUUID=${new_id}-02/g" "$tmp_root/etc/fstab" 2>/dev/null || true

    # sed above is best-effort; verify it actually took, since a silent miss here leaves
    # cmdline.txt/fstab pointing at the old PARTUUID and the disk won't boot.
    if [[ -f "$tmp_boot/cmdline.txt" ]] && ! grep -q "PARTUUID=${new_id}-02" "$tmp_boot/cmdline.txt"; then
      msg "WARNING: cmdline.txt does not reference the new PARTUUID; the disk may not boot. Check it manually."
    fi
    if [[ -f "$tmp_root/etc/fstab" ]] && ! grep -q "PARTUUID=${new_id}-02" "$tmp_root/etc/fstab"; then
      msg "WARNING: /etc/fstab does not reference the new PARTUUID; check it manually."
    fi
  else
    msg "WARNING: could not mount $boot_part/$root_part to update PARTUUID references; the disk may not boot."
  fi
  umount "$tmp_boot" 2>/dev/null || true
  umount "$tmp_root" 2>/dev/null || true
  rmdir "$tmp_boot" "$tmp_root" 2>/dev/null || true

  # Only PARTUUID images reach this point (see the root= check above). Unique filesystem
  # UUIDs matter for the same duplicate-identifier reason; note that the immutable A/B
  # layout deliberately keeps identical per-slot UUIDs and resolves slots by PARTLABEL,
  # so an image of that family must not have them randomised here.
  if command -v tune2fs >/dev/null 2>&1; then
    e2fsck -f -y "$root_part" >/dev/null 2>&1 || true
    tune2fs -U random "$root_part" >/dev/null 2>&1 || true
  fi

  msg "New disk ID: $new_id"
}

drop_to_shell() {
  msg "Dropping to shell. Type 'exit' to return to the menu."
  bash -l || true
}

# --- serial numbers and serial ports ------------------------------------------
#
# The console's own FTDI chips and a plug-in EX-12 adapter share one VID:PID, and
# an unprogrammed adapter's chip reports no serial at all, so which is which can
# only be read off the USB topology. That is scan-ftdi-adapters.py's job, and this
# menu deliberately asks it rather than judging anything here: run-board-tests.sh
# and program-ftdi-*.py use the same answers.
#
# Two rules through this whole section: the menu never passes --yes to a flasher
# (the tool shows the chips and the old serials, and that confirmation is the
# operator's, not the menu's), and programming is never chained into testing -
# a flasher ends by asking for an unplug/replug, which has to happen before any
# port means anything.

FTDI_SCAN="$PROVISIONING_DIR/scan-ftdi-adapters.py"

ftdi_tools_present() {
  if [[ ! -r $FTDI_SCAN ]]; then
    msg "Not found: $FTDI_SCAN"
    msg "The openmux-factory-tools package provides it; option 1's image ships it."
    return 1
  fi
  return 0
}

# Chatter from a function whose stdout is a return value has to go elsewhere.
emsg() { echo -e "$*" >&2; }

# One line per FTDI chip the scanner says belongs to an adapter group, in the
# scanner's own tsv columns: role, path, hub, bus, devnum, serial, maker, product,
# reason. The role is the scanner's judgement off the USB topology - this menu
# never guesses it, and an unprogrammed chip has nothing here to guess from.
ftdi_adapters() {
  ftdi_tools_present || return 1
  python3 "$FTDI_SCAN" --format tsv 2>/dev/null | awk -F'\t' '$1 == "adapter"'
}

# One line per adapter group, as "hub<TAB>bases": what to offer the operator,
# collapsed from the three chips a card presents. bases is empty until the card
# has been programmed, which is the state this whole section exists to handle.
ftdi_adapter_summary() {
  ftdi_adapters | awk -F'\t' '
    {
      hub = $3; base = $6; sub(/-[A-Za-z]$/, "", base)
      if (!(hub in seen)) { seen[hub] = 1; order[++n] = hub }
      if (base != "" && !((hub SUBSEP base) in have)) {
        have[hub, base] = 1
        list[hub] = list[hub] (list[hub] ? "," : "") base
      }
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], list[order[i]] }'
}

# The console's own chips, which the header shows so the operator can see the
# tool is talking about the hardware they are looking at. Flat /dev/openmux, and
# never offered as a card.
ftdi_console_summary() {
  ftdi_tools_present || return 1
  python3 "$FTDI_SCAN" --format tsv --include-internal 2>/dev/null |
    awk -F'\t' '$1 == "console" && $6 != "" { printf "%s ", $6 }' | sed 's/ *$//'
}

# Ask for a serial base, and refuse it here if the udev rules would not match it:
# a base that is written but never matched leaves a programmed chip with no
# /dev/openmux ports, which reads to the next person as a broken card. The rules
# themselves live in scan_ftdi.validate_base and are reached through the scanner,
# so the menu, the flashers and the tests cannot disagree about what is legal.
#
# Exit 3 from --check-base means "legal, but the rules will not name a folder for
# it", which is not the same as a refusal: the operator may be working with a
# prefix this stick's openmux.env does not know about, so it is asked explicitly
# rather than accepted quietly or refused.
ftdi_ask_base() {
  local role=$1 prefix=$2 example base rc again
  example="${prefix}1234"
  while true; do
    printf "Serial base, e.g. %s  ('q' cancels): " "$example" >&2
    read -r base || return 1
    [[ -z $base || $base == q || $base == Q ]] && return 1
    ftdi_tools_present || return 1
    python3 "$FTDI_SCAN" --check-base "$base" --for-role "$role"
    rc=$?
    if (( rc == 0 )); then
      FTDI_BASE=$base
      return 0
    fi
    if (( rc == 3 )); then
      # Not read -rp: bash only shows that prompt when stdin is a terminal, and a
      # question nobody saw asked is worse than no question.
      printf 'Use it as typed anyway? [y/N]: ' >&2
      read -r again || return 1
      if [[ $again =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        FTDI_BASE=$base
        return 0
      fi
    fi
    msg "Try again, or 'q' to cancel."
  done
}

program_console_serial() {
  local script="$PROVISIONING_DIR/program-ftdi-internal.py"
  if [[ ! -x $script ]]; then msg "Provisioning script not found: $script"; pause; return; fi
  msg "The console's own two FTDI chips - the USB the host sees as a COM port, and"
  msg "the debug serial. Their serials become OMC<digits>-A and -B, and the"
  msg "ports land in flat /dev/openmux. The card's chips are refused by this tool."
  msg ""
  ftdi_ask_base internal OMC || return 0
  msg ""
  msg "If a card is plugged in, unplug it now: it must not be in the socket while"
  msg "these are flashed, even though the tool will refuse it if it is."
  msg ""
  "$script" "$FTDI_BASE"
  msg ""
  msg "When it finishes, this console's ports reappear as /dev/openmux/port1-8."
  msg "Test them from the serial menu."
  pause
}

program_adapter_serial() {
  local script="$PROVISIONING_DIR/program-ftdi-external.py" hub
  if [[ ! -x $script ]]; then msg "Flashing script not found: $script"; pause; return; fi
  if ! hub=$(ftdi_pick_adapter); then return 0; fi
  ftdi_ask_base external OMX || return 0
  msg ""
  msg "The adapter stays in its socket for this. Its three chips are written"
  msg "together as $FTDI_BASE-A, -B and -C, which is what numbers the twelve ports."
  msg ""
  "$script" "$FTDI_BASE" --adapter "$hub"
  local rc=$?
  (( rc == 0 )) && msg "Unplug the adapter, wait two seconds, plug it back, then" \
                 && msg "test it from the serial menu."
  pause
}

# Offer the adapter groups on the bus and echo the chosen hub. An adapter is
# identified by where it is plugged in, because until it is programmed it has no
# serial to name it by - and once it has, the socket still says which physical
# card the operator is holding. Returns non-zero without choosing when there is
# nothing to choose.
ftdi_pick_adapter() {
  local summary line hub bases n=0 hubs=() choice
  summary=$(ftdi_adapter_summary)
  if [[ -z $summary ]]; then
    emsg "No EX-12 adapter found on USB."
    emsg "If one is plugged in, list the FTDI devices from this menu: it shows what"
    emsg "the bus does see, which is how a card that is unpowered, or on a hub that"
    emsg "is not the card's own, becomes obvious."
    pause
    return 1
  fi
  while IFS=$'\t' read -r hub bases; do
    [[ -n $hub ]] || continue
    n=$((n + 1))
    hubs+=("$hub")
    emsg "  $n) USB path $hub  ${bases:+programmed as $bases}${bases:-not programmed yet}"
  done <<<"$summary"
  if (( n == 1 )); then
    emsg "Only one adapter on the bus."
    echo "${hubs[0]}"
    return 0
  fi
  emsg ""
  printf 'Which adapter? [1-%d] ' "$n" >&2
  read -r choice || return 1
  if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
    emsg "Not one of those."
    pause
    return 1
  fi
  echo "${hubs[choice - 1]}"
}

list_ftdi_devices() {
  ftdi_tools_present || { pause; return; }
  python3 "$FTDI_SCAN" --serials
  pause
}

test_console_ports() {
  local script="$PROVISIONING_DIR/run-board-tests.sh"
  if [[ ! -x $script ]]; then msg "Test runner not found: $script"; pause; return; fi
  msg "Console ports are /dev/openmux/port1-8, flat. The runner prints the plug order"
  msg "when it starts - 2-3, 4-5, 6-7, 8-1. Two of those four jump between the two"
  msg "console chips (4-5 and 8-1), and those are the pairs that fail loudly when a"
  msg "chip was programmed with the wrong serial."
  msg ""
  msg "It is safer to unplug any EX-12 adapter first, so there is nothing else"
  msg "sharing those names while you are probing with a plug."
  msg ""
  pause
  "$script" --port-base /dev/openmux --pairs console
  pause
}

test_adapter_ports() {
  local script="$PROVISIONING_DIR/run-board-tests.sh" hub bases base
  if [[ ! -x $script ]]; then msg "Test runner not found: $script"; pause; return; fi
  if ! hub=$(ftdi_pick_adapter); then return 0; fi
  bases=$(ftdi_adapter_summary | awk -F'\t' -v h="$hub" '$1==h {print $2; exit}')
  if [[ -z $bases ]]; then
    msg "That adapter is not programmed yet, so it has no /dev/openmux folder to"
    msg "test. Program it first - the twelve port numbers come from that serial."
    pause
    return
  fi
  base=${bases%%,*}
  msg "Testing /dev/openmux/$base. The runner prints the twelve-way patch cord"
  msg "before it starts, including the 4-5, 8-9 and 12-1 joints between chips."
  msg ""
  "$script" --port-base "/dev/openmux/$base" --pairs card
  pause
}

serial_menu() {
  local choice console adapters n
  while true; do
    clear
    msg "========================================"
    msg "   Serial numbers and serial ports"
    msg "========================================"
    ftdi_tools_present || { pause; return 0; }
    console=$(ftdi_console_summary)
    adapters=$(ftdi_adapter_summary)
    n=$(grep -c . <<<"$adapters")
    # Each group names the options that act on it, which is the unambiguous way to
    # say what the old parenthetical tried to: the console's built-in chips are
    # handled by options 1 and 4 and never by the EX-12 ones. "not offered as a
    # card" read to an operator with eight live ports like word for word the
    # description of a fault, so it is gone rather than rephrased.
    if [[ -n $console ]]; then
      msg "  Console chips : $console"
      msg "                  ports 1-8 in /dev/openmux  (program with 1, test with 4)"
    else
      msg "  Console chips : none seen on the internal paths. Either nothing is"
      msg "                  programmed yet, or this board enumerates somewhere"
      msg "                  other than 2-1.1/2-1.2 - list them and check before"
      msg "                  programming anything."
    fi
    if (( n == 0 )); then
      msg "  EX-12 cards   : none on the bus  (program with 2, test with 5)"
    else
      msg "  EX-12 cards   : $n  (program with 2, test with 5)"
      while IFS=$'\t' read -r hub bases; do
        if [[ -z $bases ]]; then
          msg "                  hub $hub: present, not programmed"
        else
          msg "                  hub $hub: programmed as $bases"
          # Only when there is exactly one base: two on one hub would mean the
          # card's own chips disagree, and /dev/openmux/A,B names no folder.
          if [[ -n $bases && $bases != *,* ]]; then
            msg "                            /dev/openmux/$bases/port1-12"
          fi
        fi
      done <<<"$adapters"
    fi
    msg ""
    msg "  1) Program the console's internal serial number"
    msg "  2) Program an EX-12 adapter's serial number"
    msg "  3) List / identify FTDI devices"
    msg "  4) Test the console's ports (loopback)"
    msg "  5) Test an EX-12 adapter's ports (loopback)"
    msg "  6) Back"
    msg "========================================"
    read -rp "Select an option: " choice
    case "$choice" in
      1) program_console_serial ;;
      2) program_adapter_serial ;;
      3) list_ftdi_devices ;;
      4) test_console_ports ;;
      5) test_adapter_ports ;;
      6) return 0 ;;
      *) msg "Invalid option."; pause ;;
    esac
  done
}

# --- bootloader EEPROM / boot order -------------------------------------------
#
# Everything in this section writes the module's SPI flash, which is the only
# part of this menu that can turn a unit into a bench repair. Guarded as such.
#
# What "applying a config" actually does - checked against the rpi-eeprom
# sources, and NOT what this option used to claim:
#
#   rpi-eeprom-config --apply <conf> does not patch the firmware that is
#   running. It takes the NEWEST pieeprom-*.bin that the rpi-eeprom package on
#   THIS STICK ships (apply_update() -> get_latest_eeprom() ->
#   `rpi-eeprom-update -l`), replaces only the bootconf.txt inside it, and hands
#   the result to `rpi-eeprom-update -d -i -f`. So one "boot order change" is
#   simultaneously a bootloader VERSION change whenever the stick's image and
#   the module's firmware differ - a real firmware upgrade/downgrade, not a
#   config tweak. `-f` additionally BYPASSES the FREEZE_VERSION pin, and on
#   BCM2712 the default path re-flashes the SPI flash immediately (A/B update),
#   not at the next reboot.
#
# Upstream is not blind here either, and the guards below are deliberately
# redundant with it (checked against /usr/bin/rpi-eeprom-update as built into
# the medium, and /usr/bin/rpi-eeprom-config):
#
#   * applyRecoveryUpdate() compares the IMAGE's MFG_VER with
#     /proc/device-tree/chosen/rpi-min-boot-ver and dies when
#     STRICT_MIN_VER_CHECK=1 (the default) - a module manufactured with a newer
#     bootloader than this stick ships is refused there. That is the
#     "module boot key/ver is too old for the image" case, and it is covered.
#   * confirmDowngrade() covers the other direction: an image older than the
#     running bootloader - or a running version it cannot read - is refused
#     unless -y / RPI_EEPROM_ALLOW_DOWNGRADE=1, and --apply passes -d -i -f
#     only, never -y.
#   * the image -l picks is filtered by EEPROM size and BCM chip
#     (FIRMWARE_ROOT-$BCM_CHIP/<release-status>), so a BCM2711 image cannot be
#     selected on a BCM2712 module.
#
# What upstream does NOT cover, and is therefore ours: -f ignores the
# FREEZE_VERSION pin; an UPGRADE to a release nobody validated for this module's
# boot flow is entirely acceptable to upstream; and upstream's downgrade prompt
# is written to /dev/tty from inside rpi-eeprom-config, i.e. a question asked
# where nobody saw it being asked. So this menu shows the current order and both
# versions before anything else, refuses a downgrade or an unchecked write,
# requires a second distinct word whenever the firmware version moves, honours
# FREEZE_VERSION, and never writes back a config it could not fully read.

# BOOT_ORDER nibble -> mode name (Raspberry Pi bootloader configuration).
# Unknown nibbles are echoed rather than guessed at.
boot_mode_name() {
  case "$1" in
    0) echo "SD-DETECT(deprecated)" ;;
    1) echo "SD/eMMC" ;;
    2) echo "NETWORK" ;;
    3) echo "RPIBOOT" ;;
    4) echo "USB-MSD" ;;
    5) echo "BCM-USB-MSD" ;;
    6) echo "NVME" ;;
    7) echo "HTTP" ;;
    e) echo "STOP" ;;
    f) echo "RESTART" ;;
    *) echo "mode:$1" ;;
  esac
}

# Renders a BOOT_ORDER value the way the bootloader reads it: one boot mode per
# nibble, LEAST significant nibble first, leading zero nibbles being padding
# rather than mode 0. An operator must be able to see "USB-MSD -> NVME -> ..."
# before agreeing to overwrite it, not have to decode 0xf164 by hand.
describe_boot_order() {
  local raw="$1" seq="" c i
  [[ "$raw" =~ ^0[xX][0-9a-fA-F]+$ ]] || { printf '%s' "$raw"; return 0; }
  raw="$(printf '%s' "${raw#0[xX]}" | tr 'A-F' 'a-f')"
  while [[ "$raw" == 0* && ${#raw} -gt 1 ]]; do raw="${raw#0}"; done
  for (( i = ${#raw} - 1; i >= 0; i-- )); do
    c="${raw:i:1}"
    [[ -n "$seq" ]] && seq+=" -> "
    seq+="$(boot_mode_name "$c")"
  done
  printf '%s' "$seq"
  return 0
}

# The module's current bootloader configuration, or nothing plus a reason on
# stderr. Every caller decides WRITE / NO WRITE from this output, so a missing
# tool has to be distinguishable from an empty config and must never be treated
# as "no BOOT_ORDER set".
read_eeprom_config() {
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "rpi-eeprom-config is not installed on this medium (package rpi-eeprom)." >&2
    return 1
  fi
  local out
  # stderr deliberately NOT redirected: when this fails, upstream's own reason
  # ("ERROR: ...vcgencmd bootloader_config..." / a missing blconfig nvmem node)
  # is the diagnosis, and it is the only thing the operator will see.
  out="$(rpi-eeprom-config)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Every BOOT_ORDER assignment together with the section it lives in, as
# "section|value". BOOT_ORDER is legal in conditional sections too, so "the"
# boot order is not necessarily one line and pretending otherwise would let the
# menu report an order the module does not actually follow.
conf_boot_order_lines() {
  awk '
    function strip(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*\[/ { sec = strip($0); next }
    /^[[:space:]]*BOOT_ORDER[[:space:]]*=/ {
      v = $0
      sub(/^[[:space:]]*BOOT_ORDER[[:space:]]*=[[:space:]]*/, "", v)
      printf "%s|%s\n", (sec == "" ? "[all]" : sec), strip(v)
    }
  '
}

# BOOT_ORDER in the default (pre-section / [all]) section only; empty if unset.
conf_default_boot_order() {
  awk '
    function strip(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { inall = 1 }
    /^[[:space:]]*\[/ { inall = (strip($0) == "[all]"); next }
    inall && /^[[:space:]]*BOOT_ORDER[[:space:]]*=/ {
      v = $0
      sub(/^[[:space:]]*BOOT_ORDER[[:space:]]*=[[:space:]]*/, "", v)
      print strip(v); exit
    }
  '
}

# Replaces BOOT_ORDER in the default section, inserting it there if absent.
# Conditional sections are copied through verbatim: silently rewriting a
# [gpio8=0]-style override (which a plain sed/sed-i would do) is exactly the
# surprise this menu must not produce. Usage: <value> [conf-file, default stdin]
conf_set_boot_order() {
  awk -v new="BOOT_ORDER=$1" '
    function strip(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { inall = 1 }
    /^[[:space:]]*\[/ {
      if (strip($0) == "[all]") { inall = 1 } else {
        if (!done && inall) { print new; done = 1 }
        inall = 0
      }
      print; next
    }
    !done && inall && /^[[:space:]]*BOOT_ORDER[[:space:]]*=/ { print new; done = 1; next }
    { print }
    END { if (!done && inall) print new }
  ' "${2:--}"
}

# As conf_set_boot_order, but removes the default-section assignment so the
# bootloader falls back to its built-in order.
conf_drop_boot_order() {
  awk '
    function strip(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { inall = 1 }
    /^[[:space:]]*\[/ { inall = (strip($0) == "[all]"); print; next }
    inall && /^[[:space:]]*BOOT_ORDER[[:space:]]*=/ { next }
    { print }
  ' "${1:--}"
}

# Build timestamp (epoch seconds) of the RUNNING bootloader, from the same two
# sources rpi-eeprom-update uses: device-tree first, vcgencmd as the fallback.
running_bootloader_ts() {
  local f=/proc/device-tree/chosen/bootloader/build-timestamp hex ts line
  if [[ -r "$f" ]]; then
    hex="$(od -An -tx1 -v "$f" 2>/dev/null | tr -d ' \n')"
    if [[ "$hex" =~ ^[0-9a-fA-F]+$ ]]; then printf '%s' "$((16#$hex))"; return 0; fi
  fi
  command -v vcgencmd >/dev/null 2>&1 || return 1
  line="$(vcgencmd bootloader_version 2>/dev/null)" || return 1
  ts="$(awk '/timestamp/ { print $2; exit }' <<<"$line")"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then printf '%s' "$ts"; return 0; fi
  ts="$(date -u -d "$(head -n1 <<<"$line")" +%s 2>/dev/null)"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then printf '%s' "$ts"; return 0; fi
  return 1
}

# The newest image the rpi-eeprom package on this stick offers - i.e. exactly
# the image --apply would write. Empty when the package ships none.
target_bootloader_image() { rpi-eeprom-update -l 2>/dev/null | tail -n1; }

# Timestamp baked into an EEPROM image (the value rpi-eeprom-update compares
# against the running one). Read with grep -a rather than strings, which is not
# guaranteed to be installed here.
image_bootloader_ts() {
  local img="$1" ts
  [[ -n "$img" && -r "$img" ]] || return 1
  ts="$(grep -aom1 -E 'BUILD_TIMESTAMP=[0-9]+' "$img" 2>/dev/null)"
  ts="${ts#BUILD_TIMESTAMP=}"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then printf '%s' "$ts"; return 0; fi
  return 1
}

ts_to_date() {
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then date -u -d "@$1" +%F 2>/dev/null && return 0; fi
  printf 'unknown'
}

# Classifies what a write would do to the bootloader VERSION, independent of the
# config change. Prints "plan|running_ts|image_ts|image_path" with plan one of
# same | upgrade | downgrade | unknown.
eeprom_write_plan() {
  local cur img image plan
  cur="$(running_bootloader_ts || true)"
  image="$(target_bootloader_image)"
  img="$(image_bootloader_ts "${image:-}" || true)"
  if [[ -z "$cur" || -z "$img" ]]; then plan=unknown
  elif (( img > cur )); then plan=upgrade
  elif (( img < cur )); then plan=downgrade
  else plan=same
  fi
  printf '%s|%s|%s|%s\n' "$plan" "${cur:-}" "${img:-}" "${image:-}"
}

# The state that has to be on screen BEFORE anyone may decide: what the module
# boots from now, what firmware is running, and what writing would replace it
# with. Reprinted on every sub-menu redraw, so the operator also sees the effect
# of the change they just made.
show_eeprom_status() {
  local conf found=0 sec val plan cur_ts img_ts image cur_date img_date img_name
  conf="$(read_eeprom_config)" || conf=""
  if [[ -z "$conf" ]]; then
    msg "  No bootloader configuration available - see the reason above."
    msg "  Nothing can be changed until that works."
    return 1
  fi

  while IFS='|' read -r sec val; do
    [[ -n "${sec:-}" ]] || continue
    found=1
    if [[ "$sec" == "[all]" ]]; then
      msg "  Boot order [all]:  $val  ->  $(describe_boot_order "$val")"
    else
      msg "  Boot order $sec:  $val  ->  $(describe_boot_order "$val")"
    fi
  done < <(printf '%s\n' "$conf" | conf_boot_order_lines)
  (( found )) || msg "  Boot order:        not set -> the ROM's built-in order (0xf41, no NVMe)"

  IFS='|' read -r plan cur_ts img_ts image < <(eeprom_write_plan)
  cur_date="$(ts_to_date "${cur_ts:-}")"
  img_date="$(ts_to_date "${img_ts:-}")"
  img_name="none"
  [[ -n "$image" ]] && img_name="$(basename "$image")"
  msg "  Bootloader running:  $cur_date"
  msg "  Image on this stick: $img_date  ($img_name)"
  case "$plan" in
    same)
      msg "  => a write changes the BOOT ORDER ONLY (identical bootloader version)." ;;
    upgrade)
      msg "  => a write ALSO UPGRADES the bootloader $cur_date -> $img_date." ;;
    downgrade)
      msg "  => a write would DOWNGRADE the bootloader - refused by this menu." ;;
    *)
      msg "  => versions not comparable - writes refused by this menu." ;;
  esac

  if grep -qiE '^[[:space:]]*FREEZE_VERSION[[:space:]]*=[[:space:]]*1' <<<"$conf"; then
    msg "  NOTE: FREEZE_VERSION=1 - this module's bootloader is pinned. Refused below."
  fi
  if [[ -e /boot/firmware/pieeprom.upd ]]; then
    msg "  NOTE: a bootloader update is STAGED in /boot/firmware and will be"
    msg "        applied by the next reboot (cancel: rpi-eeprom-update -r)."
  fi
  return 0
}

# The single write path. Refuses more than it accepts, because a bad EEPROM word
# is not recoverable from this menu. Usage: <orig conf> <new conf file>
apply_eeprom_conf() {
  local conf="$1" new_conf="$2"
  local plan cur_ts img_ts image word confirm cur_date img_date

  IFS='|' read -r plan cur_ts img_ts image < <(eeprom_write_plan)
  cur_date="$(ts_to_date "${cur_ts:-}")"
  img_date="$(ts_to_date "${img_ts:-}")"
  case "$plan" in
    same) word="YES" ;;
    upgrade) word="UPGRADE" ;;
    downgrade)
      msg ""
      msg "REFUSED: the bootloader image on this stick ($img_date) is OLDER than the"
      msg "one running in this module ($cur_date), so applying a config here would"
      msg "downgrade the bootloader. rpi-eeprom-update would also stop on this"
      msg "(confirmDowngrade refuses without -y), but it asks on /dev/tty from inside"
      msg "rpi-eeprom-config, so stop it here instead. Refresh the install image's"
      msg "rpi-eeprom package (or apt upgrade rpi-eeprom on the stick) instead."
      return 1
      ;;
    *)
      msg ""
      msg "REFUSED: either the running bootloader version or the version of the image"
      msg "this stick would write cannot be determined, so the write cannot be checked."
      msg "With an unreadable running version rpi-eeprom-update treats the write as a"
      msg "possible downgrade and refuses it for the same reason (no -y is passed)."
      return 1
      ;;
  esac

  if grep -qiE '^[[:space:]]*FREEZE_VERSION[[:space:]]*=[[:space:]]*1' <<<"$conf"; then
    msg ""
    msg "REFUSED: FREEZE_VERSION=1 - this module's bootloader is deliberately pinned."
    msg "rpi-eeprom-config --apply bypasses that flag, so it is honoured here instead."
    msg "Unpinning a module is a maintenance decision, not a side effect of setting a"
    msg "boot order. See 'rpi-eeprom-update -r' / the bootloader recovery flow."
    return 1
  fi

  msg ""
  msg "Writes:  $(basename "${image:-<no image>}") - bootloader $img_date"
  msg "         into the module's SPI flash. The new order takes effect on the next boot."
  if [[ "$plan" == "same" ]]; then
    msg "         Bootloader version UNCHANGED ($cur_date): this replaces only the"
    msg "         configuration inside the firmware release already running here."
  fi
  msg "On CM5 this is normally an IMMEDIATE A/B re-flash taking up to a minute:"
  msg "*** do NOT remove power while it runs. ***"
  if [[ "$word" == "UPGRADE" ]]; then
    msg ""
    msg "This is NOT just a boot-order change. It also replaces the bootloader firmware"
    msg "$cur_date -> $img_date. Upstream checks that release's manufacture version"
    msg "(MFG_VER) against this module and stops if it is too old, but nothing here has"
    msg "validated the release itself for this product's boot flow."
  fi
  # The required word is echoed as a message and not only as the read prompt:
  # bash prints a `read -p` prompt only when stdin is a terminal, so over ssh -
  # or in a test - the operator would be asked to type something they cannot see.
  msg ""
  msg "Type $word (uppercase) to apply, anything else cancels."
  read -rp "Confirm: " confirm
  if [[ "$confirm" != "$word" ]]; then
    msg "Aborted."
    return 1
  fi

  if rpi-eeprom-config --apply "$new_conf"; then
    msg ""
    msg "Applied. Verify after the next reboot with:  rpi-eeprom-config | grep BOOT_ORDER"
    return 0
  fi
  msg ""
  msg "rpi-eeprom-config --apply FAILED - see its output above; nothing was changed"
  msg "unless it reported an immediate update, in which case treat the module as QC."
  return 1
}

# Renders current vs. new order, then writes. Empty <value> drops the override
# so the bootloader uses its built-in order.
eeprom_change_boot_order() {
  local value="${1:-}" meaning="${2:-}"
  local conf n cur outside tmp rc

  conf="$(read_eeprom_config)" || conf=""
  if [[ -z "$conf" ]]; then
    msg "Could not read the bootloader configuration; nothing written."
    return 1
  fi

  # A short read means the config never really came back (no root, no vcgencmd,
  # no blconfig nvmem). Writing it back would blank the module's EEPROM config
  # - rpi-eeprom-update refuses to propagate such configs for the same reason.
  n="$(printf '%s\n' "$conf" | grep -c .)"
  if (( n < 3 )); then
    msg "REFUSED: the bootloader config read back as $n line(s); writing that back would"
    msg "blank the module's EEPROM configuration."
    return 1
  fi

  cur="$(printf '%s\n' "$conf" | conf_default_boot_order)"
  outside="$(printf '%s\n' "$conf" | conf_boot_order_lines | awk -F'|' '$1 != "[all]" { printf "%s=%s ", $1, $2 }')"

  msg ""
  if [[ -n "$outside" ]]; then
    msg "NOTE: BOOT_ORDER is also set outside [all] ($outside). Those lines are left"
    msg "untouched - the change below only concerns the default section."
  fi
  [[ -n "$meaning" ]] && msg "$meaning"

  tmp="$(mktemp)"
  if [[ -n "$value" ]]; then
    if [[ -n "$cur" && "${cur,,}" == "${value,,}" ]]; then
      msg "Boot order is already $value - no EEPROM write needed."
      rm -f "$tmp"
      return 0
    fi
    if [[ -n "$cur" ]]; then
      msg "Current boot order:  $cur  ->  $(describe_boot_order "$cur")"
    else
      msg "Current boot order:  not set in [all] -> the ROM's built-in order"
    fi
    msg "New boot order:      $value  ->  $(describe_boot_order "$value")"
    printf '%s\n' "$conf" | conf_set_boot_order "$value" > "$tmp"
  else
    if [[ -z "$cur" ]]; then
      msg "No BOOT_ORDER in the default section - the ROM built-in order already applies."
      rm -f "$tmp"
      return 0
    fi
    msg "Current boot order:  $cur  ->  $(describe_boot_order "$cur")"
    msg "New boot order:      unset -> the ROM's built-in order, documented as 0xf41"
    msg "                     (SD/eMMC, then USB-MSD, then repeat): NO NVMe entry, so"
    msg "                     this is NOT the same as the 0xf461 platform default."
    printf '%s\n' "$conf" | conf_drop_boot_order > "$tmp"
  fi

  apply_eeprom_conf "$conf" "$tmp"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# Options 3 and 4 of the main menu used to be two blind writes; they are one
# sub-menu now so the current order is always visible when choosing between them.
boot_order_menu() {
  local choice
  while true; do
    clear
    msg "========================================"
    msg "     Bootloader EEPROM / boot order"
    msg "========================================"
    if ! show_eeprom_status; then pause; continue; fi
    msg "----------------------------------------"
    msg "  1) 0xf164 USB, NVMe, eMMC      (USB priority)"
    msg "  2) 0xf461 eMMC, NVMe, USB      (eMMC with NVMe)"
    msg "  3) 0xf14  USB, eMMC            (USB priority, no NVMe)"
    msg "  4) unset  eMMC, USB            (ROM default, removes BOOT_ORDER)"
    msg "  5) Show the full EEPROM config"
    msg "  6) Back"
    msg "========================================"
    read -rp "Select an option: " choice
    case "$choice" in
      1) eeprom_change_boot_order 0xf164 "USB priority: the USB stick if present, then NVMe, then eMMC."
         pause ;;
      2) eeprom_change_boot_order 0xf461 "Platform default: eMMC first, NVMe next, USB only as fallback."
         pause ;;
      3) eeprom_change_boot_order 0xf14 "USB priority without the NVMe step: the USB stick if present, then eMMC."
         pause ;;
      4) eeprom_change_boot_order ""
         pause ;;
      5) msg ""; read_eeprom_config || msg "(no config)"; pause ;;
      6) return 0 ;;
      *) msg "Invalid option."; pause ;;
    esac
  done
}

run_board_tests() {
  local script="$PROVISIONING_DIR/run-board-tests.sh"
  if [[ ! -x "$script" ]]; then
    msg "Test runner not found: $script"
    pause
    return
  fi

  "$script"
  pause
}

# Is the RUNNING system an overlaid (read-only) root? The mount is the truth here,
# not /proc/cmdline: the command line records what was REQUESTED, and a request can
# be lost (the token has to be on the first line of cmdline.txt for the firmware to
# pass it on), so reporting the mount keeps the banner honest even about a stick
# whose cmdline.txt was edited by hand.
overlayfs_status() {
  if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "overlay" ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

# Add or drop the overlayroot token in the firmware's cmdline.txt. Every part of
# this is load-bearing: the file must stay a SINGLE line, because the firmware
# appends it to the kernel command line and ignores everything after the first
# line, so appending a second line is silently a no-op. Hence: read the whole
# file, strip any overlayroot token and stray whitespace, re-add when enabling,
# write back one line with one trailing newline. Non-zero if the vfat is not
# writable.
set_overlayroot_token() { # set_overlayroot_token <add|drop>
  local mode=${1:-} cmdline="/boot/firmware/cmdline.txt" line
  [[ "$mode" == "add" || "$mode" == "drop" ]] || return 2
  [[ -f "$cmdline" ]] || return 1
  line="$(tr -d '\n\r' < "$cmdline")"
  line="$(printf '%s' "$line" |
    sed -E 's/[[:space:]]*overlayroot=[^[:space:]]*//g; s/[[:space:]]{2,}/ /g; s/[[:space:]]+$//')"
  [[ "$mode" != "add" ]] || line="$line overlayroot=tmpfs"
  # Never add `ro` alongside it: the read-only lower layer comes from the
  # initramfs' default readonly=y, while an `ro` parameter turns into
  # overlayroot's cmdline_ro and remounts the OVERLAY read-only, which would
  # break apt, passwd and the EEPROM staging this menu does in the session.
  printf '%s\n' "${line# }" > "$cmdline"
}

toggle_overlayfs() {
  local current mode action
  current="$(overlayfs_status)"
  if [[ "$current" == "enabled" ]]; then
    mode="drop"
    action="disable"
    msg "This stick is running a READ-ONLY root: / is a temporary overlay in RAM"
    msg "above the ext4 partition, which is mounted read-only at /media/root-ro."
    msg "Everything written to / - apt installs, passwd, hand edits, logs - is"
    msg "gone at the next reboot. Disabling it makes the root persistent (and"
    msg "writable) again."
  else
    mode="add"
    action="enable"
    msg "This stick is running its ext4 root directly: writes to / survive a"
    msg "reboot. Enabling the read-only overlay puts a temporary RAM layer over"
    msg "the root partition, discarding every write to / made after the change."
  fi

  msg "Note: this only affects the install medium (this USB stick) itself, not any"
  msg "system flashed with option 1."
  msg "The boot partition is never overlaid, so this setting - and only this"
  msg "setting - is kept. The system will reboot after the change to apply it."
  msg ""
  local confirm
  # Prompt on stderr explicitly rather than with read -p: read only prints its
  # prompt when stdin is a terminal, and this menu also gets driven over pipes.
  printf '%s it? (y/N): ' "$action" >&2
  read -r confirm
  if [[ ! "$confirm" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    msg "Aborted."
    pause
    return
  fi

  if ! set_overlayroot_token "$mode"; then
    msg "Could not rewrite /boot/firmware/cmdline.txt - is the boot partition"
    msg "mounted read-only, or missing? Nothing was changed; no reboot."
    pause
    return
  fi

  # No update-initramfs here, deliberately: nothing in the initrd reads
  # cmdline.txt. overlayroot's initramfs script parses the kernel command line
  # at boot - where it outranks /etc/overlayroot.conf - and it ships in this
  # initrd already, so the toggle takes effect on the next boot regardless.
  msg ""
  msg "New kernel command line:"
  msg "  $(tr -d '\n' < /boot/firmware/cmdline.txt)"
  sync
  msg "Read-only root setting updated. Rebooting for it to take effect..."
  reboot
}

main_menu() {
  while true; do
    clear
    cat <<EOF
========================================
   OpenMux Console - Install Medium
========================================
  1) Install image to disk
  2) Serial numbers and serial ports
  3) Boot order / bootloader EEPROM
  4) Run board tests (console ports)
  5) Drop to shell
  6) Reboot
  7) Power off
  8) Toggle USB stick read-only mode (currently: $(overlayfs_status))
========================================
EOF
    local choice
    read -rp "Select an option: " choice
    case "$choice" in
      1) do_install ;;
      2) serial_menu ;;
      3) boot_order_menu ;;
      4) run_board_tests ;;
      5) drop_to_shell ;;
      6) reboot ;;
      7) poweroff ;;
      8) toggle_overlayfs ;;
      *) msg "Invalid option."; pause ;;
    esac
  done
}

main_menu
