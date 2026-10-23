#!/usr/bin/env bash
# list-ftdis.sh - a name people already know, now a wrapper.
#
# This used to be a flat dump of every 0403:6011 on the bus, which on a real
# OpenMux is a misleading list: the console's own chips and a plugged-in EX-12
# adapter are the same chip family, so their rows looked interchangeable, and a
# role printed there would have been a guess read back out of a serial string -
# the very thing a mis-aimed flash corrupts. The scanner groups by hub instead,
# says why it called each row what it did, and keeps the console out of anything
# offered as a programming target. Options: scan-ftdi-adapters.py --help
#
# Exit status differs from the old script on purpose: an empty bus is not an
# error here (0), so a caller can tell "nothing plugged in" from "broken tool".
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$here/scan-ftdi-adapters.py" "$@"
