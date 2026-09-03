#!/usr/bin/env python3
"""Test harness for the h6502 memory-hierarchy model.

A test case is a pair of files in tests/cases/memsys/:

    NAME.cmd       one line of h6502 arguments (shell quoting honoured);
                   any further lines are comments describing what it proves
    NAME.expected  the expected stdout

Cases are run from the repository root, so paths inside a .cmd are written
relative to it (h6502/demos/loop.bin).  The model is deterministic as long as
no case selects random replacement, so expected output is compared exactly.

Usage:
    python3 tests/run_mem_tests.py            run every case
    python3 tests/run_mem_tests.py NAME ...   run named cases
    python3 tests/run_mem_tests.py --bless    regenerate .expected files
"""

import os
import shlex
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
H6502 = os.path.join(ROOT, "h6502", "h6502")
CACHETEST = os.path.join(ROOT, "h6502", "cachetest")
CASES = os.path.join(ROOT, "tests", "cases", "memsys")
TIMEOUT = 30


def case_args(path):
    """First non-comment, non-blank line of a .cmd file, shell-split."""
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return shlex.split(line)
    raise ValueError("%s has no command line" % path)


def run_case(name, bless=False):
    cmd = os.path.join(CASES, name + ".cmd")
    exp = os.path.join(CASES, name + ".expected")
    argv = [H6502] + case_args(cmd)
    try:
        p = subprocess.run(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        print("  TIMEOUT %s" % name)
        return False
    got = p.stdout

    if bless:
        with open(exp, "wb") as f:
            f.write(got)
        print("  BLESS %s" % name)
        return True

    if not os.path.exists(exp):
        print("  MISSING %s.expected" % name)
        return False
    with open(exp, "rb") as f:
        want = f.read()
    if got == want:
        print("  PASS  %s" % name)
        return True

    # Compare as bytes and split on b"\n" only: several demos emit a bare CR,
    # and Python's universal-newline translation would hide the difference.
    print("  FAIL  %s" % name)
    gl, wl = got.split(b"\n"), want.split(b"\n")
    shown = 0
    for i in range(max(len(gl), len(wl))):
        g = gl[i] if i < len(gl) else b"<missing>"
        w = wl[i] if i < len(wl) else b"<missing>"
        if g != w:
            if shown >= 8:
                print("        ... and more")
                break
            shown += 1
            print("        line %d" % (i + 1))
            print("        want: %s" % w.decode("utf-8", "replace"))
            print("        got : %s" % g.decode("utf-8", "replace"))
    return False


def main():
    args = sys.argv[1:]
    bless = "--bless" in args
    names = [a for a in args if not a.startswith("-")]

    if not os.path.exists(H6502):
        print("h6502 not built -- run `make h6502`")
        return 1

    ok = True

    # the C-level unit tests first: if the cache model itself is wrong,
    # every end-to-end expectation below is meaningless
    if os.path.exists(CACHETEST):
        print("cache unit tests")
        p = subprocess.run([CACHETEST], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = p.stdout.decode()
        print("  " + out.strip().splitlines()[-1])
        if p.returncode:
            print(out)
            ok = False
    else:
        print("cachetest not built -- run `make h6502-test`")
        ok = False

    if not names:
        names = sorted(f[:-4] for f in os.listdir(CASES) if f.endswith(".cmd"))

    print("memory model cases")
    passed = failed = 0
    for n in names:
        if run_case(n, bless):
            passed += 1
        else:
            failed += 1
            ok = False

    print("---- %d passed, %d failed ----" % (passed, failed))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
