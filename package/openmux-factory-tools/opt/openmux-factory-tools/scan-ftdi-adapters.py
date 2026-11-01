#!/usr/bin/env python3
"""scan-ftdi-adapters.py - what FTDI equipment is on this bus, and which of it
is safe to program.

The console's own FTDI chips and any plugged-in EX-12 adapter are the same chip
(0403:6011), and a new adapter chip has no serial at all, so "list the FTDIs" is
not a useful question - the useful question is which hub each one hangs off.
This tool answers that, keeps the console out of the way, and can identify a
device by hotplug ("plug it in now" -> the group that appeared).

Roles are decided topologically and every row says WHY. Console rows are
reported in their own section and left out of the selectable list unless
--include-internal is given: they are never the intended target of this flow.

Two shapes of output: the full report (what a person reads when asked to identify
the equipment) and --summary, the shorter one the install menu redraws as its
header. Both come from this file, so the menu is never the thing that decides what
a chip is, and there is no second copy of that decision to fall out of step.

Exit status: 0 when the scan worked, including when it found no adapters;
1 when --audit/--verify finds a numbering fault, or the scan itself could not
run (so a caller can tell "nothing is plugged in" from "the tool is broken");
2 for bad arguments.
"""

import argparse
import json
import os
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import scan_ftdi as F  # noqa: E402


def build_parser():
    ap = argparse.ArgumentParser(
        description="List and classify OpenMux FTDI devices (console vs adapter).")
    ap.add_argument("--devices-dir", default="/sys/bus/usb/devices",
                    help="sysfs USB device tree (default: %(default)s). Point it at "
                         "a fake tree to exercise this tool without hardware.")
    ap.add_argument("--vid-pid", default=F.VIDPID_DEFAULT,
                    help="only list devices with this id (default: %(default)s)")
    ap.add_argument("--internal", default=None,
                    help=f"comma separated console FTDI paths (default: "
                         f"{','.join(F.INTERNAL_PATHS_DEFAULT)}, or "
                         f"${F.INTERNAL_PATHS_ENV})")
    ap.add_argument("--format", choices=("text", "tsv"), default="text")
    ap.add_argument("--serials", action="store_true",
                    help="after the table, print one programmed serial base per line "
                         "with the ports it covers - what is installed here?")
    ap.add_argument("--summary", action="store_true",
                    help="print the compact report INSTEAD of the full one: every FTDI "
                         "in one table (the console's own chips included, whatever "
                         "--include-internal says) plus one line per card. What the "
                         "install menu prints as its header.")
    ap.add_argument("--include-internal", action="store_true",
                    help="list the console's own chips in the main table too")
    ap.add_argument("--check-base", metavar="BASE",
                    help="validate a typed serial base against the udev rules and "
                         "the configured prefix, then exit: 0 usable, 1 refused, "
                         "3 usable but unconventional. Needs no devices - this is "
                         "a check of the rules, not of the bus.")
    ap.add_argument("--for-role", choices=("internal", "external"),
                    default="external",
                    help="which configured prefix --check-base validates against "
                         "(default: %(default)s)")
    ap.add_argument("--env-file", default=F.ENV_FILE_DEFAULT,
                    help=f"identity/prefix defaults (default: %(default)s)")
    ap.add_argument("--snapshot", metavar="FILE",
                    help="write the current topology to FILE as JSON")
    ap.add_argument("--diff-with", metavar="FILE",
                    help="compare against a FILE written by --snapshot and report "
                         "what appeared or disappeared (identify-by-replug)")
    ap.add_argument("--audit", action="store_true",
                    help="check that every port in --port-base is backed by the "
                         "chip/interface the udev rules promise")
    ap.add_argument("--verify", metavar="BASE",
                    help="--audit shorthand for a programmed adapter: audits "
                         "<port-root>/BASE")
    ap.add_argument("--port-base", default=None,
                    help="port directory to audit (default: /dev/openmux, the console)")
    ap.add_argument("--port-root", default="/dev/openmux",
                    help="where per-adapter port folders live (default: %(default)s)")
    ap.add_argument("--sys-tty-dir", default="/sys/class/tty")
    ap.add_argument("--audit-only", action="store_true",
                    help="with --audit/--verify, skip the device tables and print only "
                         "the audit (what run-board-tests.sh uses)")
    return ap


def resolve_internal(args):
    if args.internal is not None:
        return tuple(p for p in args.internal.replace(",", " ").split() if p)
    return F.internal_paths_from_env()


def snapshot_payload(devices, internal_paths):
    return {
        "internal_paths": list(internal_paths),
        "devices": [{"path": d["path"], "parent": d["parent"],
                     "serial": d["serial"], "role": d["role"]}
                    for d in devices],
    }


