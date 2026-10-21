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

set_internal_serial() {
  local script="$PROVISIONING_DIR/program-ftdi-internal.py"
  if [[ ! -x "$script" ]]; then
    msg "Provisioning script not found: $script"
    pause
    return
  fi

  local base
  read -rp "Enter internal serial base, e.g. OMH1234 -> OMH1234-A/B (or 'q' to cancel): " base
  [[ "$base" == "q" ]] && return
  [[ -n "$base" ]] || { msg "Serial base cannot be empty."; pause; return; }

  "$script" "$base"
  pause
}

# BOOT_ORDER nibbles are tried lowest-to-highest significance: 4=USB-MSD, 6=NVME, 1=SD/eMMC, f=restart.
set_boot_order_usb_first() {
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    msg "rpi-eeprom-config not found; this device may not use an EEPROM bootloader."
    pause
    return
  fi

  local tmp_conf
  tmp_conf="$(mktemp)"
  rpi-eeprom-config > "$tmp_conf" 2>/dev/null

  if grep -q '^BOOT_ORDER=' "$tmp_conf"; then
    sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf164/' "$tmp_conf"
  else
    echo "BOOT_ORDER=0xf164" >> "$tmp_conf"
  fi

  msg ""
  msg "This sets BOOT_ORDER=0xf164: USB first, then NVMe, then eMMC/SD, then repeat."
  msg "The bootloader EEPROM is updated; the new order takes effect after a reboot."
  local confirm
  read -rp "Type YES (uppercase) to apply, or anything else to cancel: " confirm
  if [[ "$confirm" != "YES" ]]; then
    msg "Aborted."
    rm -f "$tmp_conf"
    pause
    return
  fi

  if rpi-eeprom-config --apply "$tmp_conf"; then
    msg "Boot order update scheduled. Reboot for it to take effect."
  else
    msg "Failed to apply boot order change."
  fi
  rm -f "$tmp_conf"
  pause
}

# Dropping the BOOT_ORDER override lets the bootloader fall back to its stock firmware default.
restore_boot_order_default() {
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    msg "rpi-eeprom-config not found; this device may not use an EEPROM bootloader."
    pause
    return
  fi

  local tmp_conf
  tmp_conf="$(mktemp)"
  rpi-eeprom-config > "$tmp_conf" 2>/dev/null

  if ! grep -q '^BOOT_ORDER=' "$tmp_conf"; then
    msg "No BOOT_ORDER override is set; this board is already using the stock default."
    rm -f "$tmp_conf"
    pause
    return
  fi

  sed -i '/^BOOT_ORDER=/d' "$tmp_conf"

  msg ""
  msg "This removes the BOOT_ORDER override so the bootloader falls back to its stock default."
  msg "The bootloader EEPROM is updated; the change takes effect after a reboot."
  local confirm
  read -rp "Type YES (uppercase) to apply, or anything else to cancel: " confirm
  if [[ "$confirm" != "YES" ]]; then
    msg "Aborted."
    rm -f "$tmp_conf"
    pause
    return
  fi

  if rpi-eeprom-config --apply "$tmp_conf"; then
    msg "Default boot order restored. Reboot for it to take effect."
  else
    msg "Failed to restore default boot order."
  fi
  rm -f "$tmp_conf"
  pause
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

overlayfs_status() {
  if grep -q 'overlayroot=tmpfs' /proc/cmdline 2>/dev/null; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

toggle_overlayfs() {
  local current target action
  current="$(overlayfs_status)"
  if [[ "$current" == "enabled" ]]; then
    target=1
    action="disable"
    msg "The overlay root filesystem is currently ENABLED: writes to the root"
    msg "filesystem are discarded on reboot. Disabling it makes the filesystem"
    msg "persistent (writable) again."
  else
    target=0
    action="enable"
    msg "The overlay root filesystem is currently DISABLED: the filesystem is"
    msg "persistent (writable). Enabling it makes the root filesystem read-only,"
    msg "discarding all writes to it on reboot."
  fi

  msg "Note: this only affects the install medium (this USB stick) itself, not any"
  msg "system flashed with option 1."
  msg "The system will reboot after the change to apply it."
  msg ""
  local confirm
  read -rp "$action it? (y/N): " confirm
  if [[ ! "$confirm" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    msg "Aborted."
    pause
    return
  fi

  # Minbase has no raspi-config; toggle the parameter by editing
  # /boot/firmware/cmdline.txt directly and refreshing the initramfs.
  local cmdline="/boot/firmware/cmdline.txt"
  if [[ ! -f "$cmdline" ]]; then
    msg "cmdline.txt not found at $cmdline."
    pause
    return
  fi

  if [[ "$target" == 1 ]]; then
    grep -qw 'overlayroot=tmpfs' "$cmdline" || printf 'overlayroot=tmpfs\n' >> "$cmdline"
  else
    sed -i 's/ *overlayroot=tmpfs//; s/  */ /g; s/ *$//' "$cmdline"
  fi

  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u >/dev/null 2>&1 || \
      msg "WARNING: update-initramfs -u failed; the change may not take effect until the next boot."
  fi

  msg "Overlay filesystem setting updated. Rebooting for it to take effect..."
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
  2) Set internal serial number
  3) Set boot order (USB first)
  4) Restore default boot order
  5) Run board tests
  6) Drop to shell
  7) Reboot
  8) Power off
  9) Toggle read-only overlay filesystem (currently: $(overlayfs_status))
========================================
EOF
    local choice
    read -rp "Select an option: " choice
    case "$choice" in
      1) do_install ;;
      2) set_internal_serial ;;
      3) set_boot_order_usb_first ;;
      4) restore_boot_order_default ;;
      5) run_board_tests ;;
      6) drop_to_shell ;;
      7) reboot ;;
      8) poweroff ;;
      9) toggle_overlayfs ;;
      *) msg "Invalid option."; pause ;;
    esac
  done
}

main_menu
