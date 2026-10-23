#!/bin/sh
# Detects the console's internal FTDI (serial matching "OMC*-A") and records its
# manufacturer/product/serial identity to /etc/openmux-hardware for other services
# to source at boot.
#
# The OMC prefix must match 99-openmux-ftdi.rules and the factory tools' default;
# the three live in two packages. See the header of that rules file.
set -eu

OUT="/etc/openmux-hardware"

command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 2>/dev/null || true

# USB enumeration can lag behind this running this early in boot; retry briefly.
found=""
tries=0
while [ "$tries" -lt 10 ] && [ -z "$found" ]; do
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    [ -f "$d/serial" ] || continue
    serial="$(cat "$d/serial" 2>/dev/null || true)"
    case "$serial" in
      OMC*-A) found="$d" ;;
    esac
    [ -n "$found" ] && break
  done
  [ -n "$found" ] && break
  tries=$((tries + 1))
  sleep 1
done

if [ -z "$found" ]; then
  echo "openmux-detect-hardware: no FTDI with serial matching 'OMC*-A' found; leaving $OUT untouched." >&2
  exit 0
fi

manufacturer="$(cat "$found/manufacturer" 2>/dev/null || echo "")"
product_full="$(cat "$found/product" 2>/dev/null || echo "")"
serial_full="$(cat "$found/serial" 2>/dev/null || echo "")"

product="${product_full%%,*}"
serial="${serial_full%%-*}"

umask 022
cat > "$OUT" <<EOF
OPENMUX_MANUFACTURER="$manufacturer"
OPENMUX_PRODUCT="$product"
OPENMUX_SERIAL="$serial"
EOF

echo "openmux-detect-hardware: wrote $OUT (manufacturer='$manufacturer' product='$product' serial='$serial')"