def diff_snapshots(old, new):
    """(appeared, gone) device paths between two snapshot payloads."""
    before = {d["path"] for d in old.get("devices", [])}
    after = {d["path"] for d in new.get("devices", [])}
    return sorted(after - before), sorted(before - after)


def render_text(devices, internal_paths, prefixes, include_internal, devices_dir):
    lines = [f"OpenMux FTDI topology  (sysfs {devices_dir}, filter {F.VIDPID_DEFAULT})",
             f"Console paths treated as untouchable: {', '.join(internal_paths) or '(none)'}",
             ""]

    selectable = devices if include_internal else F.adapters(devices)
    hidden = [d for d in devices if d not in selectable]

    lines.append("SELECTABLE DEVICES")
    if not selectable:
        lines.append("  (none - no external FTDI adapter group found; plug one in and "
                     "run this again)")
    else:
        lines.append(_indent(F.format_rows(_device_rows(selectable),
                                          _device_headers())))

    # Per-hub roll-up: the thing the operator actually picks is a hub, not a chip.
    groups = [g for g in F.group_by_parent(selectable).items()]
    if groups:
        lines.append("")
        lines.append("ADAPTER GROUPS (an EX-12 presents 3 chips under its own hub)")
        for hub, members in groups:
            serials = sorted({m["serial"] for m in members if m["programmed"]})
            state = ", ".join(serials) if serials else "unprogrammed"
            lines.append(f"  hub {hub}: {len(members)} chip(s) "
                         f"[{', '.join(m['path'] for m in members)}] {state}")
            suffixes = sorted({F.split_serial(m["serial"])[1]
                               for m in members if m["programmed"]})
            expected = F.PORTS_PER_CHIP * len(members)
            lines.append(f"      ports implied: {expected} "
                         f"(chips {''.join(suffixes) or '?'})")
            if len(members) != 3:
                lines.append(f"      NOTE: {len(members)} chip(s), an EX-12 has 3 - "
                             f"is a chip unpowered, or is this hub shared?")

    console_rows = F.console(devices)
    if console_rows:
        lines.append("")
        lines.append("CONSOLE (internal FTDI - never offered for adapter programming)")
        for dev in console_rows:
            lines.append(f"  {dev['path']} ({dev['parent']}) "
                         f"serial={dev['serial']} product='{dev['product']}'")
            lines.append(f"      why: {dev['reason']}")

    if hidden and not include_internal:
        lines.append("")
        lines.append(f"  ({len(hidden)} console row(s) hidden; --include-internal shows all)")

    for label, prefix in (("internal", prefixes["internal"]),
                          ("external", prefixes["external"])):
        lines.append("")
        lines.append(f"Configured {label} serial prefix: {prefix}")
    return "\n".join(lines)


def render_tsv(devices, include_internal):
    print("role\tpath\tparent\tbusnum\tdevnum\tserial\tmanufacturer\tproduct\treason")
    for dev in devices:
        if dev["role"] == "console" and not include_internal:
            continue
        # Empty serial means unprogrammed, and nothing else. The text tables write
        # `unprogrammed` because a blank cell in a table reads like a rendering bug;
        # in a machine-readable column a placeholder is a second sentinel every
        # caller would have to learn, and one they could forget.
        serial = dev["serial"] if dev["programmed"] else ""
        fields = (dev["role"], dev["path"], dev["parent"], dev["bus"], dev["dev"],
                  serial, dev["manufacturer"], dev["product"], dev["reason"])
        print("\t".join(field.replace("\t", " ").replace("\n", " ") for field in fields))


def _indent(text, prefix="  "):
    return "\n".join(prefix + line for line in text.splitlines())


def _wrapped(text, marker):
    """One finding under a table ("NOTE: ...", "WARNING: ...), wrapped to 78.

    Written as one string so it is edited as a sentence rather than as several
    adjacent literals whose breaks drift away from the words. Anything variable goes
    LAST in the string: on a serial console the overflow then costs a wrap instead
    of shifting a table column."""
    return textwrap.fill(text, width=78, initial_indent=f"  {marker}: ",
                         subsequent_indent=" " * (len(marker) + 4))


