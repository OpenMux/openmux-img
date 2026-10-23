#!/usr/bin/env python3
"""scan_ftdi.py - shared OpenMux FTDI topology, numbering and identity helpers.

Unlike the other files in this directory (each a self-contained factory tool),
this module IS imported by its siblings: by scan-ftdi-adapters.py,
program-ftdi-internal.py, program-ftdi-external.py, and through them by
run-board-tests.sh. That breaks the "every tool stands alone" habit on purpose,
because four facts here must never be allowed to drift apart:

  * the chip/interface -> port number map encoded by
    /etc/udev/rules.d/99-openmux-ftdi.rules (interfaces 00-03 of the chip whose
    serial ends -A/-B/-C are ports 4*chip + iface + 1),
  * which FTDI devices belong to the console and which to a plug-in adapter.
    Classification can only be TOPOLOGICAL: every chip in this system is the
    same 0403:6011 FT4232H, and a brand new adapter chip has no serial at all,
    so neither vid:pid nor the descriptor strings can tell the two apart,
  * the guards that keep an adapter flash from landing on the console's own
    chips - which sit on the SAME hub as the adapter (console chips at 2-1.1
    and 2-1.2, the adapter's own hub typically at 2-1.4), and are therefore
    always present whenever an adapter is being programmed,
  * the /boot/firmware/openmux.env identity keys and their precedence.

Nothing in this module writes to a device; it only reads sysfs and reports.
Every function takes the directory it should read, so the tools can be
exercised against a fake sysfs tree with no hardware attached.
"""

import os
import re

# Every FTDI in this system - console and adapter alike - is one of these.
VIDPID_DEFAULT = "0403:6011"

# Suffix written into each chip's EEPROM, in port-block order. Chip A owns
# ports 1-4, B ports 5-8, C ports 9-12 (see the header of this module).
CHIP_ORDER = ("A", "B", "C")
PORTS_PER_CHIP = 4

# Console chips hang off these bus-port paths (program-ftdi-internal.py has
# always flashed exactly these two). Overridable because a carrier revision
# could enumerate them elsewhere - and the guards are only as good as this set.
INTERNAL_PATHS_DEFAULT = ("2-1.1", "2-1.2")
INTERNAL_PATHS_ENV = "OPENMUX_FTDI_INTERNAL_PATHS"

# A plausible default for where an adapter's own hub sits. NOT a default target
# any more: it is only a hint shown in messages and never flashed unasked.
EXTERNAL_HUB_HINT = "2-1.4"

ENV_FILE_DEFAULT = "/boot/firmware/openmux.env"

# Identity keys read from ENV_FILE_DEFAULT (see Plan 1 for who writes it).
KEY_MANUFACTURER = "OPENMUX_MANUFACTURER"
KEY_PRODUCT_INTERNAL = "OPENMUX_PRODUCT_INTERNAL"
KEY_PRODUCT_EXTERNAL = "OPENMUX_PRODUCT_EXTERNAL"
KEY_PREFIX_INTERNAL = "OPENMUX_SERIAL_PREFIX_INTERNAL"
KEY_PREFIX_EXTERNAL = "OPENMUX_SERIAL_PREFIX_EXTERNAL"

# The shipped prefixes: OMC for the console's own chips (OpenMux Console), OMX for
# an adapter's (OpenMux eXtention). Defaults only - the environment and the env
# file above override them.
#
# The thing to understand about these two strings is that they are not only used
# here. The prefix is part of the udev rule grammar (OMC[0-9]*-A), and
# openmux-detect-hardware.sh matches 'OMC*-A' in shell - both in openmux-hardware,
# a different package from these tools. Change one without the others and the
# result is silent: the flash succeeds, the chip re-enumerates with a serial
# nothing claims, and the board simply has no /dev/openmux ports. om-verify.sh
# asserts the three agree.
PREFIX_INTERNAL_DEFAULT = "OMC"
PREFIX_EXTERNAL_DEFAULT = "OMX"

# A prefix plus any number of digits, as the rules spell it: OMC[0-9]*. The width
# is not policed - a serial stamped 4 digits is still a serial, and refusing it
# would make that chassis unprogrammable rather than merely unusual.
PREFIX_RE_HINT = "upper-case letters/digits, e.g. OMC or OMX"

