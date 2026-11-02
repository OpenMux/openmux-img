#!/usr/bin/env python3
"""check-openmux-env.py - validate an openmux.env before an image ships it.

Run by the medium build (`./build.sh --openmux-env <file>`); the gate exists
because the reader on the device is silent in two ways that only become visible
on a programmed chip:

  * `load_env_file()` in scan_ftdi.py keeps EVERYTHING after the first '=' and
    strips quotes off the ends. `OPENMUX_MANUFACTURER="ACME AS"
    # vendor` therefore yields the value `ACME AS"  # vendor`: the comment is
    part of the string, and so is the quote, which then lands inside
    `manufacturer="..."` in the ftdi_eeprom conf.
  * a key spelled slightly wrong is not an error anywhere in the chain. The file
    parses, the tools find nothing under the real name, and the built-in default
    is used instead - so the medium looks configured and writes the stock
    strings.

Neither is detectable on the stick, so both are detected here. Answers come from
the shipped code rather than from a second copy of the format: the key names, the
defaults and the parsing itself come from `scan_ftdi.py`, and the serial prefixes
are read out of the udev rules the same build ships, because an env file cannot
change a rule - it can only disagree with one.

Values are reported as `load_env_file()` resolves them, which is the only form
the flashers ever see.

Exit: 0 = shippable (warnings allowed), 1 = errors, 2 = unusable input.
"""

import argparse
import importlib.util
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TOOLS_DEFAULT = REPO / "package/openmux-factory-tools/opt/openmux-factory-tools"
RULES_DEFAULT = REPO / "package/openmux-hardware/etc/udev/rules.d/99-openmux-ftdi.rules"

# Comments and blank lines are the only non-data lines the reader skips.
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# The two shapes `99-openmux-ftdi.rules` uses: the console's flat port links and
# a card's per-base folder. Both spell the prefix as literally as the rules get.
RULE_RE = {
    "internal": re.compile(r'ATTRS\{serial\}=="([A-Z]+)\[0-9\]\*-[A-C]".*'
                           r'SYMLINK\+="openmux/port\d+"'),
    "external": re.compile(r'ATTRS\{serial\}=="([A-Z]+)\[0-9\]\*-[A-C]".*'
                           r'SYMLINK\+="openmux/%c/port\d+"'),
}


def import_scan_ftdi(tools_dir):
    """Import the shipped module, so key names and parsing are not restated here.

    Byte-code writing is off first: a __pycache__ inside package/ would
    otherwise appear every time this runs, in the tree dpkg-deb packs.
    """
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(tools_dir))
    try:
        import scan_ftdi
    except ImportError as exc:          # pragma: no cover - build tree problem
        sys.exit(f"ERROR: cannot import {tools_dir}/scan_ftdi.py: {exc}")
    return scan_ftdi


def load_script_defaults(F, tools_dir):
    """{key: default} taken from the two flashers, not restated here.

    MANUFACTURER_DEFAULT / PRODUCT_DEFAULT live in the scripts that write the
    EEPROM, one pair each, and are what an unset key resolves to on the device.
    Both files are import-safe (main() is behind __name__), and reading them is
    the only way this report cannot drift from what gets flashed.
    """
    out = {}
    for name, product_key in (("program-ftdi-internal.py", F.KEY_PRODUCT_INTERNAL),
                              ("program-ftdi-external.py", F.KEY_PRODUCT_EXTERNAL)):
        spec = importlib.util.spec_from_file_location(name[:-3].replace("-", "_"),
                                                      tools_dir / name)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        out[F.KEY_MANUFACTURER] = module.MANUFACTURER_DEFAULT
        out[product_key] = module.PRODUCT_DEFAULT
    return out


