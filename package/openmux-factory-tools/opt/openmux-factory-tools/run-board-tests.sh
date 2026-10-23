#!/usr/bin/env bash
# run-board-tests.sh - drive serial-test.py across a set of loopback pairs.
#
# Works for the console (8 ports, flat /dev/openmux/portN) and for an EX-12
# adapter (12 ports under /dev/openmux/<serial>/). To test a card, plug in ONE
# adapter, program it, replug, then:
#
#   run-board-tests.sh --port-base /dev/openmux/OMX1234 --pairs card
#
# WHY THE PAIR SETS ARE SHAPED LIKE THEY ARE. A pairwise loopback proves that two
# ports are wired together; it cannot prove the ports are NUMBERED correctly,
# because each pair is exercised in both directions and swapping the two ends of
# one plug is invisible. Pairing ports within one chip (the historical
# 1-2/3-4/5-6/7-8) additionally cannot notice a chip whose four ports come up in
# reverse: 5-6 simply becomes 8-7, which is still an allowed pair. The `console`
# and `card` profiles therefore shift by one, which puts a pair across every seam
# between chips (4|5, 8|9, and 12|1 around the end), and the numbering itself is
# verified separately from sysfs by scan-ftdi-adapters.py --audit, which needs no
# fixture at all and runs first by default.
#
# Add a new test by adding another run_* call near the bottom; keep tests
# independent so one failure does not hide the others.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_TEST="$SCRIPT_DIR/serial-test.py"
SCANNER="$SCRIPT_DIR/scan-ftdi-adapters.py"

# Everything from the bare marker below to the end marker is pure: no devices, no
# reads, no writes. Extract it with awk to test it offline. The markers are
# deliberately bare - an awk program spelled out inside a marker matches both the
# start and the end pattern, and the extraction comes back as two comment lines.
# ---- pure helpers ----
# Profiles list port pairs, "a:b" comma separated. A pair set must be a PERFECT
# MATCHING: every port used exactly once, otherwise a port goes untested while
# the summary still looks complete.
ftdi_pair_profile() {
  case "$1" in
    # Original molded fixture wiring: both ports of every pair on one chip.
    legacy-console) echo "1:2,3:4,5:6,7:8" ;;
    # OpenMux console, 8 ports / 2 chips. Shifted so 4:5 crosses the A|B seam and
    # 8:1 crosses the far end of chip B.
    console)        echo "2:3,4:5,6:7,8:1" ;;
    # EX-12, 12 ports / 3 chips: 4:5 and 8:9 cross the chip seams, 12:1 wraps.
    card)           echo "2:3,4:5,6:7,8:9,10:11,12:1" ;;
    *)              echo "" ;;
  esac
}

# Chip letter and interface a port belongs to, per 99-openmux-ftdi.rules:
# interfaces 00-03 of chip A/B/C are ports 1-4 / 5-8 / 9-12.
ftdi_port_chip() {
  local port=$1 block=$(( ($1 - 1) / 4 )) offset=$(( ($1 - 1) % 4 ))
  local chips=(A B C)
  (( port < 1 || port > 12 )) && { echo "? ?"; return; }
  echo "${chips[$block]} $offset"
}

ftdi_pair_label() {
  read -r chip_a if_a <<<"$(ftdi_port_chip "$1")"
  read -r chip_b if_b <<<"$(ftdi_port_chip "$2")"
  local label="Port $1-$2"
  [[ $chip_a == "?" ]] && { echo "$label"; return; }
  if [[ $chip_a == "$chip_b" ]]; then
    echo "$label (both on chip $chip_a)"
  else
    echo "$label (chip $chip_a if$if_a -> chip $chip_b if$if_b, seam)"
  fi
}

