
## e6502 - MOS 6502 Emulator, Assembler, and Nano BASIC

Companion code for *The Language Stack: From Silicon to Semantics*, Chapter 1.
Three tools built together to trace the path from raw machine cycles to an
interactive programming language:

| Component  | Directory | What it is                              |
|------------|-----------|-----------------------------------------|
| `m6502`    | `m6502/`  | C99 6502 emulator with monitor/debugger |
| `a6502`    | `a6502/`  | Two-pass Python assembler               |
| Nano BASIC | `basic/`  | Tiny BASIC interpreter in 6502 assembly |
| `h6502`    | `h6502/`  | Memory-hierarchy model: von Neumann / Harvard / modified Harvard, with a configurable L1 cache |



### Quick start

```bash
make          # build the emulators, assemble the demos
make run      # assemble Nano BASIC and launch it
make smc      # one self-modifying program, three memory architectures
make test-all # BASIC suite + memory-model suite
```



### The MOS 6502

The MOS Technology 6502, introduced in 1975, powered the Apple II, Atari 2600,
Commodore 64, BBC Micro, and NES.  Its simplicity made it the canonical teaching
chip: eight addressing modes, three general-purpose registers (A, X, Y), a
hardware stack on page $01, and a 16-bit address bus giving 64 KB of flat memory.

#### Registers

| Register | Width  | Role                                 |
|----------|--------|--------------------------------------|
| A        | 8-bit  | Accumulator - arithmetic and logic   |
| X        | 8-bit  | Index / counter                      |
| Y        | 8-bit  | Index / counter                      |
| SP       | 8-bit  | Stack pointer (page $01, descending) |
| PC       | 16-bit | Program counter                      |
| P        | 8-bit  | Status flags: N V - B D I Z C        |

#### Status flags (P)

| Bit | Flag | Meaning                                 |
|-----|------|-----------------------------------------|
| 7   | N    | Negative - set when result bit 7 = 1    |
| 6   | V    | Overflow - set on signed overflow       |
| 4   | B    | Break - set by BRK instruction          |
| 3   | D    | Decimal - BCD arithmetic (not emulated) |
| 2   | I    | Interrupt disable                       |
| 1   | Z    | Zero - set when result = 0              |
| 0   | C    | Carry / borrow                          |



### m6502 emulator

The emulator is a single-file C99 core (`m6502.c` / `m6502.h`) driven by a
monitor shell (`main.c`).  The entire 64 KB address space is RAM except for a
few memory-mapped I/O ports:

| Address | Direction | Function                                         |
|---------|-----------|--------------------------------------------------|
| `$F001` | write     | character output (stdout)                        |
| `$F002` | read      | `$FF` if a character is waiting, `$00` otherwise |
| `$F003` | read      | next character from stdin                        |
| `$F004` | read      | `$FF` if Ctrl-C / BREAK is pending (read clears) |

On an interactive terminal the emulator switches stdin to char-at-a-time mode
and turns **Ctrl-C** into a BREAK signal (via `$F004`) instead of killing the
process, so a running BASIC program stops with `BREAK IN <line>`.  Piped input
(scripts, the test harness) is left untouched.

Interrupt vectors live at the standard 6502 locations:

| Address | Vector |
|---------|--------|
| `$FFFA` | NMI    |
| `$FFFC` | RESET  |
| `$FFFE` | IRQ    |

#### Building

```bash
make          # produces m6502/m6502
```

#### Command-line usage

```bash
m6502/m6502 [options] [file]

  -r            run immediately (skip initial monitor prompt)
  -a <hex>      load file at address (default $0800)
  file          binary to load
```

Examples:

```bash
m6502/m6502                          # open monitor, no binary loaded
m6502/m6502 prog.bin                 # load prog.bin at $0800, enter monitor
m6502/m6502 -r -a 800 prog.bin       # load and run immediately
```

#### Monitor commands

All numeric arguments are hexadecimal unless noted.