def rule_prefixes(rules_path):
    """{role: prefix} exactly as the shipped udev rules match them.

    Returns what it finds; an empty or unreadable rules file yields {} and the
    caller refuses rather than comparing against nothing.
    """
    try:
        text = rules_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    found = {}
    for role, pattern in RULE_RE.items():
        prefixes = set(pattern.findall(text))
        if len(prefixes) == 1:
            found[role] = prefixes.pop()
        elif prefixes:
            found[role] = None          # rules inconsistent: unsolvable here
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("env_file", help="the openmux.env to be shipped")
    ap.add_argument("--tools-dir", type=Path, default=TOOLS_DEFAULT,
                    help="directory holding scan_ftdi.py (default: this repo's)")
    ap.add_argument("--rules", type=Path, default=RULES_DEFAULT,
                    help="the 99-openmux-ftdi.rules the image ships")
    args = ap.parse_args()

    F = import_scan_ftdi(args.tools_dir)
    # Everything load_env_file() is consulted for, per the tools that read it.
    # Anything else in the file is dead text, which is why an unknown key here is
    # an error and not a warning: it is nearly always a typo for one of these.
    known = (F.KEY_MANUFACTURER, F.KEY_PRODUCT_INTERNAL, F.KEY_PRODUCT_EXTERNAL,
             F.KEY_PREFIX_INTERNAL, F.KEY_PREFIX_EXTERNAL)

    path = Path(args.env_file)
    try:
        raw = path.read_bytes()
    except OSError as exc:
        print(f"ERROR: {path}: {exc.strerror or exc}", file=sys.stderr)
        return 2
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        print(f"ERROR: {path}: not UTF-8 ({exc}): the values go verbatim into a "
              f"USB descriptor", file=sys.stderr)
        return 2

    errors, warnings = [], []
    seen = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            errors.append(f"{path.name}:{lineno}: not KEY=VALUE; the reader skips "
                          f"the line without a word")
            continue
        if stripped.startswith("export "):
            errors.append(f"{path.name}:{lineno}: 'export' is not part of the "
                          f"format; the key becomes 'export {stripped.split('=')[0]}'")
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        if not KEY_RE.match(key):
            errors.append(f"{path.name}:{lineno}: {key!r} is not a KEY the reader "
                          f"can find (upper-case, letters/digits/underscore)")
            continue
        if key in seen:
            # Direction matters: load_env_file() assigns into a dict line by line,
            # so the LAST line wins and the earlier one disappears. Reporting the
            # survivor is what lets the editor delete the right line.
            errors.append(f"{path.name}:{lineno}: {key} given twice; the reader "
                          f"keeps THIS line and discards line {seen[key]} - "
                          f"delete one of them")
            seen[key] = lineno
            continue
        seen[key] = lineno
        if key not in known:
            errors.append(f"{path.name}:{lineno}: {key} is not read by any tool. "
                          f"Known keys: {', '.join(sorted(known))}")
            continue
        # Everything below judges the value AS load_env_file() KEEPS it - strip,
        # then str() of quotes from each END - because that substring, not the text
        # on the line, is what reaches the EEPROM. `"ACME"` is fine; `"ACME" note`
        # parses to `ACME" note`, quote and all, and a trailing quote is eaten
        # rather than reported (measured: `ACME"Mfg"` reads back as `ACME"Mfg`).
        parsed = value.strip().strip('"').strip("'")
        if "#" in parsed:
            errors.append(f"{path.name}:{lineno}: {key} has a '#' in its value. "
                          f"This file has no inline comments - the '#' and "
                          f"everything after it is part of the string")
        if '"' in parsed or "'" in parsed:
            errors.append(f"{path.name}:{lineno}: {key} has a quote left inside the "
                          f"value after the enclosing pair is removed. It survives "
                          f"into manufacturer=\"...\" in the ftdi_eeprom conf")
        if [c for c in parsed if ord(c) < 32 or ord(c) > 126]:
            errors.append(f"{path.name}:{lineno}: {key} has a non-printable or "
                          f"non-ASCII character; it goes into a USB descriptor "
                          f"read on other people's machines")
        if value.strip() != parsed:
            warnings.append(f"{path.name}:{lineno}: {key} is quoted - fine, but "
                            f"the quotes are optional and are not part of the value")
        if len(parsed) > 32:
            warnings.append(f"{path.name}:{lineno}: {key} is "
                            f"{len(parsed)} characters; it is shown "
                            f"in a host's device-manager field, read it back once")

    if not seen:
        errors.append(f"{path}: no KEY=VALUE lines. Shipping an empty file changes "
                      f"nothing - every tool falls back to its built-in default - "
                      f"so it would only look configured")

    # The authoritative reading: what the flashers will actually resolve.
    resolved = F.load_env_file(str(path))
    for key, line in sorted(seen.items()):
        if resolved.get(key) is None and key in known:
            errors.append(f"{path.name}:{line}: {key} is present but the shipped "
                          f"parser reads no value for it")

    # Values that are empty resolve to the default in resolve_identity(): the
    # file looks set and is not.
    for key, value in sorted(resolved.items()):
        if key in known and not value:
            errors.append(f"{key}: empty value falls back to the built-in default "
                          f"- delete the line instead of blanking it")

    # Prefixes: this file cannot change the rules, only fight them.
    rules = rule_prefixes(args.rules)
    if not rules:
        errors.append(f"{args.rules}: could not read the serial prefixes the image "
                      f"rules match, so prefix keys cannot be checked")
    for env_key, role in ((F.KEY_PREFIX_INTERNAL, "internal"),
                          (F.KEY_PREFIX_EXTERNAL, "external")):
        want = rules.get(role)
        if want is None and role not in rules:
            continue
        got = resolved.get(env_key)
        if got is None:
            continue
        if want is None:
            errors.append(f"{env_key}: {args.rules.name} does not match one "
                          f"{role} prefix unambiguously, so {got!r} cannot be "
                          f"checked against it")
            continue
        if not re.fullmatch(r"[A-Z]+", got):
            errors.append(f"{env_key}={got!r}: the rules spell a prefix as "
                          f"upper-case letters followed by [0-9]*; anything else "
                          f"matches no chip")
        elif got != want:
            errors.append(f"{env_key}={got!r} but {args.rules.name} only matches "
                          f"{want!r}. An env file cannot change a udev rule: the "
                          f"flash would succeed and the chip would come back with a "
                          f"serial no rule claims, i.e. a board with no "
                          f"/dev/openmux ports. Changing a prefix means changing "
                          f"the rules, openmux-detect-hardware.sh and scan_ftdi.py "
                          f"together (see om-verify.sh's prefix check)")

    # ---------------- reporting ----------------
    defaults = load_script_defaults(F, args.tools_dir)
    defaults[F.KEY_PREFIX_INTERNAL] = F.PREFIX_INTERNAL_DEFAULT
    defaults[F.KEY_PREFIX_EXTERNAL] = F.PREFIX_EXTERNAL_DEFAULT
    order = [F.KEY_MANUFACTURER, F.KEY_PRODUCT_INTERNAL, F.KEY_PRODUCT_EXTERNAL,
             F.KEY_PREFIX_INTERNAL, F.KEY_PREFIX_EXTERNAL]
    rows = []
    for key in order:
        value = resolved.get(key)
        rows.append([key, value if value else defaults.get(key, ""),
                     "file" if value else "built-in default"])
    print(F.format_rows(rows, ["key", "value the tools will use", "source"]))

    # Precedence on the stick is flag > process env > this file > default, so an
    # operator exporting these in a shell gets a different answer than the image
    # will. Harmless at build time, worth one line because it is invisible.
    shadowed = [key for key in order if os.environ.get(key)]
    if shadowed:
        print("NOTE: " + ", ".join(shadowed) + " is also set in this build "
              "environment. That does not reach the image, but on a stick the "
              "same variables outrank this file.", file=sys.stderr)

    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        print(f"ERROR: {path} is not shippable: {len(errors)} problem(s)",
              file=sys.stderr)
        return 1
    print(f"OK: {path} ({len(seen)} key(s)) matches the shipped parser and the "
          f"shipped udev rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