# Echoes one "a b" per line; returns non-zero with a reason on stderr when the
# set is not a perfect matching over 1..N.
ftdi_validate_pairs() {
  local spec=$1 seen="" pair a b
  local -a out=()
  local IFS=,
  for pair in $spec; do
    pair=${pair// /}
    [[ $pair == *:* ]] || { echo "pair '$pair' is not A:B" >&2; return 1; }
    a=${pair%%:*}; b=${pair##*:}
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || { echo "pair '$pair' is not numeric" >&2; return 1; }
    (( a >= 1 && a <= 12 && b >= 1 && b <= 12 )) || { echo "pair '$pair': ports must be 1-12" >&2; return 1; }
    (( a == b )) && { echo "pair '$pair' loops a port into itself" >&2; return 1; }
    case " $seen " in *" $a "*|*" $b "*) echo "ports $a/$b repeat: every port must appear exactly once" >&2; return 1 ;; esac
    seen="$seen $a $b"
    out+=("$a $b")
  done
  ((${#out[@]} > 0)) || { echo "no pairs given" >&2; return 1; }
  printf '%s\n' "${out[@]}"
}
# ---- end pure helpers ----

usage() {
  cat <<'USAGE'
usage: run-board-tests.sh [--port-base DIR] [--pairs PROFILE|A:B,C:D,...]
                          [--no-audit | --audit-only] [serial-test.py options]

  --port-base DIR   port directory to test (default /dev/openmux, which is the
                    console; an adapter's is /dev/openmux/<serial>)
  --pairs SPEC      'legacy-console' (1-2 3-4 5-6 7-8, the original fixture),
                    'console' (2-3 4-5 6-7 8-1, default), 'card'
                    (2-3 4-5 6-7 8-9 10-11 12-1), or your own A:B,C:D list.
                    Every port must appear exactly once.
  --no-audit        skip the sysfs numbering check that runs first
  --audit-only      run only the numbering check, no serial tests
  --sys-tty-dir DIR  sysfs tty tree the audit reads (default /sys/class/tty)
  --loops N         loopback iterations per pair, per direction (default 500)

Anything else is passed through to serial-test.py.
USAGE
}

PORT_BASE="/dev/openmux"
PROFILE="console"
SYS_TTY_DIR="/sys/class/tty"
DO_AUDIT=1
AUDIT_ONLY=0
FORWARD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port-base)    PORT_BASE=$2; shift 2 ;;
    --pairs)        PROFILE=$2; shift 2 ;;
    --sys-tty-dir)  SYS_TTY_DIR=$2; shift 2 ;;
    --no-audit)     DO_AUDIT=0; shift ;;
    --audit-only)   DO_AUDIT=1; AUDIT_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              FORWARD+=("$1"); shift ;;
  esac
done

if [[ ! -r $SERIAL_TEST ]]; then
  echo "serial-test.py not found or not readable: $SERIAL_TEST" >&2
  exit 2
fi

# A profile name expands to its spec; anything else is taken as a spec written by
# the person running the test, which is how a one-off wiring gets tested without
# editing this file.
spec=$(ftdi_pair_profile "$PROFILE")
[[ -z $spec ]] && spec=$PROFILE
PROFILE=${PROFILE:-console}
LIST=$(ftdi_validate_pairs "$spec" 2>&1) || {
  echo "ERROR: --pairs $PROFILE: $LIST" >&2
  [[ $spec == "$PROFILE" ]] && echo "Known profiles: legacy-console, console, card." >&2
  echo "Each port must be used exactly once, e.g. --pairs 1:2,3:4" >&2
  exit 2
}

# Ports the profile expects, and which of them actually exist.
expected=()
while read -r a b; do expected+=("$a" "$b"); done <<<"$LIST"
missing=()
for port in "${expected[@]}"; do
  [[ -e "$PORT_BASE/port$port" ]] || missing+=("port$port")
done
# Unique port count, used to tell a card with a chip missing from a card nobody
# has programmed yet.
have=0
for port in "${expected[@]}"; do [[ -e "$PORT_BASE/port$port" ]] && have=$((have + 1)); done

echo "Port directory: $PORT_BASE"
echo "Pair profile:   $PROFILE"
if [[ ! -d $PORT_BASE ]]; then
  echo "ERROR: $PORT_BASE does not exist."
  echo "There are no /dev/openmux ports to test, which means one of:"
  echo "  * the FTDI chips have not been programmed yet;"
  echo "  * they were programmed with a serial that 99-openmux-ftdi.rules does not match"
  echo "    (console chips must be OMC<digits>-A/-B; an adapter's own folder needs"
  echo "    OMX<digits>-A/-B/-C); or"
  echo "  * this is an adapter and the folder is named after its serial, e.g."
  echo "    --port-base /dev/openmux/OMX000042."
  echo "scan-ftdi-adapters.py shows what is programmed; --serials lists the bases."
  exit 2