# Both tables describing a chip use the same cells, so the columns are declared
# once, in one order: `product` last, because it is the one field whose length
# nobody here controls - it is whatever string was flashed into the EEPROM - and a
# long one therefore pushes only its own column past 80 columns on a serial
# console, leaving every column to its left in position. `--format tsv` prints
# every string untruncated and is what any caller should parse.
#
# Header spellings are chosen to fit, not to match sysfs: `maker` where the file
# system and --format tsv say `manufacturer`, because that header is 12 columns and
# the values shipped here are 7. The TSV header is the one a program reads, so that
# one keeps the long name.
#
# `compact` is the menu-header view, and it drops `busdev` and the row number.
# busdev is the only value here that goes stale the moment anything on the bus
# re-enumerates - which is exactly what plugging in or flashing a chip does - and a
# row number is only worth its columns when something is chosen by number, which
# nothing is: every flag in every tool here takes a bus-port path. The full report
# prints both, and that is the view to read before a manual `ftdi_eeprom --device
# d:BBB/DDD`.
_DEVICE_HEADERS = ("#", "hub", "path", "busdev", "serial", "role", "maker", "product")
_COMPACT_DROP = ("#", "busdev")


def _device_headers(compact=False):
    if not compact:
        return _DEVICE_HEADERS
    return tuple(h for h in _DEVICE_HEADERS if h not in _COMPACT_DROP)


def _device_rows(devices, compact=False):
    """Table rows for `devices`, in the order given, matching _device_headers().

    An unprogrammed chip shows `unprogrammed` rather than an empty cell: a blank in
    a serial column reads as a rendering bug, and here it is the most important fact
    on the line - that chip has no identity yet, which is what the programming
    options exist for."""
    rows = []
    for number, dev in enumerate(devices, 1):
        row = [dev["parent"] or "-", dev["path"]]
        if not compact:
            row.insert(0, number)
            row.append(f"{int(dev['bus']):03d}:{int(dev['dev']):03d}")
        row += [dev["serial"] if dev["programmed"] else "unprogrammed",
                dev["role"], dev["manufacturer"], dev["product"]]
        rows.append(tuple(row))
    return rows


def card_groups(devices):
    """[(hub, [chip rows])] for the adapter groups, ordered as the ports nest."""
    return sorted(F.group_by_parent(F.adapters(devices)).items(),
                  key=lambda item: F.path_sort_key(item[0]))


def render_summary(devices, internal_paths, port_root, devices_dir):
    """The compact report the install menu prints as its header.

    Two blocks, each answering a question asked before an option is chosen: WHICH
    chips are here (one table, the console's own chips included - leaving them out
    is what made the old summary look like it was hiding the hardware under
    discussion) and HOW MANY CARDS (one line each, since a card is what is held in
    the hand while three rows are what the bus sees).

    No verdict is added here that the full report does not already make; the
    warning below is the one case where the table alone is not enough to notice a
    problem, because a missing console row and an unprogrammed console look the
    same in it."""
    # Every line below is written to stay inside 80 columns, because this is the
    # serial-console header: variable text (paths, bases, port folders) goes at the
    # END of a line, where overflow costs a wrap instead of breaking the columns.
    lines = [f"FTDI DEVICES  ({F.VIDPID_DEFAULT} under {devices_dir}; console chips "
             "included)",
             ""]
    if not devices:
        lines.append(textwrap.fill(
            f"  (none - nothing answers as {F.VIDPID_DEFAULT} here. Is the console "
            "powered, and is a card's own cable seated?)", width=78,
            subsequent_indent="   "))
    else:
        lines.append(_indent(F.format_rows(_device_rows(devices, compact=True),
                                          _device_headers(compact=True))))

    if not F.console(devices):
        # Not "nothing is programmed": classification is topological, so an empty
        # console set means no chip sits on those paths at all, programmed or not -
        # which is equally true of a board whose console enumerates elsewhere. Both
        # end the same way for the operator: the console options would write, or
        # refuse to find, chips at the wrong paths.
        lines.append(_wrapped(
            "no chip sits on the console's internal paths, so nothing in the table "
            "above is the console. Either it is not enumerating, or this board hangs "
            "its chips somewhere else and --internal (or "
            f"${F.INTERNAL_PATHS_ENV}) needs saying. Paths checked: "
            f"{', '.join(internal_paths) or 'none configured'}", "WARNING"))

    lines.append("")
    lines.append("EX-12 CARDS  (one line per card; a card is three FT4232H behind its "
                 "own hub)")
    groups = card_groups(devices)
    if not groups:
        lines.append("  (none on the bus)")
    else:
        headers = ("hub", "serial", "chips", "ports")
        rows = []
        notes = []
        for hub, members in groups:
            bases = sorted({F.split_serial(m["serial"])[0] for m in members
                            if m["programmed"]})
            suffixes = "".join(sorted({F.split_serial(m["serial"])[1] for m in members
                                       if m["programmed"]}))
            ports = F.PORTS_PER_CHIP * len(members)
            if not bases:
                serial, where = "unprogrammed", "(none yet)"
            elif len(bases) > 1:
                # Three chips answering to two bases: a reflash that did not rewrite
                # all three. `<root>/A,B` names no folder, so the card has no ports at
                # all. Kept out of the cell, which would widen that column for every
                # card.
                serial, where = f"{len(bases)} bases", "(no folder matches)"
                notes.append(f"hub {hub} answers to {len(bases)} serial bases "
                             f"({', '.join(bases)}): one card cannot fill two folders, "
                             "so it has no /dev/openmux port at all until it is "
                             "reprogrammed")
            else:
                serial = bases[0]
                where = f"{port_root}/{bases[0]}/port1-{ports}"
            rows.append((hub, serial,
                         f"{len(members)}" + (f" {suffixes}" if suffixes else ""),
                         where))
            if len(members) != 3:
                notes.append(f"hub {hub} has {len(members)} chip(s) and an EX-12 has 3: "
                             "an unpowered chip, or a hub shared with other "
                             "equipment. Program it with --allow-partial only, and "
                             "only knowing which chip is missing")
        lines.append(_indent(F.format_rows(rows, headers)))
        for note in notes:
            lines.append(_wrapped(note, "NOTE"))
    return "\n".join(lines)


