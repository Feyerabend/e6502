#!/usr/bin/env python3
"""BREAK (Ctrl-C) test for the e6502 BASIC family.

This can't use the .bas/.expected harness because it needs to send a signal to
a *running* program, so it lives on its own.  For each tier it starts an
infinite loop, sends SIGINT (as Ctrl-C would), and checks that:

  1. the program stops with "BREAK IN <line>", and
  2. the REPL is still alive afterwards (a follow-up PRINT still runs).

Usage:  python3 tests/test_break.py
"""

import os
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "m6502", "m6502")
TIERS = [("nano", "1-nano"), ("integer", "2-integer"), ("msbasic", "3-msbasic")]


def wait_for(pred, timeout):
    """Spin until pred() is true or timeout elapses."""
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.02)
    return False


def run_one(binpath):
    p = subprocess.Popen([EMU, "-r", "-a", "800", binpath],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1)
    # start an infinite loop and leave stdin open so it keeps running
    p.stdin.write("10 PRINT 7\n20 GOTO 10\nRUN\n")
    p.stdin.flush()
    time.sleep(0.5)              # let the loop spin
    p.send_signal(signal.SIGINT)  # Ctrl-C
    time.sleep(0.3)
    try:
        p.stdin.write("PRINT 314\n")  # prove the REPL survived the break
        p.stdin.flush()
        p.stdin.close()
    except (BrokenPipeError, ValueError):
        pass
    try:
        out, _ = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        out = p.communicate()[0]
        return out, False, "hang after BREAK"
    ok = ("BREAK IN" in out) and ("314" in out)
    why = "" if ok else "no BREAK" if "BREAK IN" not in out else "REPL dead"
    return out, ok, why


def main():
    if not os.path.exists(EMU):
        sys.stderr.write("emulator not built: %s  (run `make`)\n" % EMU)
        sys.exit(2)
    failed = 0
    for name, d in TIERS:
        b = os.path.join(ROOT, "basic", d, "basic.bin")
        if not os.path.exists(b):
            print("  SKIP %s (not built)" % name)
            continue
        _, ok, why = run_one(b)
        print("  %-4s %s%s" % ("PASS" if ok else "FAIL", name,
                               "" if ok else "  (" + why + ")"))
        failed += 0 if ok else 1
    print("---- break: %s ----" % ("ok" if not failed else "%d failed" % failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
