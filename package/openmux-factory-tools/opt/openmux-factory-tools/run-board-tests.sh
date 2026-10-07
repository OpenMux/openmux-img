#!/usr/bin/env bash
# Runs serial-test.py across this board's internal serial port pairs.
# To add a new test, add another run_test call below.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_TEST="$SCRIPT_DIR/serial-test.py"
PORT_BASE="/dev/openmux"
EXTRA_ARGS=("$@")

if [[ ! -x "$SERIAL_TEST" ]]; then
  echo "serial-test.py not found or not executable: $SERIAL_TEST" >&2
  exit 1
fi

results=()
overall_ok=0

run_serial_test() {
  local name="$1" port_a="$2" port_b="$3"
  echo "========================================"
  echo "Running: $name ($port_a <-> $port_b)"
  echo "========================================"
  if "$SERIAL_TEST" --port-a "$port_a" --port-b "$port_b" "${EXTRA_ARGS[@]}"; then
    results+=("$name: PASS")
  else
    results+=("$name: FAIL")
    overall_ok=1
  fi
  echo
}

run_serial_test "Port 1-2" "$PORT_BASE/port1" "$PORT_BASE/port2"
run_serial_test "Port 3-4" "$PORT_BASE/port3" "$PORT_BASE/port4"
run_serial_test "Port 5-6" "$PORT_BASE/port5" "$PORT_BASE/port6"
run_serial_test "Port 7-8" "$PORT_BASE/port7" "$PORT_BASE/port8"

echo "========================================"
echo "Summary"
echo "========================================"
for line in "${results[@]}"; do
  echo "$line"
done

exit "$overall_ok"