# Both the rules' ${s%-A} and openmux-detect-hardware.sh's ${s%%-*} split a serial
# at its first dash, so a serial BASE must never contain a dash.


# --------------------------------------------------------------- sysfs basics

def read_attr(path, default=""):
    """Read one sysfs attribute, stripped; `default` when absent/unreadable.

    sysfs files exist but read as empty (or throw) quite often for
    unenumerated devices, so the default is the normal path, not an error."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return default


def vidpid(devdir):
    vid = read_attr(os.path.join(devdir, "idVendor")).lower()
    pid = read_attr(os.path.join(devdir, "idProduct")).lower()
    if not vid or not pid:
        return ""
    return f"{vid}:{pid}"


def usb_path_ancestor(ancestor, node):
    """True if `ancestor` IS `node` or one of node's parents.

    Bus-port names nest on a dot ('2-1' -> '2-1.4' -> '2-1.4.2'), and comparing
    them as plain strings would call '2-1' an ancestor of '2-11'. The dot has
    to be part of the match."""
    return node == ancestor or node.startswith(ancestor + ".")


def parent_of(devices_dir, name):
    """Bus-port name of the device above `name`, or "" at the root hub.

    realpath() of '2-1.4.2' ends in .../2-1.4/2-1.4.2, so its dirname basename
    is the parent port string - the same value lsusb -t prints."""
    real = os.path.realpath(os.path.join(devices_dir, name))
    parent = os.path.basename(os.path.dirname(real))
    return "" if parent == name else parent


def list_devices(devices_dir, vidpid_wanted=VIDPID_DEFAULT):
    """Scan sysfs for FTDI *device* directories (not interface directories).

    An interface dir ('2-1.4.2:1.0') carries bInterfaceNumber but no busnum, so
    requiring busnum keeps the list to whole devices - one entry per chip.
    Entries are returned sorted by bus-port name, which is the order the ports
    physically nest in, and each row is keyed by that NAME rather than by
    busnum/devnum: the path is the physical port chain and survives a replug,
    while bus/dev numbers are reassigned whenever anything on the bus
    re-enumerates - which is exactly what plugging an adapter does."""
    if not os.path.isdir(devices_dir):
        raise NotADirectoryError(devices_dir)

    found = []
    for name in sorted(os.listdir(devices_dir), key=path_sort_key):
        devdir = os.path.join(devices_dir, name)
        if not os.path.isdir(devdir):
            continue
        if not read_attr(os.path.join(devdir, "busnum")):
            continue
        if vidpid(devdir) != vidpid_wanted:
            continue
        serial = read_attr(os.path.join(devdir, "serial"), "<none>")
        found.append({
            "path": name,
            "parent": parent_of(devices_dir, name),
            "bus": read_attr(os.path.join(devdir, "busnum"), "0"),
            "dev": read_attr(os.path.join(devdir, "devnum"), "0"),
            "manufacturer": read_attr(os.path.join(devdir, "manufacturer"), "?"),
            "product": read_attr(os.path.join(devdir, "product"), "?"),
            "serial": serial,
            "programmed": serial not in ("<none>", ""),
        })
    return found


def group_by_parent(devices):
    """{parent port name: [device rows]} - one group per hub."""
    groups = {}
    for dev in devices:
        groups.setdefault(dev["parent"], []).append(dev)
    return groups


def split_serial(serial):
    """('OMX1234', 'A') for 'OMX1234-A'; ('', '') when nothing was programmed.

    The base is everything before the LAST dash and the suffix the one letter
    after it. Both spellings of this split in the tree - udev's ${s%-A} and
    openmux-detect-hardware.sh's ${s%%-*} - mean the same thing as long as the
    base holds no dash, which validate_base() is there to keep true."""
    base, dash, suffix = (serial or "").rpartition("-")
    if not dash:
        return "", ""
    return base, suffix


def chip_index(suffix):
    """0/1/2 for suffix A/B/C (case-insensitive), or None if unknown."""
    try:
        return CHIP_ORDER.index((suffix or "").upper())
    except ValueError:
        return None


def expected_port(suffix, iface, ports_per_chip=PORTS_PER_CHIP):
    """The port number the udev rules promise for this chip/interface."""
    index = chip_index(suffix)
    if index is None:
        return None
    return index * ports_per_chip + int(iface) + 1


def port_chip(port):
    """('A', 0) for port 1, ('B', 0) for port 5 - the inverse of expected_port."""
    index = (int(port) - 1) // PORTS_PER_CHIP
    if index >= len(CHIP_ORDER):
        return None, None
    return CHIP_ORDER[index], (int(port) - 1) % PORTS_PER_CHIP


# ------------------------------------------------------------- classification

def classify(dev, internal_paths=INTERNAL_PATHS_DEFAULT):
    """(role, reason) for one device row; role in console|adapter|unknown.

    Topology decides, and the console set is what gets subtracted first. Serial
    strings are only reported, never used to decide - an unprogrammed chip has
    no serial, and the whole point of the guards is that a programmed adapter
    chip can end up wearing a console serial (or the other way round)."""
    path = dev["path"]
    for internal in internal_paths:
        if usb_path_ancestor(internal, path):
            return "console", f"sits on the console's internal FTDI path {internal}"
    if dev["parent"] and dev["parent"] not in ("",):
        return "adapter", f"hangs off hub {dev['parent']}, outside the console paths"
    return "unknown", "no hub parent resolved"


def scan(devices_dir="/sys/bus/usb/devices", vidpid_wanted=VIDPID_DEFAULT,
         internal_paths=INTERNAL_PATHS_DEFAULT):
    """list_devices() + classify(). Raises NotADirectoryError if unavailable -
    callers must not confuse a broken scan with an empty bus."""
    devices = list_devices(devices_dir, vidpid_wanted)
    for dev in devices:
        dev["role"], dev["reason"] = classify(dev, internal_paths)
    return devices


def adapters(devices):
    """The rows an operator may legitimately be offered: adapters only.

    Console rows are removed rather than merely labelled, because a console
    chip is never the intended target of the adapter flow - and because a
    virgin adapter chip and a console chip look identical by descriptor."""
    return [d for d in devices if d["role"] == "adapter"]


def console(devices):
    return [d for d in devices if d["role"] == "console"]


def internal_paths_from_env(default=INTERNAL_PATHS_DEFAULT):
    """The console path set, from $OPENMUX_FTDI_INTERNAL_PATHS when set.

    Comma or space separated. Kept an environment knob rather than a build-spec
    value: it is board topology, not customer data."""
    raw = os.environ.get(INTERNAL_PATHS_ENV, "").strip()
    if not raw:
        return tuple(default)
    return tuple(p for p in raw.replace(",", " ").split() if p)


# --------------------------------------------------------------- target guards

def guard_target(path, hub_path, internal_paths, devices, console_strings=()):
    """Why flashing `path` must be refused, or None when it looks safe.

    Checked BEFORE the operator confirms anything, against the sysfs state at
    that moment. assert_target_live() repeats the resolvable part of this
    immediately before the flash, because plugging or unplugging anything on
    this bus re-enumerates it beneath us."""
    for internal in internal_paths:
        if usb_path_ancestor(internal, path):
            return (f"{path} is the console's own internal FTDI chip (it sits on "
                    f"{internal}); refusing to reprogram the console")

    live = next((d for d in devices if d["path"] == path), None)
    if live is None:
        return f"{path} is not present on the bus"

    if live["role"] == "console":
        return f"{path} was classified as a console chip: {live['reason']}"

    if hub_path and live["parent"] != hub_path:
        return (f"{path} hangs off hub {live['parent'] or 'the root hub'}, not the "
                f"selected adapter hub {hub_path}")

    for string in console_strings:
        if string and string in ("<none>", "?"):
            continue
        if string in (live["manufacturer"], live["product"], live["serial"]):
            return (f"{path} currently reports the console's identity string "
                    f"'{string}'")

    return None


def guard_hub(hub_path, internal_paths, devices):
    """Why `hub_path` cannot be an adapter hub, or None.

    The mistake this catches is --usb-path 2-1: '2-1' is a real path, and its
    computed sub-ports include 2-1.2 - the console's second chip - which passes
    the vid:pid test because it is the same chip family. Name the console
    subtree first and the question never gets that far."""
    for internal in internal_paths:
        if usb_path_ancestor(hub_path, internal):
            return (f"{hub_path} contains the console's own internal FTDI chip "
                    f"{internal}; the adapter has its own hub underneath it")

    group = [d for d in devices
             if d["parent"] == hub_path and d["role"] != "console"]
    if not group:
        seen = sorted({d["parent"] or "root hub" for d in devices})
        return (f"no FTDI chip hangs off {hub_path} (FTDI hubs seen: "
                f"{', '.join(seen) if seen else 'none - is anything plugged in?'}); "
                f"an EX-12 adapter presents three chips under its own hub")
    return None


def device_exists(devices_dir, path):
    """True if the bus-port directory is there at all, whatever it turned out to be."""
    return os.path.isdir(os.path.realpath(os.path.join(devices_dir, path or "")))


def guard_internal_target(path, devices, console_paths):
    """Why flashing `path` as a CONSOLE chip must be refused, or None.

    The mirror image of guard_target(), guarding the opposite mistake: aiming the
    console tool at an adapter. The console's two chips sit side by side on the
    upstream hub, while an adapter's three chips always sit together behind the
    adapter's own hub. So a target whose FTDI siblings are not exactly the
    declared console set is not a console chip, even when the operator named the
    paths by hand:

      --path-a 2-1.4.2 --path-b 2-1.4.3   -> 2-1.4.4 is a sibling nobody declared,
                                             so this is a card, and it is refused.
    """
    me = next((d for d in devices if d["path"] == path), None)
    if me is None:
        return f"{path} is not present as a {VIDPID_DEFAULT} device on this bus"

    strangers = sorted(d["path"] for d in devices
                       if d["parent"] == me["parent"] and d["path"] not in console_paths)
    if strangers:
        return (f"{path} shares hub {me['parent'] or 'the root hub'} with "
                f"{', '.join(strangers)}, which is not one of the console's paths "
                f"({', '.join(console_paths)}). An EX-12's chips sit together behind "
                f"the card's own hub and look exactly like this - use "
                f"program-ftdi-external.py for a card")
    return None


def find_serial_conflict(base, devices, exclude=(), folder=""):
    """Explain why flashing base would duplicate an existing serial, else None.

    `exclude` names paths that are about to be overwritten anyway, so a console
    reprogrammed to the number it already has is not told it conflicts with
    itself. `folder` only shapes the message: the console owns the flat
    /dev/openmux/portN, an adapter owns /dev/openmux/<base>."""
    taken = {d["serial"] for d in devices
             if d["programmed"] and d["path"] not in exclude}
    where = f"/dev/openmux/{base}" if folder == "card" else "/dev/openmux"
    for suffix in CHIP_ORDER:
        if f"{base}-{suffix}" in taken:
            return f"{base}-{suffix} is already programmed on a device on this bus"
    existing_base = {split_serial(s)[0] for s in taken if s}
    if base in existing_base:
        return (f"a device on this bus already uses the base serial {base}; two "
                f"devices with one base share one {where} folder")
    return None


def validate_base(base, prefix):
    """(ok, errors, warnings) for a typed serial base; never raises.

    Hard failures are the ones that silently break the udev rules or the
    identity service; anything merely unconventional is a warning the operator
    can overrule."""
    errors, warnings = [], []
    if not base:
        return False, ["serial base is empty"], warnings

    if any(char.isspace() for char in base):
        errors.append("serial base must not contain whitespace")
    for char in "\"'\\":
        if char in base:
            errors.append(f"serial base must not contain {char!r}")
    if "-" in base:
        errors.append("serial base must not contain '-': the port rules and the "
                      "hardware identity split the serial at its first dash")
    if base != base.strip():
        errors.append("serial base must not have leading or trailing spaces")

    if errors:
        return False, errors, warnings

    if prefix and not base.upper().startswith(prefix.upper()):
        warnings.append(f"does not start with the configured prefix {prefix!r}; "
                        f"the udev rules will not create /dev/openmux/{base}")
    if prefix and base.upper().startswith(prefix.upper()):
        digits = base[len(prefix):]
        if not digits.isdigit():
            warnings.append(f"suffix after {prefix!r} is not all digits "
                            f"({digits!r}); the rules match {prefix}[0-9]*")
    return True, errors, warnings


# ---------------------------------------------------------------- numbering audit

def resolve_tty_iface(sys_tty_dir, tty):
    """(chip serial, interface number) behind /dev/<tty>, via sysfs only.

    /sys/class/tty/<tty>/device is the USB INTERFACE directory (2-1.4.2:1.2), so
    bInterfaceNumber is right there and its parent is the chip. Nothing here
    needs udevadm, which the minbase images do not necessarily carry."""
    iface_dir = os.path.realpath(os.path.join(sys_tty_dir, tty, "device"))
    ifaces = read_attr(os.path.join(iface_dir, "bInterfaceNumber"))
    if not ifaces:
        return None, None
    try:
        iface = int(ifaces, 16)
    except ValueError:
        return None, None
    return read_attr(os.path.join(os.path.dirname(iface_dir), "serial"), ""), iface


def numbering_audit(port_base, sys_tty_dir="/sys/class/tty"):
    """Check that /dev/openmux/portN really is chip/interface what the rules say.

    A pairwise loopback test can only ever prove which ports are PAIRED:
    swapping the two ends of any single plug is invisible to it, because every
    pair is exercised in both directions. The ORDER of the ports is provable
    another way and needs no fixture at all - each port's symlink resolves to a
    tty whose USB interface already reports which chip it belongs to (the chip's
    serial suffix) and which of that chip's four ports it is. This checks
    exactly the claim the pair profiles exist to protect: that the last port of
    one chip is immediately followed by the first port of the next.

    Returns (rows, ok). Rows are dicts so callers can render text or tsv.
    ok is False when anything is missing, unresolvable, or misplaced - a broken
    map is a programming or udev fault, never a wiring fault."""
    rows = []
    ok = True

    if not os.path.isdir(port_base):
        return rows, False

    for name in sorted(os.listdir(port_base), key=_port_sort_key):
        if not name.startswith("port") or not name[4:].isdigit():
            continue
        port = int(name[4:])
        link = os.path.join(port_base, name)
        tty = os.path.basename(os.path.realpath(link))
        row = {"port": port, "tty": tty, "base": "", "chip": "-", "iface": None,
               "expected": None, "ok": False, "detail": ""}
        rows.append(row)

        if not os.path.exists(link):
            row["detail"] = "dangling symlink"
            ok = False
            continue

        serial, iface = resolve_tty_iface(sys_tty_dir, tty)
        if serial is None:
            row["detail"] = f"{tty}: no USB interface under it (not an FTDI port?)"
            ok = False
            continue

        base, suffix = split_serial(serial)
        row["chip"] = suffix or "-"
        row["iface"] = iface
        want = expected_port(suffix, iface) if iface is not None else None
        row["expected"] = want
        row["base"] = base

        if want is None:
            row["detail"] = (f"chip serial {serial!r} does not end with a known "
                             f"chip suffix ({'/'.join(CHIP_ORDER)})")
        elif want != port:
            chip, _ = port_chip(want)
            row["detail"] = (f"chip {suffix} interface {iface} belongs on port "
                             f"{want}, not port {port} (port {port} belongs to "
                             f"chip {port_chip(port)[0]})")
        else:
            row["ok"] = True

        if not row["ok"]:
            ok = False

    return rows, ok


def path_sort_key(path):
    """Sort bus-port names the way the ports physically nest.

    Plain string order puts 2-1.10 before 2-1.2, which would hand chip A to the
    wrong chip on a hub with more than nine downstream ports."""
    parts = []
    for chunk in re.split(r"[.\-:]", path or ""):
        parts.append(int(chunk) if chunk.isdigit() else -1)
    return parts


def _port_sort_key(name):
    return (0, int(name[4:])) if name[4:].isdigit() else (1, 0)


# ------------------------------------------------------------ identity defaults

def load_env_file(path=ENV_FILE_DEFAULT):
    """Parse KEY=VALUE lines; missing file is normal and yields {}."""
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def resolve_identity(env_values, key, cli_value=None, default=""):
    """CLI flag > process environment > openmux.env > built-in default.

    An EMPTY environment value counts as unset, matching the precedence the
    provisioning scripts have always used."""
    if cli_value:
        return cli_value
    env = os.environ.get(key)
    if env:
        return env
    value = env_values.get(key)
    if value:
        return value
    return default


def format_rows(rows, headers):
    """Small fixed-width table so text output lines up without a dependency."""
    cells = [["" if cell is None else str(cell) for cell in row] for row in rows]
    widths = [len(header) for header in headers]
    for row in cells:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    spec = "  ".join(f"{{:<{width}}}" for width in widths)
    out = [spec.format(*headers), spec.format(*("-" * width for width in widths))]
    out += [spec.format(*row) for row in cells]
    return "\n".join(out)
