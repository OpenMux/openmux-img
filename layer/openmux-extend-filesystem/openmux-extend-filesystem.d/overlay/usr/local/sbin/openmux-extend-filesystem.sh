#!/bin/sh
# openmux-extend-filesystem.sh - grow the root partition + ext4 filesystem
# to fill the whole disk.
#
# Runs from the openmux-extend-filesystem oneshot unit. It does the work
# once (growpart + online resize2fs, mirroring the rpi-image-gen
# cm5-jig-growfs reference); a stamp file + the unit's ConditionPathExists
# keep every later boot a no-op. Only the ext4 root partition is touched -
# the vfat boot partition keeps its build-time size.
set -eu
# systemd's default PATH is fine for all of these, but be explicit.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Run-once: a stamp file makes later boots a no-op; the unit's
# ConditionPathExists=!<stamp> additionally keeps it from even starting.
stamp=/var/lib/openmux/growfs-done
[ -e "$stamp" ] && exit 0

# Mounted root's backing path, e.g. /dev/root or /dev/disk/by-slot/system.
root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
case "$root_src" in
    /dev/*) : ;;
    *) echo "openmux-extend-filesystem: root source '$root_src' not a block device; skipping" >&2
       exit 0 ;;
esac

# Resolve the symlink before deriving names. The kernel can boot by slot
# (root=/dev/disk/by-slot/system), so findmnt may report that path rather
# than the underlying node - whose basename is neither a disk nor a part.
root_dev=$(readlink -f "$root_src" 2>/dev/null || true)
case "$root_dev" in
    /dev/*) : ;;
    *) echo "openmux-extend-filesystem: cannot resolve '$root_src' to a device node; skipping" >&2
       exit 0 ;;
esac
name=$(basename "$root_dev")

# Parent disk: prefer lsblk PKNAME, else strip the trailing partition
# suffix (handles nvme0n1p2 / mmcblk0p2 -> ...p<N> and sdaN).
disk=$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -n1 || true)
[ -n "$disk" ] || disk=$(printf '%s' "$name" | sed -E 's/p?[0-9]+$//')

# Partition number: prefer sysfs, else the trailing digits of the name.
part=$(cat "/sys/class/block/$name/partition" 2>/dev/null || true)
[ -n "$part" ] || part=$(printf '%s' "$name" | sed -E 's/.*[^0-9]([0-9]+)$/\1/')

# Both must be present AND well-formed. A non-numeric part reaches growpart
# and is rejected; with the failure swallowed and the stamp written anyway
# the disk would stay small forever with nothing in the journal to say why.
case "$part" in
    ''|*[!0-9]*) echo "openmux-extend-filesystem: '$part' is not a partition number for $root_dev; skipping" >&2
                 exit 0 ;;
esac
[ -n "$disk" ] || { echo "openmux-extend-filesystem: could not resolve parent disk for $root_dev; skipping" >&2; exit 0; }

# growpart reports NOCHANGE (exit 1) when the partition already fills the
# disk, so there is no separate size comparison to perform up front.

# growpart exits 0 when it resized, 1 when no change was needed, 2 on a real
# error. Only 0/1 leave the partition at the right size; anything else must
# not be stamped so the next boot retries. `cmd || rc=$?` (not `cmd; rc=$?`)
# so NOCHANGE's non-zero exit does not trip `set -e`.
rc=0
growpart "/dev/$disk" "$part" || rc=$?
case "$rc" in
    0|1) : ;;
    *) echo "openmux-extend-filesystem: growpart /dev/$disk $part failed (exit $rc); not stamping" >&2
       exit 1 ;;
esac

# Online ext4 grow over the path that is actually mounted; a no-op when the
# filesystem already fills the partition. A normal first boot mounts /
# read-write, which is what online resize requires.
resize2fs "$root_src"

mkdir -p "$(dirname "$stamp")"
: > "$stamp"
logger -t openmux-extend-filesystem "root filesystem expansion complete on /dev/$disk$part" || true
