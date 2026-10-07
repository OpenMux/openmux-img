#!/usr/bin/env python3
import serial
import time
import argparse
import sys
import logging
import random

POLL_INTERVAL = 0.002
SIGNAL_TIMEOUT = 0.2
HEARTBEAT_EVERY = 50  # log progress every N loop iterations
PAYLOAD_DIGITS = 10  # fixed-width so dst.read() knows how many bytes to expect

log = logging.getLogger("serial-test")

def open_port(dev, baud=115200):
    log.debug("Opening port %s @ %d baud ...", dev, baud)
    t0 = time.time()
    s = serial.Serial(
        port=dev,
        baudrate=baud,
        timeout=0.5,
        write_timeout=0.5,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        rtscts=False,
        dsrdtr=False
    )
    s.reset_input_buffer()
    s.reset_output_buffer()
    log.debug("Opened %s in %.3fs", dev, time.time() - t0)
    return s

def wait_until(cond_fn, timeout=SIGNAL_TIMEOUT, poll=POLL_INTERVAL, desc=None):
    t0 = time.time()
    while (time.time() - t0) < timeout:
        if cond_fn():
            log.debug("wait_until(%s) satisfied after %.3fs", desc, time.time() - t0)
            return True
        time.sleep(poll)
    log.debug("wait_until(%s) TIMED OUT after %.3fs", desc, time.time() - t0)
    return False

def force_known_output_state(a, b):
    log.debug("Forcing known baseline output state (RTS/DTR low on both ports)")
    # Set both ports to known baseline outputs
    a.rts = False
    a.dtr = False
    b.rts = False
    b.dtr = False
    time.sleep(0.05)

def verify_initial_state(a, b):
    """
    Expected with both sides deasserted:
      a.cts=False, a.dsr=False, b.cts=False, b.dsr=False
    """
    log.debug("Verifying initial signal state")
    checks = [
        ("A.CTS initial LOW", a.cts is False),
        ("A.DSR initial LOW", a.dsr is False),
        ("B.CTS initial LOW", b.cts is False),
        ("B.DSR initial LOW", b.dsr is False),
    ]
    ok = all(x[1] for x in checks)
    log.debug("Initial state checks: %s", checks)
    return ok, checks

def test_tx_rx_repeated(src, dst, loops, label):
    log.info("Starting %s TX/RX test (%d loops, random %d-digit numbers)", label, loops, PAYLOAD_DIGITS)
    passes = 0
    failures = []

    for i in range(1, loops + 1):
        number = random.randint(0, 10 ** PAYLOAD_DIGITS - 1)
        payload = str(number).zfill(PAYLOAD_DIGITS).encode("ascii")
        dst.reset_input_buffer()
        src.write(payload)
        src.flush()
        log.debug("%s TX/RX iter %d: wrote %r, reading %d bytes ...", label, i, payload, len(payload))
        got = dst.read(len(payload))
        log.debug("%s TX/RX iter %d: got %r", label, i, got)
        if got == payload:
            passes += 1
        else:
            log.warning("%s TX/RX iter %d: MISMATCH expected %r got %r", label, i, payload, got)
            failures.append((i, payload, got))
            break
        if i % HEARTBEAT_EVERY == 0 or i == loops:
            log.info("%s TX/RX: iteration %d/%d (passes so far: %d)", label, i, loops, passes)

    ok = (passes == loops)
    msg = f"{label} TX/RX {'PASS' if ok else 'FAIL'} ({passes}/{loops})"
    log.info(msg)
    return ok, msg, failures

def test_rts_to_cts_repeated(src, dst, loops, label):
    log.info("Starting %s RTS->CTS test (%d loops)", label, loops)
    passes = 0
    failures = []

    # verify initial mapping at current state
    initial_ok = (src.rts is False and dst.cts is False)
    log.debug("%s RTS->CTS initial_ok=%s", label, initial_ok)

    for i in range(1, loops + 1):
        # drive low, verify
        src.rts = False
        ok_low = wait_until(lambda: dst.cts is False, desc=f"{label} RTS->CTS low iter {i}")

        # drive high, verify
        src.rts = True
        ok_high = wait_until(lambda: dst.cts is True, desc=f"{label} RTS->CTS high iter {i}")

        # back low, verify again (helps catch sticky lines)
        src.rts = False
        ok_back_low = wait_until(lambda: dst.cts is False, desc=f"{label} RTS->CTS back-low iter {i}")

        if ok_low and ok_high and ok_back_low:
            passes += 1
        else:
            log.warning("%s RTS->CTS iter %d: FAIL low=%s high=%s back_low=%s", label, i, ok_low, ok_high, ok_back_low)
            failures.append((i, ok_low, ok_high, ok_back_low))
            break
        if i % HEARTBEAT_EVERY == 0 or i == loops:
            log.info("%s RTS->CTS: iteration %d/%d (passes so far: %d)", label, i, loops, passes)

    ok = (passes == loops) and initial_ok
    msg = f"{label} RTS->CTS {'PASS' if ok else 'FAIL'} ({passes}/{loops}), initial_ok={initial_ok}"
    log.info(msg)
    return ok, msg, failures

