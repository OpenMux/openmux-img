#!/usr/bin/env python3
"""Program the EEPROM of the three FTDI chips on an OpenMux EX-12 expansion card.

A card carries three FT4232H chips behind its own USB hub and is written
BASE-A, BASE-B, BASE-C, where BASE is the card serial.  Chip A owns interfaces
0-3 (ports 1-4), B ports 5-8, C ports 9-12, exactly as
/etc/udev/rules.d/99-openmux-ftdi.rules expects, so the card's ports appear
under /dev/openmux/<BASE>/portN.

THE ONE THING THAT MATTERS IN THIS FILE: the console's own FTDI chips sit on the
same hub as a plugged-in card (console 2-1.1 and 2-1.2, card hub typically
2-1.4), they are the same vid:pid, and a card fresh from the factory has no
serial to tell anyone apart.  So "flash every 0403:6011 under this path"
reprograms the console if the path is one port too high - which silently deletes
/dev/openmux/port5-8 and makes the console's second chip answer as a card's
ports 1-4, with no error anywhere in the system.  Everything here resolves and
re-checks USB *paths* against the console's path set, and never treats a vid:pid
as proof of what a chip is.  Those topology rules and guards live in
scan_ftdi.py so this tool, program-ftdi-internal.py and the scanner cannot
drift apart.

There is deliberately no flag to override the console guard.  If this board's
console chips are not where the defaults say they are, the honest fix is to say
where they are with --internal (or $OPENMUX_FTDI_INTERNAL_PATHS), which keeps
the guard intact; a bypass switch would only make the guard decorative.

Examples:
  scan-ftdi-adapters.py                      # what is plugged in, and why
  program-ftdi-external.py OMX000042         # find the one card, program it
  program-ftdi-external.py OMX000042 --adapter 2-1.4
  program-ftdi-external.py --verify OMX000042  # prove the port map, then wire-test:
  run-board-tests.sh --port-base /dev/openmux/OMX000042 --pairs card
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import scan_ftdi as F  # noqa: E402

MANUFACTURER_DEFAULT = "OpenMux"
# Written into the chip's EEPROM, so it outlives every rebuild of this repo: a
# unit already flashed keeps the string it was given until it is reprogrammed.
# The capital X in "eXtention" is deliberate - it is the X in OMX.
PRODUCT_DEFAULT = "OpenMux eXtention EX-12"
CHIP_COUNT = len(F.CHIP_ORDER)


def build_parser():
    ap = argparse.ArgumentParser(
        description="Program the serials of an OpenMux EX-12 adapter's three FTDI chips.",
        epilog="The console's own FTDI chips live on the same hub and are always refused "
               "as targets. Nothing is written without a typed confirmation.")
    ap.add_argument("serial_number", nargs="?",
                    help='card serial base, e.g. "OMX000042" -> OMX000042-A/-B/-C')
    ap.add_argument("--adapter", "--usb-path", dest="adapter", default=None,
                    help="bus-port path of the adapter's own hub. Omit it to auto-detect "
                         "the one adapter group on the bus; it is re-checked against the "
                         "console's paths either way, before anything is written")
    ap.add_argument("--devices-dir", default="/sys/bus/usb/devices",
                    help="sysfs USB tree (default: %(default)s)")
    ap.add_argument("--internal", default=None,
                    help=f"the console's FTDI paths, comma separated (default: "
                         f"{','.join(F.INTERNAL_PATHS_DEFAULT)}, or "
                         f"${F.INTERNAL_PATHS_ENV}). Use this, not a bypass, if a board "
                         f"enumerates its console elsewhere")
    ap.add_argument("--manufacturer", help="override the EEPROM manufacturer string")
    ap.add_argument("--product", help="override the EEPROM product string")
    ap.add_argument("--env-file", default=F.ENV_FILE_DEFAULT,
                    help=f"identity/prefix defaults (default: %(default)s)")
    ap.add_argument("--allow-partial", action="store_true",
                    help="program fewer than %d chips, for bench work on a hub that "
                         "exposes only part of a card" % CHIP_COUNT)
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve, guard and print the plan without writing")
    ap.add_argument("--yes", action="store_true",
                    help="skip the typed confirmation (scripted use only)")
    ap.add_argument("--verify", metavar="BASE",
                    help="do not program: audit the port numbering under "
                         "/dev/openmux/BASE and exit non-zero if any port is misplaced")
    ap.add_argument("--port-root", default="/dev/openmux",
                    help="where per-adapter port folders live (default: %(default)s)")
    ap.add_argument("--sys-tty-dir", default="/sys/class/tty")
    return ap


def die(message, devices):
    """Refuse, and show what IS connected.

    A near-miss path is the failure mode worth teaching about, so a refusal never
    leaves the operator guessing what the tool saw."""
    print(f"ERROR: {message}", file=sys.stderr)
    if not devices:
        print("ERROR: no FTDI devices visible at all - is the adapter powered and the "
              "cable seated?", file=sys.stderr)
        sys.exit(2)
    print("\nWhat is actually connected:", file=sys.stderr)
    for dev in devices:
        print(f"  {dev['path']:<10} hub={dev['parent'] or '-':<8} {dev['role']:<8} "
              f"serial={dev['serial']} product='{dev['product']}'", file=sys.stderr)
    print("\nscan-ftdi-adapters.py lists the same things with the reason for each role; "
          "its --diff-with\nidentifies a device by having you plug it in.",
          file=sys.stderr)
    sys.exit(2)


def resolve_hub(adapter_arg, devices, internal_paths):
    """(hub_path, note) for the adapter to program; exits with a diagnosis if not.

    A path is not permission. --adapter 2-1 is a perfectly real bus-port path, and
    its children include 2-1.2 - the console's own second chip - which is a valid
    FT4232H and would pass any descriptor check. So the hub is validated against
    the console subtree before chips are listed, not after."""
    groups = F.group_by_parent(F.adapters(devices))

    if adapter_arg:
        why = F.guard_hub(adapter_arg, internal_paths, devices)
        if why:
            die(why, devices)
        return adapter_arg, "named with --adapter"

    if not groups:
        die("no external FTDI adapter found", devices)
    if len(groups) > 1:
        die("more than one adapter group on the bus (%s); program one at a time and "
            "name it with --adapter" % ", ".join(sorted(groups)), devices)
    (hub, members), = groups.items()
    return hub, f"auto-detected, {len(members)} chip(s)"


def pick_targets(hub, devices, allow_partial):
    """[(chip letter, path, device row)] for one adapter, in physical port order.

    Chip letters follow the order the chips enumerate under the hub - the same
    assumption the udev rules make - and the mapping is printed before anything is
    written, so a hub that enumerates backwards shows up on the confirmation
    screen instead of in the field.
    """
    members = sorted((d for d in devices
                      if d["parent"] == hub and d["role"] != "console"),
                     key=lambda d: F.path_sort_key(d["path"]))
    if not members:
        die(f"no FTDI chip under {hub}", devices)
    if len(members) > CHIP_COUNT:
        die(f"{len(members)} FTDI chips under {hub} and an EX-12 has {CHIP_COUNT}; this "
            f"hub may be shared with other equipment", devices)
    if len(members) < CHIP_COUNT and not allow_partial:
        die(f"only {len(members)} of {CHIP_COUNT} chips answer under {hub}; a card with "
            f"a dead chip would ship with unreachable ports (pass --allow-partial if "
            f"this is deliberate bench work)", devices)
    return list(zip(F.CHIP_ORDER, [d["path"] for d in members], members))


def make_conf(serial, manufacturer, product):
    return f"""vendor_id=0x0403
