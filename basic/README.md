
## The BASIC version family

The interpreter grows in tiers that echo the Apple II's own evolution - from a
minimal integer seed, to a Woz-style *Integer BASIC*, to an Applesoft-style
*Microsoft BASIC*.  Each tier is a self-contained `basic.asm` + `basic.bin`
that runs on the same `m6502` emulator, so you can diff two versions to see
exactly what a feature costs in 6502 assembly.

| Tier | Directory     | Build       | Status | What it adds                          |
|------|---------------|-------------|--------|---------------------------------------|
| 1    | `1-nano/`     | `make basic1` | ready | The seed: LET/PRINT/INPUT/IF/GOTO/REM/END, LIST/RUN/NEW, 16-bit integer expressions, 26 scalar variables A-Z |
| 2    | `2-integer/`  | `make basic2` | ready | `FOR`/`NEXT`, `GOSUB`/`RETURN`, `AND`/`OR`/`NOT` + `IF...THEN <statement>`, multi-statement lines (`:`), integer arrays `DIM A(n)` |
| 3    | `3-msbasic/`  | `make basic3` | ready | String variables `A$` (≤63 chars) + string functions (`LEN`/`ASC`/`VAL`/`CHR$`/`STR$`/`LEFT$`/`RIGHT$`/`MID$`), numeric functions (`ABS`/`SGN`/`RND`), `DATA`/`READ`/`RESTORE`, `ON...GOTO/GOSUB`, `;` in `PRINT` |
| 4    | `4-float/`    | `make basic4` | Done | *Decimal* floating point (`value = sign·M·10^E`, 7-digit mantissa). Everything is float-wired: literals (`3.14`/`1E3`/`.5`), `+ - * /`, scalar vars, arrays (5-byte packed float elements), `PRINT`, comparisons, `IF`, `GOTO`/`GOSUB`, `ON..GOTO`, `FOR`/`NEXT` (float limit/step), `INPUT`, `READ`/`DATA`/`RESTORE`, `LEN`/`ASC`/`VAL`/`ABS`/`SGN`/`RND`, `STR$`, and `AND`/`OR`/`NOT` (integer-bitwise). Transcendentals (`SIN`/`COS`/..) deferred. |

Tier 4 uses *decimal* float rather than binary, so `0.1 + 0.2` prints `0.3`
exactly and there are no binary-rounding surprises. It runs its own test suite
(`make test` covers it via `run_tests.py float`); because its numeric output
differs (`10/4` → `2.5`), it does not inherit the integer tiers' suites.

**Tier-3 notes / limits (teaching simplifications):** strings cap at 63 chars; string-function string arguments are a single variable or literal (e.g. `LEFT$(A$,3)`, not `LEFT$(A$+B$,3)`); `DATA`/`READ` hold numbers; `RND` is a small integer LCG (deterministic seed). These keep the source readable rather than aiming for Applesoft byte-compatibility.

All arithmetic is **16-bit signed integer** throughout - even tier 3 keeps
integer math (no floating point), so it is "Microsoft BASIC in feature shape",
not a bit-exact Applesoft.  Comparisons yield `-1` for true, `0` for false.

**Array bounds checking (tiers 2-4):** an array subscript outside its
dimensioned range - or a negative index - raises `?BAD SUBSCRIPT` instead of
reading/writing arbitrary memory.  Errors reset the CPU stack and return
cleanly to the prompt, so an error deep inside an expression can no longer
print a garbage value on its way back up.


### Code size

Each `basic.bin` is a full 62 KB image (`$0800-$FFFF`) because it is padded with
zeros up to the `$FFFA` reset/IRQ vectors, but the actual interpreter - machine
code plus its string tables, assembled from `$0800` upward - is far smaller:

| Tier | Directory     | Code + data | Top address |
|------|---------------|-------------|-------------|
| 1    | `1-nano/`     | ~2.9 KB     | `$1370`     |
| 2    | `2-integer/`  | ~4.2 KB     | `$18D3`     |
| 3    | `3-msbasic/`  | ~6.3 KB     | `$212C`     |
| 4    | `4-float/`    | ~7.8 KB     | `$271A`     |

(Runtime storage - program text at `$0300-$07FF`, variables, string vars, the
FOR/GOSUB stacks, and the array heap - lives in separate RAM regions above the
code and is not counted here.)  For comparison, Woz's Apple Integer BASIC was
~5-6 KB; tier 4 adds full decimal floating point for well under 8 KB.


### REPL / input notes (all tiers)

- **Case-insensitive** keywords and variables: input is folded to upper-case as
  it is read, **except inside `"..."` string literals**, whose case is preserved.
  So `print a$` works, and `A$ = "Hello"` keeps `Hello`.
- The program area is `$0300-$07FF` (~1.25 KB). A line that would grow the
  program into the interpreter code, or a single line longer than the record
  format allows, is rejected with `?PROGRAM TOO BIG` (the interpreter keeps
  running). Input lines are capped at 255 characters.
- Arithmetic is signed 16-bit: `*` and `/` handle negative operands
  (`-10/2 = -5`, truncating toward zero); `+ - *` wrap modulo 65536.
- Expression parenthesis nesting is bounded (~8 deep). Pathologically deep
  nesting yields `0` for the over-deep part rather than overflowing the CPU or
  value stack - so the interpreter can't be hung by input like `(((((...)))))`.
- **Ctrl-C breaks a running program**: it stops with `BREAK IN <line>` and
  returns to the `>` prompt (the emulator delivers Ctrl-C via the `$F004`
  port; see the top-level README). So deliberate infinite loops (`GOTO` to
  self, `FOR ... STEP 0`) are interruptible on an interactive terminal.
- No array bounds checking (an out-of-range index reads/writes other RAM but
  never crashes the emulator); over-`GOSUB`/`FOR` nesting is capped and errors.

### Running

```bash
make basic1        # assemble + launch Nano BASIC
make basic2        # Integer BASIC
make basic3        # MS-style BASIC
make run           # newest built tier
```

### Tests

Every tier has a suite under `../tests/cases/<tier>/`.  Run them with:

```bash
make test                         # nano suite
python3 ../tests/run_tests.py integer
python3 ../tests/run_tests.py all
```

A case is a `NAME.bas` (fed to the interpreter on stdin) paired with a
`NAME.expected` (its normalized output).  A lower tier's suite is expected to
keep passing on the tiers above it.