def test_dtr_to_dsr_repeated(src, dst, loops, label):
    log.info("Starting %s DTR->DSR test (%d loops)", label, loops)
    passes = 0
    failures = []

    # verify initial mapping at current state
    initial_ok = (src.dtr is False and dst.dsr is False)
    log.debug("%s DTR->DSR initial_ok=%s", label, initial_ok)

    for i in range(1, loops + 1):
        # drive low, verify
        src.dtr = False
        ok_low = wait_until(lambda: dst.dsr is False, desc=f"{label} DTR->DSR low iter {i}")

        # drive high, verify
        src.dtr = True
        ok_high = wait_until(lambda: dst.dsr is True, desc=f"{label} DTR->DSR high iter {i}")

        # back low, verify again
        src.dtr = False
        ok_back_low = wait_until(lambda: dst.dsr is False, desc=f"{label} DTR->DSR back-low iter {i}")

        if ok_low and ok_high and ok_back_low:
            passes += 1
        else:
            log.warning("%s DTR->DSR iter %d: FAIL low=%s high=%s back_low=%s", label, i, ok_low, ok_high, ok_back_low)
            failures.append((i, ok_low, ok_high, ok_back_low))
            break
        if i % HEARTBEAT_EVERY == 0 or i == loops:
            log.info("%s DTR->DSR: iteration %d/%d (passes so far: %d)", label, i, loops, passes)

    ok = (passes == loops) and initial_ok
    msg = f"{label} DTR->DSR {'PASS' if ok else 'FAIL'} ({passes}/{loops}), initial_ok={initial_ok}"
    log.info(msg)
    return ok, msg, failures

def run_pair_test(port_a, port_b, baud, loops):
    log.info("Opening ports: A=%s B=%s @ %d baud", port_a, port_b, baud)
    a = open_port(port_a, baud)
    b = open_port(port_b, baud)

    summary_lines = []
    detailed_failures = []
    overall_ok = True

    try:
        time.sleep(0.1)
        force_known_output_state(a, b)

        # Initial state verification
        init_ok, init_checks = verify_initial_state(a, b)
        for name, ok in init_checks:
            summary_lines.append(f"{name}: {'PASS' if ok else 'FAIL'}")
        if not init_ok:
            overall_ok = False
            log.error("Initial state check failed, aborting remaining tests")
            return overall_ok, summary_lines, detailed_failures

        # (test_fn, args, failure_label) run in order; stop at the first failure
        sub_tests = [
            (test_tx_rx_repeated, (a, b, loops, "A->B"), "A->B TX/RX"),
            (test_tx_rx_repeated, (b, a, loops, "B->A"), "B->A TX/RX"),
            (test_rts_to_cts_repeated, (a, b, loops, "A->B"), "A.RTS->B.CTS"),
            (test_rts_to_cts_repeated, (b, a, loops, "B->A"), "B.RTS->A.CTS"),
            (test_dtr_to_dsr_repeated, (a, b, loops, "A->B"), "A.DTR->B.DSR"),
            (test_dtr_to_dsr_repeated, (b, a, loops, "B->A"), "B.DTR->A.DSR"),
        ]
        for test_fn, test_args, failure_label in sub_tests:
            ok, msg, fails = test_fn(*test_args)
            summary_lines.append(msg)
            if not ok:
                overall_ok = False
                detailed_failures.append((failure_label, fails[:10]))
                log.error("%s failed, aborting remaining tests", failure_label)
                break

    finally:
        log.debug("Closing ports")
        a.close()
        b.close()

    return overall_ok, summary_lines, detailed_failures

def main():
    parser = argparse.ArgumentParser(description="Pairwise serial loopback stress test")
    parser.add_argument("--port-a", required=True, help="e.g. /dev/ttyUSB0 or COM3")
    parser.add_argument("--port-b", required=True, help="e.g. /dev/ttyUSB1 or COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--loops", type=int, default=500, help="Iterations per test (default: 500)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable INFO-level progress logging")
    parser.add_argument("-d", "--debug", action="store_true", help="Enable DEBUG-level logging (per-iteration detail)")
    args = parser.parse_args()

    level = logging.WARNING
    if args.verbose:
        level = logging.INFO
    if args.debug:
        level = logging.DEBUG
    logging.basicConfig(
        level=level,
        format="%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )

    log.info("Starting test: A=%s B=%s baud=%d loops=%d", args.port_a, args.port_b, args.baud, args.loops)
    overall_ok, summary, failures = run_pair_test(
        args.port_a, args.port_b, args.baud, args.loops
    )


    print(f"Testing {args.port_a} <-> {args.port_b}")
    print(f"Loops per sub-test: {args.loops}")
    print("-" * 60)
    for line in summary:
        print(line)

    if failures:
        print("-" * 60)
        print("Failure samples (first 10 per test):")
        for test_name, sample in failures:
            print(f"\n{test_name}:")
            for item in sample:
                print(f"  {item}")

    print("-" * 60)
    print("OVERALL:", "PASS" if overall_ok else "FAIL")
    sys.exit(0 if overall_ok else 1)

if __name__ == "__main__":
    main()