fi
if (( ${#missing[@]} > 0 )); then
  echo "WARNING: ${#missing[@]} of the ports this profile needs are missing: ${missing[*]}"
  echo "  Ports are created four at a time, one chip at a time, so a shortfall of four"
  echo "  means a chip was never programmed - or was programmed with a serial the udev"
  echo "  rules do not match for this layout."
  (( have == 0 )) && echo "  Nothing at all is present here: nothing has been programmed under $PORT_BASE."
  echo "  Continuing with the pairs that do exist; the missing ones are reported as SKIP."
  echo
fi

if (( DO_AUDIT )); then
  echo "========================================"
  echo "Numbering audit (sysfs, no wiring needed)"
  echo "========================================"
  if [[ ! -r $SCANNER ]]; then
    echo "SKIP: $SCANNER not readable"
    audit_ok=0
  else
    python3 "$SCANNER" --audit --audit-only --port-base "$PORT_BASE" \
      --sys-tty-dir "$SYS_TTY_DIR"
    audit_ok=$?
    if (( audit_ok != 0 )); then
      echo "The port symlinks do not match the chips behind them. Fix that before wiring a"
      echo "loopback plug: with a wrong map, a pair that passes proves nothing about the"
      echo "ports it claims to cover."
    fi
  fi
  echo
  (( AUDIT_ONLY )) && exit "$audit_ok"
fi

# The plan, printed before anything is touched, so the plugs can be fitted from
# this screen and the seams seen while plugging.
echo "========================================"
echo "Loopback connections required"
echo "========================================"
while read -r a b; do
  printf '  %-14s %s\n' "$a <--> $b" "$(ftdi_pair_label "$a" "$b")"
done <<<"$LIST"
echo
echo "Fit a loopback plug on each pair above, then this runs $(wc -l <<<"$LIST") tests."
echo "Each pair is driven both ways and checks TX/RX both directions, RTS->CTS and"
echo "DTR->DSR, so a plug wired for data only will fail."
echo

results=()
overall_ok=${audit_ok:-0}
ran=0
pass=0
skipped=0

run_serial_test() {
  local name="$1" port_a="$2" port_b="$3"
  if [[ ! -e $port_a || ! -e $port_b ]]; then
    local absent=()
    [[ -e $port_a ]] || absent+=("$port_a")
    [[ -e $port_b ]] || absent+=("$port_b")
    echo "----------------------------------------"
    echo "SKIP: $name - missing ${absent[*]}"
    results+=("SKIP $name: port not present - that chip is unprogrammed, or was programmed "
              "with a serial the udev rules do not match")
    # Not a pass, and not the same as a failure: but a run that leaves ports
    # untested must not report success, or a half-programmed card walks out of the
    # factory with a green line next to it.
    skipped=$((skipped + 1))
    overall_ok=1
    return
  fi
  echo "========================================"
  echo "Running: $name ($port_a <-> $port_b)"
  echo "========================================"
  if python3 "$SERIAL_TEST" --port-a "$port_a" --port-b "$port_b" "${FORWARD[@]}"; then
    results+=("$name: PASS")
    pass=$((pass + 1))
  else
    results+=("$name: FAIL")
    overall_ok=1
  fi
  ran=$((ran + 1))
  echo
}

while read -r a b; do
  run_serial_test "$(ftdi_pair_label "$a" "$b")" "$PORT_BASE/port$a" "$PORT_BASE/port$b"
done <<<"$LIST"

echo "========================================"
echo "Summary"
echo "========================================"
for line in "${results[@]}"; do echo "$line"; done
echo "----"
echo "$pass/$ran pairs passed, $skipped skipped"\
$( [[ ${audit_ok:-0} != 0 ]] && echo ' (the numbering audit failed; see above)')
if (( skipped > 0 )); then
  echo "A skipped pair is an UNTESTED port, so this is not a pass even though the pairs"
  echo "that ran did pass. Program the missing chip, replug and run again."
fi

if (( ran > 0 && pass == 0 )); then
  echo
  echo "Every pair failed. When nothing passes, the fixture is usually the fault rather"
  echo "than twelve ports: check the plugs are fitted, and that they cross TX/RX AND"
  echo "RTS/CTS and DTR/DSR - serial-test.py holds the control lines low first and fails"
  echo "a plug that cannot show CTS and DSR idle."
fi

exit "$overall_ok"
