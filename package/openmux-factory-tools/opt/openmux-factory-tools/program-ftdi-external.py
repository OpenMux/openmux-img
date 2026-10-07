#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

EXPECTED_ID = "0403:6011"

# The adapter's 3 FT4232H chips sit at these sub-ports of its onboard hub; only the hub's
# own base USB path varies with which physical port the adapter is plugged into.
USB_PATH_DEFAULT = "2-1.4"
TARGET_SUFFIXES = [
    ("A", ".2"),
    ("B", ".3"),
    ("C", ".4"),
]

MANUFACTURER = "OpenMux"
PRODUCT = "OpenMux Extention EX-12"  # spelling as requested

# Overridable via --manufacturer/--product, OPENMUX_MANUFACTURER/OPENMUX_PRODUCT_EXTERNAL env vars, or this file.
ENV_FILE = Path("/boot/firmware/openmux.env")
PRODUCT_ENV_KEY = "OPENMUX_PRODUCT_EXTERNAL"


def read_env_file():
    values = {}
    try:
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return values


def resolve_value(env_values, env_key, cli_value, default):
    if cli_value:
        return cli_value
    if os.environ.get(env_key):
        return os.environ[env_key]
    return env_values.get(env_key, default)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def read_attr(devdir: Path, name: str, default=""):
    try:
        return (devdir / name).read_text().strip()
    except Exception:
        return default


def usb_path_info(usb_path: str):
    devdir = Path("/sys/bus/usb/devices") / usb_path
    if not devdir.exists():
        raise RuntimeError(f"{usb_path}: not found in /sys/bus/usb/devices")
    bus = int(read_attr(devdir, "busnum"))
    dev = int(read_attr(devdir, "devnum"))
    busdev = f"{bus:03d}:{dev:03d}"
    man = read_attr(devdir, "manufacturer", "?")
    prod = read_attr(devdir, "product", "?")
    ser = read_attr(devdir, "serial", "<none>")
    return bus, dev, busdev, man, prod, ser


def lsusb_id(busdev: str):
    cp = run(["lsusb", "-s", busdev])
    if cp.returncode != 0:
        return ""
    m = re.search(r"\bID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\b", cp.stdout)
    return m.group(1).lower() if m else ""


def make_conf(serial: str, manufacturer: str, product: str):
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


def flash_target(label: str, usb_path: str, serial: str, manufacturer: str, product: str, dry_run: bool):
    bus, dev, busdev, man, prod, old_ser = usb_path_info(usb_path)
    vidpid = lsusb_id(busdev)
    if vidpid != EXPECTED_ID:
        raise RuntimeError(f"{usb_path} ({busdev}) has {vidpid}, expected {EXPECTED_ID}")

    print(f"[OK] {label}: path={usb_path} busdev={busdev} id={vidpid} manufacturer='{man}' product='{prod}' serial='{old_ser}'")

    conf_text = make_conf(serial, manufacturer, product)
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".conf", prefix=f"ext_{label}_") as tf:
        tf.write(conf_text)
        conf_path = tf.name

    print(f"[CONF] {label}: {conf_path}")
    print(conf_text.strip(), "\n")

    device_url = f"d:{bus:03d}/{dev:03d}"
    cmd = ["sudo", "ftdi_eeprom", "--device", device_url, "--flash-eeprom", conf_path]

    if dry_run:
        print("[DRY-RUN] " + " ".join(cmd))
        return

    print(f"[FLASH] {label}: url={device_url} -> serial={serial}")
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(
            f"{label} flash failed\nCMD: {' '.join(cmd)}\nSTDOUT:\n{cp.stdout}\nSTDERR:\n{cp.stderr}"
        )
    print(f"[DONE] {label}")


def main():
    ap = argparse.ArgumentParser(description="Program OpenMux external adapter FTDI serials (A/B/C).")
    ap.add_argument("serial_number", help='Base serial, e.g. "OMX1234" -> OMX1234-A/B/C')
    ap.add_argument("--usb-path", default=USB_PATH_DEFAULT, help=f"Base USB path of the adapter's onboard hub (default: {USB_PATH_DEFAULT}); the three chips are programmed at <usb-path>.2/.3/.4")
    ap.add_argument("--manufacturer", help=f'Override EEPROM manufacturer string (default: "{MANUFACTURER}"; also settable via OPENMUX_MANUFACTURER in {ENV_FILE} or the environment)')
    ap.add_argument("--product", help=f'Override EEPROM product string (default: "{PRODUCT}"; also settable via {PRODUCT_ENV_KEY} in {ENV_FILE} or the environment)')
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    for tool in ("lsusb", "ftdi_eeprom"):
        if run(["bash", "-lc", f"command -v {tool}"]).returncode != 0:
            print(f"ERROR: missing tool: {tool}")
            sys.exit(1)

    base = args.serial_number.strip()
    if not base:
        print("ERROR: serial_number cannot be empty")
        sys.exit(1)

    env_values = read_env_file()
    manufacturer = resolve_value(env_values, "OPENMUX_MANUFACTURER", args.manufacturer, MANUFACTURER)
    product = resolve_value(env_values, PRODUCT_ENV_KEY, args.product, PRODUCT)

    plan = []
    for suffix, port_suffix in TARGET_SUFFIXES:
        new_serial = f"{base}-{suffix}"
        plan.append((suffix, f"{args.usb_path}{port_suffix}", new_serial))

    print("Planned programming:")
    for suffix, path, s in plan:
        print(f"  {path} -> {s}")
    print(f'  manufacturer="{manufacturer}"')
    print(f'  product="{product}"')

    if not args.yes:
        yn = input("Proceed with flashing? [y/N] ").strip().lower()
        if yn not in ("y", "yes"):
            print("Aborted.")
            return

    try:
        for suffix, path, new_serial in plan:
            flash_target(suffix, path, new_serial, manufacturer, product, args.dry_run)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    print("\nDone. Verify:")
    print(f"for p in {' '.join(f'{args.usb_path}{s}' for _, s in TARGET_SUFFIXES)}; do")
    print("  echo \"=== $p ===\"")
    print("  cat /sys/bus/usb/devices/$p/{manufacturer,product,serial} 2>/dev/null || true")
    print("done")


if __name__ == "__main__":
    main()
