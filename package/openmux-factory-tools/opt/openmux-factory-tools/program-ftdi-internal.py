#!/usr/bin/env python3
"""Program the EEPROM of the two internal FTDI chips in an OpenMux console.

Two FT4232H chips give eight ports. Serial strings take the form BASE-A and
BASE-B where BASE is the chassis serial; each chip's four interfaces become four
consecutive ports, matching /etc/udev/rules.d/99-openmux-ftdi.rules, so the
console owns the flat /dev/openmux/port1-8 (an EX-12 adapter's ports live in a
folder of their own and are written by program-ftdi-external.py).

WHY THE ORDER OF OPERATIONS IN THIS FILE IS LIKE IT IS: the two chips hang off
the same hub, and writing a chip's EEPROM makes it re-enumerate - which
reassigns bus/dev numbers for everything on that hub, including the chip that is
still waiting to be written. Bus/dev numbers were therefore read once, before
the operator was asked to confirm, and used twice: the second write could land
on whatever device happened to hold that number by then, since it would still be
a real device and still pass an id check. Every write now resolves the bus-port
path again, immediately before flashing. The same re-enumeration is why this tool
can leave a console half-programmed, and why that case is spelled out below
rather than reported as "flash failed".

The guards come from scan_ftdi.py, shared with program-ftdi-external.py and
scan-ftdi-adapters.py, including the one that refuses a target whose hub has
undeclared FTDI siblings - which is what an adapter's chips look like, so aiming
this tool at a card is caught instead of silently half-renaming it.
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import scan_ftdi as F  # noqa: E402

MANUFACTURER_DEFAULT = "OpenMux"
PRODUCT_DEFAULT = "OpenMux Console HW8, Internal FTDI"
CONSOLE_CHIPS = 2
CONSOLE_PORTS = CONSOLE_CHIPS * F.PORTS_PER_CHIP


def build_parser():
    ap = argparse.ArgumentParser(
        description="Program the console's two internal FTDI chips as <base>-A / <base>-B.",
        epilog="An EX-12 adapter plugged into this machine stays on the bus and is never "
               "a target here. Nothing is written without a typed confirmation.")
    ap.add_argument("serial_number", nargs="?",
                    help='chassis serial base, e.g. "OMC000001" -> OMC000001-A and -B')
    ap.add_argument("--path-a", default=F.INTERNAL_PATHS_DEFAULT[0],
                    help=f"bus-port path of chip A (default: {F.INTERNAL_PATHS_DEFAULT[0]})")
    ap.add_argument("--path-b", default=F.INTERNAL_PATHS_DEFAULT[1],
                    help=f"bus-port path of chip B (default: {F.INTERNAL_PATHS_DEFAULT[1]})")
    ap.add_argument("--devices-dir", default="/sys/bus/usb/devices",
                    help="sysfs USB tree (default: %(default)s)")
    ap.add_argument("--manufacturer", help="override the EEPROM manufacturer string")
    ap.add_argument("--product", help="override the EEPROM product string")
    ap.add_argument("--env-file", default=F.ENV_FILE_DEFAULT,
                    help=f"identity/prefix defaults (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve, guard and print the plan without writing")
    ap.add_argument("--yes", action="store_true",
                    help="skip the typed confirmation (scripted use only)")
    ap.add_argument("--audit", action="store_true",
                    help="do not program: check that /dev/openmux/portN is the chip and "
                         "interface the udev rules promise, and exit non-zero if not")
    ap.add_argument("--port-base", default="/dev/openmux",
                    help=f"console port directory (default: %(default)s)")
    ap.add_argument("--sys-tty-dir", default="/sys/class/tty")
    return ap


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


def describe(path, devices, devices_dir):
    """One line about a target, and a hard complaint if it is not what we think."""
    dev = next((d for d in devices if d["path"] == path), None)
    if dev is not None:
        return (f"{dev['path']} ({dev['manufacturer']!r} {dev['product']!r} "
                f"serial='{dev['serial']}')")
    if F.device_exists(devices_dir, path):
        found = F.vidpid(os.path.realpath(os.path.join(devices_dir, path)))
        raise RuntimeError(f"{path} exists but is {found or 'unreadable'}, not "
                           f"{F.VIDPID_DEFAULT} - this is not one of the console's "
                           f"FTDI chips, or the board has enumerated differently and "
                           f"--path-a/--path-b need updating")
    raise RuntimeError(f"{path} is not present in {devices_dir} - the console FTDI "
                       f"boards are fitted internally, so a missing path means the "
                       f"console is not enumerating at all")


def reassert(path, console_paths, devices_dir, expected_previous):
    """Resolve one target afresh, immediately before it is flashed.

    Read the docstring above: after chip A is written, chip B's bus/dev number is
    not what it was. Re-check identity by path, then read the numbers.
    """
    devices = F.scan(devices_dir, internal_paths=console_paths)
    dev = next((d for d in devices if d["path"] == path), None)
    if dev is None:
        raise RuntimeError(f"{path} has disappeared from the bus")

    why = F.guard_internal_target(path, devices, console_paths)
    if why:
        raise RuntimeError(f"{path} is no longer a safe target: {why}")
    if dev["serial"] != expected_previous:
        raise RuntimeError(f"{path} now reports serial '{dev['serial']}' instead of the "
                           f"'{expected_previous}' the plan was built on; something "
                           f"re-enumerated or was swapped mid-run")
    if dev["bus"] == "0" or dev["dev"] == "0":
        raise RuntimeError(f"{path} has no bus/dev address yet (bus {dev['bus']}, "
                           f"dev {dev['dev']}); the console is still enumerating, wait a "
                           f"moment and re-run")
    return dev


def flash(dev, serial, manufacturer, product, dry_run):
    """Write one chip, addressed by freshly read bus/dev numbers."""
    device_url = f"d:{int(dev['bus']):03d}/{int(dev['dev']):03d}"
    conf = make_conf(serial, manufacturer, product)
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".conf",
                                    prefix="openmux-int-") as handle:
        handle.write(conf)
        conf_path = handle.name
    cmd = ["sudo", "ftdi_eeprom", "--device", device_url, "--flash-eeprom", conf_path]

    print(f"  {dev['path']}  {device_url}  serial -> {serial}")
    print("  " + conf.strip().replace("\n", "\n  "))
    if dry_run:
        print(f"  [dry-run] {' '.join(cmd)}")
        return
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ftdi_eeprom failed for {dev['path']}\n"
                           f"  cmd:  {' '.join(cmd)}\n"
                           f"  exit: {proc.returncode}\n"
                           f"  {proc.stdout.strip()}\n  {proc.stderr.strip()}")


def run_audit(port_base, sys_tty_dir, prefix=F.PREFIX_INTERNAL_DEFAULT):
    """Check the console's own port symlinks (no adapter involved).

    Takes the prefix because when there are no ports at all, the useful sentence is
    the one naming the serial the rules look for - and that has to be the same
    prefix this tool would write, not a string guessed at here.
    """
    rows, ok = F.numbering_audit(port_base, sys_tty_dir=sys_tty_dir)
    print(f"Console port audit: {port_base}")
    if not rows:
        print("  no portN entries under here. The console's ports come from its own")
        print(f"  EEPROM serials via 99-openmux-ftdi.rules and match {prefix}[0-9]*-A/-B;")
        print("  if the console was just programmed it needs a replug, and if the prefix")
        print("  in use is not the one the rules match, no ports appear at all.")
        return 1
    for row in rows:
        iface = "?" if row["iface"] is None else f"{row['iface']}"
        verdict = "OK" if row["ok"] else f"WRONG: {row['detail']}"
        print(f"  port{row['port']:<3} {row['tty']:<9} chip {row['chip']} if{iface}  {verdict}")
    bad = [r for r in rows if not r["ok"]]
    print(f"  {len(rows) - len(bad)}/{len(rows)} ports where the udev rules put them")
    if len(rows) != CONSOLE_PORTS:
        print(f"  only {len(rows)} of the console's {CONSOLE_PORTS} ports exist: the second "
              f"internal chip is")
        print("  either not programmed, or programmed with a serial the rules do not "
              "match, so")
        print(f"  /dev/openmux/port{F.PORTS_PER_CHIP + 1}-{CONSOLE_PORTS} were never created.")
        ok = False
    if bad:
        print("  A misplaced port means a chip got the wrong serial - not a wiring fault.")
    return 0 if ok else 1


def main():
    args = build_parser().parse_args()
    console_paths = (args.path_a, args.path_b)

    # Resolved before the audit branch, not after it: --audit names the prefix it
    # expected when it finds no ports, and that must be the prefix this tool would
    # have written, read from the same env file.
    env = F.load_env_file(args.env_file)
    prefix = F.resolve_identity(env, F.KEY_PREFIX_INTERNAL,
                                default=F.PREFIX_INTERNAL_DEFAULT)

    if args.audit:
        return run_audit(args.port_base, args.sys_tty_dir, prefix)

    if args.serial_number is None:
        print("ERROR: a serial base is required, or use --audit to check the port map",
              file=sys.stderr)
        return 2

    if not args.dry_run and subprocess.run(
            ["bash", "-lc", "command -v ftdi_eeprom"], capture_output=True).returncode != 0:
        print("ERROR: missing tool: ftdi_eeprom (package ftdi-eeprom)")
        return 1

    if args.path_a == args.path_b:
        print(f"ERROR: --path-a and --path-b must name two different chips "
              f"(both are {args.path_a})", file=sys.stderr)
        return 2

    devices = F.scan(args.devices_dir, internal_paths=console_paths)

    # 1. Both targets are console chips, and the hub they sit on belongs to nobody
    #    else. This is the guard that catches adapter-as-console: an EX-12's three
    #    chips share their own hub, so naming two of them leaves a third sibling
    #    undeclared, which is not a shape the console ever has.
    unsafe = []
    for path in console_paths:
        try:
            describe(path, devices, args.devices_dir)
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        why = F.guard_internal_target(path, devices, console_paths)
        if why:
            unsafe.append(f"{path}: {why}")
    for message in unsafe:
        print(f"ERROR: {message}", file=sys.stderr)
    if unsafe:
        print("\nWhat is actually connected:", file=sys.stderr)
        for dev in devices:
            print(f"  {dev['path']:<10} hub={dev['parent'] or '-':<8} {dev['role']:<8} "
                  f"serial={dev['serial']}", file=sys.stderr)
        print("scan-ftdi-adapters.py explains each role; program-ftdi-external.py is the "
              "tool for a card.", file=sys.stderr)
        return 2

    base = args.serial_number.strip()
    ok_base, errors, warnings = F.validate_base(base, prefix)
    for message in errors:
        print(f"ERROR: serial base {base!r}: {message}", file=sys.stderr)
    if not ok_base:
        return 2

    # 2. A card plugged in for testing can already carry this base. Two devices
    #    with one base share one identity, and here the collision is worse than a
    #    clash: openmux-detect-hardware would report the card as the console.
    conflict = F.find_serial_conflict(base, devices, exclude=set(console_paths),
                                      folder="console")
    if conflict:
        print(f"ERROR: {conflict}.", file=sys.stderr)
        print("       Unplug any EX-12 adapter that carries this number, or pick another "
              "serial.", file=sys.stderr)
        print("       scan-ftdi-adapters.py --serials shows what is programmed here.",
              file=sys.stderr)
        return 2

    manufacturer = F.resolve_identity(env, F.KEY_MANUFACTURER, args.manufacturer,
                                      MANUFACTURER_DEFAULT)
    product = F.resolve_identity(env, F.KEY_PRODUCT_INTERNAL, args.product,
                                 PRODUCT_DEFAULT)

    plan = [("A", args.path_a, f"{base}-A"), ("B", args.path_b, f"{base}-B")]
    print("Will write, in this order:")
    for chip, path, serial in plan:
        print(f"  {path:<10} serial={serial:<12} was {describe(path, devices, args.devices_dir)}")
    print(f'  manufacturer="{manufacturer}"')
    print(f'  product="{product}"')
    print(f"\nPorts this creates, after a replug: "
          + " ".join(f"/dev/openmux/port{n}" for n in range(1, CONSOLE_PORTS + 1)))

    others = F.adapters(devices) + [d for d in devices if d["role"] == "unknown"]
    if others:
        print("\nOther FTDI devices on this bus, which this run will NOT touch:")
        for dev in others:
            print(f"  {dev['path']} (hub {dev['parent'] or '-'}), "
                  f"{dev['role']}, serial='{dev['serial']}'")
        print("  An EX-12 keeps its own serial and its own /dev/openmux folder, so "
              "programming\n  the console beside it is safe - but unplug it before "
              "testing, so a failure means\n  the console and not the cable.")
    for message in warnings:
        print(f"WARNING: serial base {base!r}: {message}", file=sys.stderr)

    # --yes is the only thing that silences this, in --dry-run too: rehearsal
    # should be the run the operator will actually perform.
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
        for chip, path, serial in plan:
            fresh = reassert(path, console_paths, args.devices_dir,
                             next(d["serial"] for d in devices if d["path"] == path))
            flash(fresh, serial, manufacturer, product, args.dry_run)
            programmed.append((chip, path, serial))
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        if programmed:
            done = ", ".join(f"{path} -> {serial}" for _, path, serial in programmed)
            print(f"\nThe console is now PARTIALLY programmed: {done}. A console with one "
                  f"renamed\nchip and one old one does not have {CONSOLE_PORTS} ports: "
                  f"/dev/openmux/port{F.PORTS_PER_CHIP + 1}-{CONSOLE_PORTS}\ndisappear "
                  f"with the second chip's serial.", file=sys.stderr)
            print("Replug (or reboot) and re-run this tool with the same serial to "
                  "finish; it is\nsafe to re-flash a chip that already has the right "
                  "serial.", file=sys.stderr)
        return 1

    print("Dry run complete, nothing written." if args.dry_run
          else "Flash issued for both chips.")
    print("\nThe EEPROM is only read at plug-in, so the new serials take effect on the")
    print("next replug or reboot. Then prove the port map before the box moves on:")
    print(f"  {os.path.basename(__file__)} --audit")
    print(f"  run-board-tests.sh --pairs console")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. If this happened mid-flash the console is partially "
              "programmed - replug and re-run.", file=sys.stderr)
        sys.exit(130)