product_id=0x6011
manufacturer="{manufacturer}"
product="{product}"
serial="{serial}"
self_powered=true
max_power=0
use_serial=true
remote_wakeup=false
"""


def reassert(path, hub, internal_paths, devices_dir, expected_previous):
    """Resolve one target afresh, immediately before it is flashed.

    The plan above was printed moments ago, but flashing a chip makes the whole
    adapter re-enumerate - every chip under the hub gets new bus/dev numbers, not
    just the one written - and so does nudging the cable. Addressing
    d:BBB/DDD from a scan taken before the operator typed "y" can therefore reach
    a different chip by the time the write happens, and nothing would complain:
    the numbers still name a real FT4232H. Hence: re-scan, re-check, then read
    the numbers."""
    devices = F.scan(devices_dir, internal_paths=internal_paths)
    dev = next((d for d in devices if d["path"] == path), None)
    if dev is None:
        raise RuntimeError(f"{path} has disappeared from the bus")

    why = F.guard_target(path, hub, internal_paths, devices)
    if why:
        raise RuntimeError(f"{path} is no longer a safe target: {why}")
    if dev["serial"] != expected_previous:
        raise RuntimeError(f"{path} now reports serial '{dev['serial']}' instead of the "
                           f"'{expected_previous}' the plan was built on; something "
                           f"re-enumerated or was swapped mid-run")
    if dev["bus"] == "0" or dev["dev"] == "0":
        raise RuntimeError(f"{path} has no bus/dev address yet (bus {dev['bus']}, "
                           f"dev {dev['dev']}); it is still enumerating, wait a moment "
                           f"and re-run")
    return dev


def flash(dev, serial, manufacturer, product, dry_run):
    """Write one chip, addressed by freshly read bus/dev numbers."""
    device_url = f"d:{int(dev['bus']):03d}/{int(dev['dev']):03d}"
    cmd = ["sudo", "ftdi_eeprom", "--device", device_url, "--flash-eeprom"]
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".conf",
                                    prefix="openmux-ext-") as handle:
        handle.write(make_conf(serial, manufacturer, product))
        conf_path = handle.name
    cmd.append(conf_path)

    print(f"  {dev['path']}  {device_url}  serial -> {serial}")
    print("  " + make_conf(serial, manufacturer, product).strip().replace("\n", "\n  "))
    if dry_run:
        print(f"  [dry-run] {' '.join(cmd)}")
        return
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ftdi_eeprom failed for {dev['path']}\n"
                           f"  cmd:  {' '.join(cmd)}\n"
                           f"  exit: {proc.returncode}\n"
                           f"  {proc.stdout.strip()}\n  {proc.stderr.strip()}")


def run_verify(base, port_root, sys_tty_dir):
    """Audit a programmed card's port map. Also what the install menu calls."""
    port_base = os.path.join(port_root, base)
    rows, ok = F.numbering_audit(port_base, sys_tty_dir=sys_tty_dir)
    print(f"Adapter port audit: {port_base}")
    if not rows:
        print("  nothing under here. If the card was just programmed, unplug it and plug")
        print("  it back in first: the symlinks are created at plug-in from the EEPROM")
        print("  contents, so a freshly written card has no folder until it replugs.")
        print(f"  If it was already replugged and this is still empty, the serial the")
        print(f"  chip holds does not match the prefix in 99-openmux-ftdi.rules.")
        return 1
    for row in rows:
        iface = "?" if row["iface"] is None else f"{row['iface']}"
        verdict = "OK" if row["ok"] else f"WRONG: {row['detail']}"
        print(f"  port{row['port']:<3} {row['tty']:<9} chip {row['chip']} if{iface}  {verdict}")
    bad = [r for r in rows if not r["ok"]]
    print(f"  {len(rows) - len(bad)}/{len(rows)} ports where the udev rules put them")
    if bad:
        print("  A misplaced port is a programming fault (which chip got which serial) or")
        print("  a udev prefix mismatch - not a wiring fault. Do not chase a loopback")
        print("  cable over this one.")
    return 0 if ok else 1