```bash
s [n]               step n instructions (default 1)
c / g [addr]        continue; g sets PC first
d [addr] [n]        disassemble (default: PC, 10 lines)
r                   show registers
set <reg> <val>     set register: pc sp a x y p
m [start] [end]     memory dump (default $0000..$00FF)
e <addr> <b>...     enter bytes at address
f <s> <e> <v>       fill s..e with byte v
a [addr]            interactive mini-assembler at addr
b [addr]            set / list breakpoints
bc <addr>           clear breakpoint
w <addr> [r|w|rw]   set watchpoint (default rw)
wc <addr>           clear watchpoint
k                   stack dump
hist                instruction history (last 16)
t                   toggle per-instruction trace
irq                 inject IRQ
nmi                 inject NMI
reset               reset CPU (reads $FFFC vector)
load <file> [addr]  load binary (default $0800)
q                   quit
h / ?               this help
```

Markers in disassembly: `>` current PC, `*` breakpoint.



### a6502 assembler

A two-pass assembler written in Python 3, with no dependencies beyond the
standard library.

```bash
python3 a6502/asm.py <source.asm> [output.bin] [-v]
```

Supports all 56 standard 6502 mnemonics, all addressing modes, labels,
constants (`NAME = expr`), and directives `.org`, `.byte`, `.word`, `.asc`,
`.fill`.  Numbers may be decimal, `$hex`, `0xhex`, or `%binary`.  Full
reference: [`a6502/ASM.md`](a6502/ASM.md).



### Nano BASIC

A minimal BASIC interpreter written entirely in 6502 assembly, assembled to a
63 KB binary that loads at `$0800`.

#### Running

```bash
make run                                  # assemble + launch (recommended)

# or manually:
python3 a6502/asm.py basic/1-nano/basic.asm basic/1-nano/basic.bin
m6502/m6502 -r -a 800 basic/1-nano/basic.bin
```

You reach a `>` prompt.  Type lines of BASIC, or immediate commands.

#### Language reference

Lines are numbered integers.  Store a line by typing its number first;
omit the number for immediate execution.

```basic
10 PRINT "HELLO, WORLD!"
20 GOTO 10
RUN
```

##### Statements

| Statement | Syntax                    | Effect                               |
|-----------|---------------------------|--------------------------------------|
| `LET`     | `LET A = expr`            | Assign variable (A-Z, 16-bit signed) |
| `PRINT`   | `PRINT expr, "str", ...`  | Print values or string literals      |
| `INPUT`   | `INPUT "prompt", A`       | Print prompt, read integer into A    |
| `IF`      | `IF expr THEN lineno`     | Branch if expr ≠ 0                   |
| `GOTO`    | `GOTO lineno`             | Unconditional jump                   |
| `REM`     | `REM anything`            | Comment (ignored)                    |
| `END`     | `END`                     | Stop program, return to prompt       |
| `LIST`    | `LIST`                    | List the stored program              |
| `RUN`     | `RUN`                     | Execute the stored program           |
| `NEW`     | `NEW`                     | Clear program memory                 |
| `MON`     | `MON`                     | Drop into the 6502 monitor           |
| `HELP`    | `HELP`                    | Print this reference                 |

##### Expressions

Standard arithmetic with correct precedence:

```basic
A = 6 + 4 * 3       ; -> 18
B = (6 + 4) * 3     ; -> 30
C = 100 / 7         ; -> 14  (integer division)
D = -A + B
```

- Operators: `+` `-` `*` `/`
- Comparisons (return -1 for true, 0 for false): `=` `<>` `<` `>` `<=` `>=`
- Variables: single letters A-Z, 16-bit signed integers

##### Example programs

*Fibonacci sequence*
```basic
10 LET A = 0
20 LET B = 1
30 PRINT A
40 LET C = A + B
50 LET A = B
60 LET B = C
70 IF B < 1000 THEN 30
80 END
```

