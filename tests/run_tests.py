#!/usr/bin/env python3
"""Test harness for the e6502 BASIC family.

A test case is a pair of files in tests/cases/<tier>/:

    NAME.bas       lines fed to the interpreter on stdin (EOF halts it)
    NAME.expected  the normalized program output to compare against

Usage:
    python3 tests/run_tests.py <tier> [name ...]
    python3 tests/run_tests.py all

    <tier> is one of: nano integer msbasic   (or "all" for every built tier)

The tier's source is assembled fresh before its cases run.  Exit status is
non-zero if any case fails or times out (a timeout means an infinite loop).
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "m6502", "m6502")
ASM = os.path.join(ROOT, "a6502", "asm.py")
LOAD_ADDR = "800"
TIMEOUT = 10  # seconds; generous, but bounds runaway loops

# integer tiers in evolution order; each also passes every lower tier's suite
ORDER = ["nano", "integer", "msbasic"]

# tier name -> version directory under basic/
TIERS = {
    "nano": "1-nano",
    "integer": "2-integer",
    "msbasic": "3-msbasic",
    "float": "4-float",
}

# the float tier changes numeric semantics (10/4 -> 2.5), so it runs only its
# own suite rather than inheriting the integer tiers' expected output.
STANDALONE = {"float"}


def normalize(raw):
    """Reduce raw emulator output to the meaningful program output lines.

    The emulator prints its own load/banner/cycle lines and the BASIC prints a
    "> " prompt (CRLF-terminated) before each interaction.  We drop everything
    up to the first prompt (emulator noise + interpreter banner), then strip the
    "> " prompt marker, blank lines, and the trailing "Done." cycle report.
    """
    text = raw.replace("\r\n", "\n").replace("\r", "\n")
    lines = [ln.rstrip() for ln in text.split("\n")]

    # skip emulator noise + banner: everything before the first prompt line
    start = 0
    for i, ln in enumerate(lines):
        if ln == ">" or ln.startswith("> "):
            start = i
            break
    else:
        start = len(lines)

    out = []
    for ln in lines[start:]:
        if ln.startswith("> "):
            ln = ln[2:]
        elif ln == ">":
            ln = ""
        if ln == "":
            continue
        if ln.startswith("Done.") or ln.startswith("Loaded ") \
                or ln.startswith("m6502 "):
            continue
        out.append(ln)
    return out


def assemble(tier):
    src = os.path.join(ROOT, "basic", TIERS[tier], "basic.asm")
    out = os.path.join(ROOT, "basic", TIERS[tier], "basic.bin")
    if not os.path.exists(src):
        return None  # tier not authored yet
    r = subprocess.run([sys.executable, ASM, src, out],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write("assembler failed for %s:\n%s\n" % (tier, r.stderr))
        sys.exit(2)
    return out


def run_case(binpath, bas_path):
    with open(bas_path) as f:
        program = f.read()
    try:
        r = subprocess.run([EMU, "-r", "-a", LOAD_ADDR, binpath],
                           input=program, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return None  # signals timeout / infinite loop
    return normalize(r.stdout)


def gather_cases(tier):
    """Cases run against `tier`: its own plus every lower tier's (regression).

    Standalone tiers (e.g. float, whose numeric output differs) run only their
    own cases.
    """
    if tier in STANDALONE:
        tiers = [tier]
    else:
        tiers = ORDER[:ORDER.index(tier) + 1]
    cases = []
    for t in tiers:
        d = os.path.join(ROOT, "tests", "cases", t)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".bas"):
                cases.append((t, f[:-4], d))
    return cases


def run_tier(tier, only):
    binpath = assemble(tier)
    if binpath is None:
        print("  (tier '%s' has no source yet - skipped)" % tier)
        return 0, 0
    cases = gather_cases(tier)
    if only:
        cases = [c for c in cases if c[1] in only]
    passed = failed = 0
    for origin, name, casedir in cases:
        label = name if origin == tier else "%s:%s" % (origin, name)
        bas = os.path.join(casedir, name + ".bas")
        exp_path = os.path.join(casedir, name + ".expected")
        with open(exp_path) as f:
            expected = [ln.rstrip() for ln in f.read().split("\n")]
        while expected and expected[-1] == "":
            expected.pop()
        actual = run_case(binpath, bas)
        if actual is None:
            print("  FAIL %-24s (timeout - possible infinite loop)" % label)
            failed += 1
            continue
        if actual == expected:
            print("  PASS %s" % label)
            passed += 1
        else:
            print("  FAIL %s" % label)
            print("    expected: %r" % expected)
            print("    actual:   %r" % actual)
            failed += 1
    return passed, failed


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__)
        sys.exit(2)
    tier = args[0]
    only = set(args[1:])
    if not os.path.exists(EMU):
        sys.stderr.write("emulator not built: %s  (run `make`)\n" % EMU)
        sys.exit(2)

    tiers = list(TIERS) if tier == "all" else [tier]
    for t in tiers:
        if t not in TIERS:
            sys.stderr.write("unknown tier: %s\n" % t)
            sys.exit(2)

    total_p = total_f = 0
    for t in tiers:
        print("== %s ==" % t)
        p, f = run_tier(t, only)
        total_p += p
        total_f += f
    print("---- %d passed, %d failed ----" % (total_p, total_f))
    sys.exit(1 if total_f else 0)


if __name__ == "__main__":
    main()