def main():
    args = build_parser().parse_args()

    if args.verify:
        return run_verify(args.verify, args.port_root, args.sys_tty_dir)

    if args.serial_number is None:
        print("ERROR: a serial base is required, or use --verify BASE to check a card "
              "that is already programmed", file=sys.stderr)
        return 2

    if not args.dry_run and subprocess.run(
            ["bash", "-lc", "command -v ftdi_eeprom"], capture_output=True).returncode != 0:
        # See program-ftdi-internal.py: name the fix, not just the gap.
        print("ERROR: missing tool: ftdi_eeprom (package ftdi-eeprom, in trixie main)")
        print("       apt-get install -y ftdi-eeprom")
        return 1

    internal_paths = (tuple(p for p in args.internal.replace(",", " ").split() if p)
                      if args.internal else F.internal_paths_from_env())
    devices = F.scan(args.devices_dir, internal_paths=internal_paths)

    hub, note = resolve_hub(args.adapter, devices, internal_paths)
    targets = pick_targets(hub, devices, args.allow_partial)

    # Each individual target again, the same bidirectional checks
    # program-ftdi-internal.py runs: the two tools differ only in which side of
    # the hub they point at.
    console_rows = F.console(devices)
    unsafe = [(path, F.guard_target(path, hub, internal_paths, devices,
                                    console_strings=[d["serial"] for d in console_rows]))
              for _, path, _ in targets]
    for path, why in [pair for pair in unsafe if pair[1]]:
        print(f"ERROR: {path}: {why}", file=sys.stderr)
    if any(why for _, why in unsafe):
        die("refusing to program this adapter", devices)

    ok_base, errors, warnings = F.validate_base(args.serial_number.strip(),
              F.resolve_identity(F.load_env_file(args.env_file),
                                 F.KEY_PREFIX_EXTERNAL,
                                 default=F.PREFIX_EXTERNAL_DEFAULT))
    for message in errors:
        print(f"ERROR: serial base {args.serial_number!r}: {message}", file=sys.stderr)
    if not ok_base:
        return 2

    base = args.serial_number.strip()
    conflict = F.find_serial_conflict(base, devices)
    if conflict:
        print(f"ERROR: {conflict}.", file=sys.stderr)
        print(f"       Two devices answering to one /dev/openmux/{base} folder would "
              f"fight over the same\n       ports, and openmux-detect-hardware would "
              f"report one machine for both.", file=sys.stderr)
        print("       scan-ftdi-adapters.py --serials shows what is programmed here.",
              file=sys.stderr)
        return 2

    env = F.load_env_file(args.env_file)
    manufacturer = F.resolve_identity(env, F.KEY_MANUFACTURER, args.manufacturer,
                                      MANUFACTURER_DEFAULT)
    product = F.resolve_identity(env, F.KEY_PRODUCT_EXTERNAL, args.product,
                                 PRODUCT_DEFAULT)

    print(f"Adapter hub {hub} ({note})")
    print("Will write, in this order:")
    for chip, path, dev in targets:
        print(f"  {path:<10} serial={base}-{chip:<3} was '{dev['serial']}' "
              f"product='{dev['product']}'")
    print(f'  manufacturer="{manufacturer}"')
    print(f'  product="{product}"')
    print("")
    print("Ports this creates, after an unplug/replug:")
    print(f"  " + " ".join(f"{args.port_root}/{base}/port{4 * i + n}"
                           for i in range(len(targets)) for n in (1, 2, 3, 4)))
    if console_rows:
        print("\nConsole chips on this bus, which this run will NOT touch: "
              + ", ".join(f"{d['path']} ({d['serial']})" for d in console_rows))
    else:
        print(f"\nWARNING: no console FTDI chip found at {', '.join(internal_paths)}. On a "
              f"real OpenMux\n         there is always one; if the console is not "
              f"enumerating, the guards above are\n         comparing against path names "
              f"only and nothing has been proven.")
    for message in warnings:
        print(f"WARNING: serial base {base!r}: {message}", file=sys.stderr)

    # --yes is the only thing that silences this, including in --dry-run: the
    # rehearsal should be the same run the operator will do for real, prompt and
    # all, and a confirmation that vanishes depending on another flag is one the
    # operator has to re-learn at the worst moment.
    if not args.yes:
        try:
            answer = input("Proceed with flashing? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 1

    programmed = []
    try:
        for chip, path, dev in targets:
            fresh = reassert(path, hub, internal_paths, args.devices_dir, dev["serial"])
            flash(fresh, f"{base}-{chip}", manufacturer, product, args.dry_run)
            programmed.append(path)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        if programmed:
            print(f"\nThe card is now PARTIALLY programmed: {', '.join(programmed)} took "
                  f"a new serial, and\n{hub} re-enumerated when it did, so nothing under "
                  f"it still matches the plan.", file=sys.stderr)
            print("Do not assume the other chips are untouched. Replug the card, then:",
                  file=sys.stderr)
            print(f"  scan-ftdi-adapters.py --serials", file=sys.stderr)
            print(f"  program-ftdi-external.py {base}   # again; it is safe to re-flash",
                  file=sys.stderr)
        return 1

    print("Dry run complete, nothing written." if args.dry_run
          else "Flash issued for all chips.")
    print("\nThe EEPROM is only read at plug-in, so unplug the adapter and plug it back")
    print("in before its ports exist. Then prove it before it ships:")
    print(f"  scan-ftdi-adapters.py --verify {base}")
    print(f"  run-board-tests.sh --port-base {args.port_root}/{base} --pairs card")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. If this happened mid-flash the card is partially "
              "programmed - replug and re-run.", file=sys.stderr)
        sys.exit(130)