def render_serials(devices):
    """Programmed serial bases, with the chips - and therefore ports - each covers.

    'What is programmed on this machine?' is the question a field engineer asks
    first, and the port range is what makes a base recognisable: OMC000001 covers
    /dev/openmux/port1-8 on the console, OMX000042 covers 1-12 under
    /dev/openmux/OMX000042/."""
    by_base = {}
    unprogrammed = 0
    for dev in devices:
        if not dev["programmed"]:
            unprogrammed += 1
            continue
        base, suffix = F.split_serial(dev["serial"])
        if not base:
            continue
        by_base.setdefault(base, []).append(dev)

    lines = ["Programmed serial bases"]
    if not by_base:
        lines.append("  (none - every chip found is unprogrammed)")
    for base in sorted(by_base):
        members = by_base[base]
        suffixes = sorted({F.split_serial(m["serial"])[1] for m in members})
        ports = [F.expected_port(s, 0) for s in suffixes if s]
        ports = sorted(p for p in ports if p)
        covers = f"ports {ports[0]}-{ports[-1] + F.PORTS_PER_CHIP - 1}" if ports else "?"
        role = members[0]["role"]
        where = ("/dev/openmux/%s/portN" % base) if role == "adapter" \
            else "/dev/openmux/portN"
        lines.append(f"  {base:<12} {role:<8} chips {''.join(suffixes):<3} {covers:<12} {where}")
    if unprogrammed:
        lines.append(f"  ({unprogrammed} chip(s) with no serial programmed)")
    return "\n".join(lines)


def run_audit(args, port_base):
    rows, ok = F.numbering_audit(port_base, sys_tty_dir=args.sys_tty_dir)
    print(f"Port numbering audit: {port_base}")
    if not rows:
        print(f"  no portN entries found under {port_base}")
        print("  the adapter is either not programmed yet, or was programmed with a")
        print("  serial the udev rules do not match (check the configured prefix)")
        return False

    headers = ("port", "tty", "chip", "iface", "expected", "result", "detail")
    rows_table = [(r["port"], r["tty"], r["chip"],
                   f"{r['iface']:02d}" if r["iface"] is not None else "-",
                   r["expected"], "OK" if r["ok"] else "MISMATCH", r["detail"])
                  for r in rows]
    print(_indent(F.format_rows(rows_table, headers), "  "))

    bad = [r for r in rows if not r["ok"]]
    print(f"  {len(rows) - len(bad)}/{len(rows)} ports in the position the rules promise")
    if bad:
        print("  A port is in the wrong place. This is a programming or udev fault, NOT")
        print("  a wiring fault: re-check which chip got which serial before re-testing.")
    return ok


def check_base(base, prefix, role="external"):
    """Validate a base the operator has just typed, without touching the bus.

    A base the rules will not match is worse than no base at all: the flash
    succeeds, the chip re-enumerates with a serial nothing claims, and the board
    looks like it has no ports. So an unconventional base is reported separately
    (exit 3) rather than folded into either answer, and the caller decides.
    """
    ok, errors, warnings = F.validate_base(base, prefix)
    for problem in errors:
        print(f"  REFUSED: {problem}")
    for note in warnings:
        print(f"  WARNING: {note}")
    if not ok:
        print(f"  {base!r} cannot be used as a serial base.")
        return 1
    if warnings:
        print(f"  {base!r} would be written as typed, but read the warning above "
              f"first.")
        return 3
    # The two roles land in different places: the console's chips share one flat
    # folder, an adapter gets a folder named after its own base. Saying which is
    # the point of checking before writing.
    if role == "internal":
        print(f"  {base} is usable - the console's ports would appear as "
              f"/dev/openmux/port1-8, chips {base}-A and {base}-B")
    else:
        print(f"  {base} is usable - its ports would appear under "
              f"/dev/openmux/{base}")
    return 0