*Factorial*
```basic
10 INPUT "N? ", N
20 LET F = 1
30 IF N < 2 THEN 60
40 LET F = F * N
50 LET N = N - 1
60 GOTO 30
70 PRINT F
```

*Countdown*
```basic
10 LET N = 10
20 PRINT N
30 LET N = N - 1
40 IF N > 0 THEN 20
50 PRINT "DONE"
```

##### Using the monitor from BASIC

Type `MON` at any point - from the prompt or inside a running program via a
numbered line - to drop into the 6502 monitor.  Inspect memory, set
breakpoints, examine registers.  Type `c` (continue) to return to the BASIC
`>` prompt.



### Memory map

```
$0000 - $00FF   zero page  (BASIC variables, interpreter state)
$0100 - $01FF   6502 hardware stack
$0200 - $07FF   free RAM
$0800 - $EFFF   Nano BASIC binary (~63 KB, program + interpreter)
$F001           I/O: character output
$F002           I/O: input status
$F003           I/O: input data
$F004           I/O: BREAK pending (read clears)
$F0FC           h6502 only: clean the data cache (write back dirty lines)
$F0FD           h6502 only: invalidate the instruction cache
$F0FE           h6502 only: reset cache statistics
$F0FF           h6502 only: halt
$FFFA - $FFFF   vectors: NMI / RESET / IRQ
```

The `$F0FC`-`$F0FF` ports exist only in `h6502`; in `m6502` those addresses are
ordinary RAM, so a binary that uses them still runs (the stores simply have no
effect).



### Project layout

```
e6502/
|-- Makefile
|-- m6502/
|   |-- m6502.h          6502 CPU header (public API)
|   |-- m6502.c          CPU core: all opcodes, addressing modes, disassembler
|   +-- main.c           monitor, I/O, loader, run loop
|-- a6502/
|   |-- asm.py           two-pass assembler
|   +-- ASM.md           assembler reference
|-- basic/
|   |-- README.md        the BASIC version family (what each tier adds)
|   |-- 1-nano/          Nano BASIC        (basic.asm / basic.bin)
|   |-- 2-integer/       Integer BASIC     (basic.asm / basic.bin)
|   +-- 3-msbasic/       MS-style BASIC    (basic.asm / basic.bin)
|-- h6502/
|   |-- HARVARD.md       memory architectures explained, with measurements
|   |-- cache.h/.c       configurable L1: geometry, replacement, write policy
|   |-- memsys.h/.c      the three architectures, routing, coherence
|   |-- hmon.c           monitor: run, trace, configure, measure
|   |-- cachetest.c      unit tests for the cache itself
|   +-- demos/           small .asm programs, each isolating one effect
+-- tests/
    |-- run_tests.py     BASIC harness (per-tier .bas -> .expected)
    |-- run_mem_tests.py memory-model harness (.cmd -> .expected)
    +-- cases/           test cases, grouped by tier (plus memsys/)
```

The BASIC interpreter comes as a **family of versions** that mirrors the Apple
II evolution - from a minimal seed up through richer dialects.  Build and run a
specific tier with `make basic1` / `basic2` / `basic3`; `make run` launches the
newest built tier.  Run the tests with `make test` (or
`python3 tests/run_tests.py <tier>`).  See [`basic/README.md`](basic/README.md).

The **`h6502`** monitor runs the same binaries on the same CPU core, but puts a
memory hierarchy behind the bus: a von Neumann machine, a true Harvard machine
with separate instruction and data memories, or a modified Harvard machine with
a split L1 cache over unified memory - the arrangement every processor built
since about 1990 actually uses.  Cache geometry, replacement policy, write
policy and miss penalty are all configurable from the monitor, and every access
can be traced.  `make test-mem` runs 69 cache unit checks and 27 end-to-end
model cases.  See [`h6502/HARVARD.md`](h6502/HARVARD.md), which explains the
three architectures and works through the measurements.