def main():
    args = build_parser().parse_args()

    if args.check_base is not None:
        # Deliberately before any scanning: this only asks what the udev rules
        # would make of the string, and has to answer that on a bench with
        # nothing plugged in. Empty string included - "is '' a valid base?" needs
        # an answer, not a device table.
        env = F.load_env_file(args.env_file)
        key = (F.KEY_PREFIX_INTERNAL if args.for_role == "internal"
               else F.KEY_PREFIX_EXTERNAL)
        prefix = F.resolve_identity(
            env, key, default=(F.PREFIX_INTERNAL_DEFAULT if args.for_role == "internal"
                               else F.PREFIX_EXTERNAL_DEFAULT))
        return check_base(args.check_base, prefix, args.for_role)

    internal_paths = resolve_internal(args)

    try:
        devices = F.scan(args.devices_dir, args.vid_pid, internal_paths)
    except NotADirectoryError:
        print(f"ERROR: cannot read {args.devices_dir} (is this the sysfs USB tree?)",
              file=sys.stderr)
        return 1

    if (args.audit or args.verify) and args.audit_only:
        # run-board-tests.sh wants the numbering verdict and nothing else.
        port_base = args.verify and os.path.join(args.port_root, args.verify) or args.port_base
        return 0 if run_audit(args, port_base or args.port_root) else 1

    if args.snapshot:
        with open(args.snapshot, "w", encoding="utf-8") as fh:
            json.dump(snapshot_payload(devices, internal_paths), fh, indent=1)
        print(f"snapshot: {len(devices)} FTDI device(s) -> {args.snapshot}")

    if args.diff_with:
        try:
            with open(args.diff_with, "r", encoding="utf-8") as fh:
                old = json.load(fh)
        except (OSError, ValueError) as exc:
            print(f"ERROR: cannot read snapshot {args.diff_with}: {exc}", file=sys.stderr)
            return 1
        appeared, gone = diff_snapshots(old, {"devices": [{"path": d["path"]}
                                                         for d in devices]})
        print(f"Compared with {args.diff_with}:")
        if not appeared and not gone:
            print("  nothing changed - was the adapter unplugged and plugged back in?")
        for path in appeared:
            dev = next((d for d in devices if d["path"] == path), None)
            hub = dev["parent"] if dev else "?"
            print(f"  NEW      {path} (hub {hub})"
                  + (f"  serial={dev['serial']}" if dev and dev["programmed"] else ""))
        for path in gone:
            print(f"  GONE     {path}")
        if appeared:
            hubs = sorted({d["parent"] for d in devices if d["path"] in appeared})
            print(f"  -> the device you just plugged in hangs off hub: {', '.join(hubs)}")

    env = F.load_env_file(args.env_file)
    prefixes = {
        "internal": F.resolve_identity(env, F.KEY_PREFIX_INTERNAL,
                                       default=F.PREFIX_INTERNAL_DEFAULT),
        "external": F.resolve_identity(env, F.KEY_PREFIX_EXTERNAL,
                                       default=F.PREFIX_EXTERNAL_DEFAULT),
    }

    if args.summary:
        # The menu header is rendered here rather than in the menu, for the same
        # reason the guards live here: the menu must not be the thing that decides
        # which chip is a console chip, and a second copy of that decision in awk
        # is a second copy that can disagree. Prefix lines and the base roll-up
        # belong to the full report, not to a header redrawn on every menu loop.
        print(render_summary(devices, internal_paths, args.port_root, args.devices_dir))
    elif args.format == "tsv":
        render_tsv(devices, args.include_internal)
    else:
        print(render_text(devices, internal_paths, prefixes,
                          args.include_internal, args.devices_dir))
        if args.serials:
            print("")
            print(render_serials(devices))

    if args.verify and args.audit:
        print("ERROR: use --audit or --verify BASE, not both", file=sys.stderr)
        return 2

    port_base = args.port_base
    if args.verify:
        port_base = os.path.join(args.port_root, args.verify)
    if args.audit or args.verify:
        return 0 if run_audit(args, port_base or args.port_root) else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
