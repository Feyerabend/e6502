# h6502 — a memory hierarchy you can see

Companion to the `m6502` emulator. Same CPU core, same instruction semantics,
same binaries. The only thing that changes is **the memory behind the bus** —
and that turns out to change quite a lot.

```bash
make h6502          # build
make smc            # the headline demo: one program, three architectures
make test-mem       # 69 cache unit checks + 27 end-to-end model cases
```

---

## 1. The question

A processor is not much use without memory, and the relationship between the
two is not one design but a choice. Two questions decide almost everything:

1. **Are instructions and data in the same memory?**
2. **Do they travel on the same bus?**

Answer *yes/yes* and you have a von Neumann machine. Answer *no/no* and you
have a Harvard machine. Answer *yes/no* — one memory, separate paths near the
core — and you have what nearly every processor built since about 1990
actually is.

The 6502 is the first case in its purest form, which is exactly why it makes a
good place to build the other two.

---

## 2. Von Neumann: one memory, one bus

```
            +-----+
            | CPU |
            +--+--+
               |            one address bus, one data bus
        =======+=======
               |
        +------+------+
        |   memory    |     instructions AND data, indistinguishable
        +-------------+
```

The 6502 has a 16-bit address bus, an 8-bit data bus, and 64 KB of undivided
address space. `$0800` might hold an opcode, a character in a string, or a
BASIC variable. Nothing in the hardware knows or cares. `LDA $0800` and an
instruction fetch from `$0800` are the same electrical event.

Three consequences follow, and all three are visible in this simulator.

**A program can read and write itself.** Self-modifying code is not a hack on
this machine, it is just addressing. Every 6502 programmer used it: patching
an operand was cheaper than an indirection, and in 1979 cycles were the scarce
resource. `demos/smc.asm` does exactly this.

**The bus is a bottleneck.** Every cycle the bus carries either an instruction
byte or a data byte, never both. Run any demo and look at the census:

```
bus accesses 143766   instruction side 113005 (78.6%)   data side 30761 (21.4%)
  by kind: OPCODE=61642  OPERAND=51363  DATA=30761  PTR=0  STACK=0  VECTOR=0
```

Roughly four out of five bus cycles are spent fetching the program, not
operating on data. That ratio is the von Neumann bottleneck as a number. If
you could fetch instructions on a separate wire, you would get most of that
bandwidth back for free.

**There is nothing to keep coherent.** One memory holds one value per address.
The question "does the fetch side agree with the load side?" cannot even be
asked.

---

## 3. Harvard: two memories, two buses

```
        +-------------+        +-----+        +-------------+
        | instruction |========| CPU |========|    data     |
        |   memory    |        +-----+        |   memory    |
        +-------------+                       +-------------+
             fetch bus                          load/store bus
```

Named after the Harvard Mark I (1944), which read its program from punched
paper tape and kept its numbers in counter wheels — not a design decision so
much as a description of the hardware available.

Both buses can be active in the same cycle, so a fetch and a load overlap
instead of queueing. That doubles the effective memory bandwidth without
making the memory any faster, which is why the architecture never went away:
it lives on in microcontrollers (AVR, PIC, 8051) and DSPs, where determinism
and bandwidth matter more than flexibility.

You pay for it in three places.

**You cannot write your instruction memory.** There is no store instruction
that reaches it. Self-modifying code is not slow or discouraged; it is
*unexpressible*. So is a JIT compiler, and so is loading a program at all —
which is why Harvard microcontrollers need a bootloader living in a special
memory region with a special instruction (`SPM` on AVR) that nothing else may
use.

**You cannot read your own constants.** A string literal sits in the program
image, in instruction memory, and `LDA message,X` reaches into *data* memory
and finds whatever happens to be there. Real Harvard ISAs bolt on an escape
hatch: AVR's `LPM` (load program memory), PIC's `RETLW` (return literal in W).
Every one of them is an admission that the split is too strict to live with.

**Your toolchain gets more complicated.** Initialised data must exist twice —
once in ROM as part of the image, once in RAM where the program can reach it —
and startup code copies it across. `load` mirrors the binary into both spaces
by default for exactly this reason; `load prog.bin 0800 i` loads only the
instruction side, and you can watch a program starve.

---

## 4. Modified Harvard: the machine on your desk

```
        +------+   +------+
        |  I$  |   |  D$  |     split L1: two ports, two caches
        +--+---+   +---+--+
           |           |
           +-----+-----+
                 |                unified below this line
        +--------+--------+
        |   main memory   |       one address space, one set of bytes
        +-----------------+
```

x86, ARM, RISC-V, POWER: all of them present a single flat address space to
the programmer, and all of them split the L1 cache into an instruction cache
and a data cache. You get Harvard's dual-port bandwidth exactly where the
bandwidth is needed — at the top of the hierarchy, closest to the core — and
you keep von Neumann's single address space everywhere the programmer looks.

It is the right answer, and it comes with a bill: **the two caches can
disagree.** Store a byte and it lands in D$. The instruction cache may be
holding that same line, and it does not notice. The CPU carries on executing
bytes that are no longer in memory. Nothing faults. Nothing warns you.

That is not a bug in the design. It is the design, and every ISA that made
this choice had to add instructions to cope with it.

---

## 5. The case: one program, three architectures

`demos/smc.asm` patches the operand of its own `LDA` five times and prints the
result. It is twenty-seven bytes and does nothing clever.

```asm
next:
        TXA
        CLC
        ADC #65         ; 'A' + X
        STA patch+1     ; <<< write into our own instruction stream
patch:
        LDA #65         ; the operand byte just overwritten
        STA IO_OUT
```

```bash
$ make smc
--- von Neumann: one memory, one cache ---
ABCDE
--- modified Harvard: one memory, split L1 ---
  [coherence] store to $080A is now stale in I$ (line $0800) -- the fetch side will not see it
A  [coherence] store to $080A is now stale in I$ (line $0800) -- the fetch side will not see it
A  [coherence] store to $080A is now stale in I$ (line $0800) -- the fetch side will not see it
A  ... (five in all, one per iteration)
--- Harvard: two memories, split L1 ---
stale-line warnings off
AAAAA
```

(The warnings interleave with the program's own output, which is why `warn off`
exists. The middle run prints `AAAAA`, one `A` per warning.)

Same bytes. Same CPU. Three answers.

**`ABCDE`** — von Neumann. The store went into the unified cache; the fetch
came out of the same line. There is one copy of the byte, so it is correct by
construction.

**`AAAAA` with a warning** — modified Harvard. The store went into D$. I$ was
holding `$0800`–`$080F` because the program is executing out of it, and I$ was
not told. This is a *cache* failure: the byte reached memory's address space,
just not the copy the fetch side was reading. It is repairable in software.

**`AAAAA` with no warning** — true Harvard. There is no coherence problem
because there is no shared thing to be incoherent about. The store went to
data memory, address `$080A`, and instruction memory address `$080A` is a
different physical byte that was never touched. You can see them diverge:

```bash
$ h6502/h6502 -m harvard -a 800 h6502/demos/smc.bin \
    -x "warn off; g 800; clean; mi 0800 080F; m 0800 080F; q"
AAAAA
dirty data lines written back
$0800  A2 00 8A 18 69 41 8D 0A 08 A9 41 8D 01 F0 E8 E0  ....iA....A.....
$0800  A2 00 8A 18 69 41 8D 0A 08 A9 45 8D 01 F0 E8 E0  ....iA....E.....
```

The first dump is instruction space, the second is data space. Byte `$080A` is
`$41` `'A'` in one and `$45` `'E'` in the other, and both are correct: they are
two different bytes that merely share a number.

This is an *architecture* failure, and it is not repairable. No cache
instruction can build a bus that does not exist.

### Repairing the middle case

The obvious fix is to throw away the stale instruction line. `demos/smc_icbi.asm`
does that and **still prints `AAAAA`**:

```bash
$ make smc-fix
--- invalidate I$ only: still wrong, the store is dirty in D$ ---
AAAAA
--- clean D$, then invalidate I$ ---
ABCDE
```

Invalidating I$ forces a refill *from main memory* — and with a write-back
data cache, main memory has not received the store yet. The patched byte is
sitting dirty in D$. The refill dutifully fetches the old byte back.

So the sequence is two operations, in this order:

1. **clean** the data cache — push the store down to where both caches can see it
2. **invalidate** the instruction cache — force it to go back and look

Which is precisely ARM's `DC CVAU` / `IC IVAU`, PowerPC's `dcbst` / `icbi`,
and the reason RISC-V's `FENCE.I` is specified the way it is. Every JIT
compiler, every debugger planting a breakpoint, every trampoline generator on
every modern machine performs some version of this dance. Get the order wrong
and you get a bug that reproduces once a week on one machine.

Two other ways to make the same binary work, both worth trying:

```
config d write=wt    write-through D$: stores reach memory at once, so there is
                     nothing to clean and the I$ invalidate alone is enough
snoop on             hardware coherence: the D-side write invalidates the
                     matching I$ line itself -- and the statistics show what
                     that costs, five invalidations in a twenty-seven-byte program
```

### A smaller lesson hiding in the same demo

```bash
$ h6502/h6502 -m mod -a 800 h6502/demos/smc.bin \
    -x "warn off; g 800; m 0800 080F; clean; m 0800 080F; q"
AAAAA
$0800  A2 00 8A 18 69 41 8D 0A 08 A9 41 8D 01 F0 E8 E0  ....iA....A.....
dirty data lines written back
$0800  A2 00 8A 18 69 41 8D 0A 08 A9 45 8D 01 F0 E8 E0  ....iA....E.....
```

Same command, one `clean` apart.

A write-back cache means **a memory dump can lie to you.** The store happened;
it just has not reached the place the debugger is reading. This is why JTAG
probes have a cache-flush button, and why `volatile` is not a synchronisation
primitive.

---

## 6. The cache, in one page

Both Harvard modes give each side its own L1. The model is configurable in
every dimension a textbook varies.

An address is split three ways:

```
     15                                    0
    +--------------------+-------+---------+
    |         tag        | index |  offset |
    +--------------------+-------+---------+
              9              3        4        (256 B, 16 B lines, 2-way)

    offset  which byte within the line
    index   which set to look in
    tag     stored with the line, to prove it is the one you wanted
```

`map` shows the decomposition for any address, and tells you what collides
with it:

```
h> map 0800
address $0800 = %0000100000000000
  I$  tag $010 | set 0 | offset 0    -> RESIDENT in way 0
      addresses that collide with it: $0000, $0080, $0100, ... (every 128 bytes)
  D$  tag $010 | set 0 | offset 0    -> not resident
      addresses that collide with it: $0000, $0080, $0100, ... (every 128 bytes)
```

The program is executing out of `$0800`, so the line is resident on the fetch
side and absent on the load side. That asymmetry *is* the Harvard split, shown
one address at a time.

| knob | command | what it trades |
|------|---------|----------------|
| capacity | `config d size=1024` | area and power against capacity misses |
| line size | `config d line=32` | fewer misses against wasted bandwidth |
| associativity | `config d ways=4` | lookup cost against conflict misses |
| replacement | `config d repl=lru\|fifo\|rand` | prediction quality against tracking state |
| write policy | `config d write=wb\|wt` | memory traffic against staleness |
| write allocate | `config d alloc=0\|1` | useful for write-once data |
| miss penalty | `config d penalty=20` | models a slower memory |

`stats`, `cd`, `sets d` and `trace` are how you watch it work:

```
h> trace 12
h> s 3
$0800: A2 00     LDX  #$00
  read  OPCODE  $0800 = $A2  I$ set  0 way 0 tag $010  MISS +8c
  read  OPERAND $0801 = $00  I$ set  0 way 0 tag $010  HIT
  -> A=$00 X=$00 Y=$00 SP=$FD
$0802: 8A        TXA
  read  OPCODE  $0802 = $8A  I$ set  0 way 0 tag $010  HIT
  -> A=$00 X=$00 Y=$00 SP=$FD
$0803: 9D 00 20  STA  $2000,X
  read  OPCODE  $0803 = $9D  I$ set  0 way 0 tag $010  HIT
  read  OPERAND $0804 = $00  I$ set  0 way 0 tag $010  HIT
  read  OPERAND $0805 = $20  I$ set  0 way 0 tag $010  HIT
  write DATA    $2000 = $00  D$ set  0 way 0 tag $040  MISS +8c
  -> A=$00 X=$00 Y=$00 SP=$FD
```

Three instructions, seven bus accesses, two misses. Four of the seven are the
instruction stream — the bottleneck of section 2, close enough to touch.

---

## 7. Four experiments with numbers

### Instruction locality is nearly free

`make h6502 && h6502/h6502 -m mod -a 800 h6502/demos/loop.bin -x "g 800; stats; q"`

```
I$    113005 acc    113003 hit         2 miss
```

Two misses in 113,000 fetches. A loop body of a dozen bytes is fetched once
and then lives in the cache forever. This is why instruction caches are
usually the easy half of the problem, and why the *data* side is where
performance work happens.

### Spatial locality: `make stride`

256 loads, always 256, only the walk order changes:

```
stride $01:   16 miss   hit rate  99.38%
stride $04:   64 miss   hit rate  97.50%
stride $10:  256 miss   hit rate  90.01%
```

At stride 16 — the line size — every load lands on a fresh line and the cache
stops helping entirely. The machine is fetching sixteen bytes to use one.
This is the array-of-structs versus struct-of-arrays result, sixteen times
over, on a machine from 1975.

### Associativity: `make assoc`

Three arrays 256 bytes apart, walked in lockstep. Capacity is pinned at 256
bytes for all three runs:

```
1-way:  0.00% hit
2-way:  0.00% hit
4-way: 99.61% hit
```

The cache never got bigger. It got permission to keep more than N lines that
happen to share an index. This is the pathology behind "my program got 10×
slower when I padded that struct to a power of two" — power-of-two strides are
exactly the ones that pile onto a single set.

### Line size: `make lines`

Same 256 loads at stride 4, fixed 256-byte capacity, direct-mapped:

```
    line       2     4     8    16    32    64   128
    misses   261   260   140    92    92   140   260
    bytes    522  1040  1120  1472  2944  8960 33280
```

A U. Longer lines buy spatial locality until the fixed capacity means *fewer*
lines and the walk starts evicting itself — while the bandwidth cost climbs
without pause. At line=128 the machine hauls 33 KB out of memory to read the
256 bytes it wanted.

This is the classic miss-rate-versus-block-size curve, and it is why real L1
line sizes sit around 32–64 bytes instead of growing forever.

---

## 8. Exercises

1. Run `loop.bin` with `cache off` (174,529 cycles) and then with the caches on
   (174,529 + 664 stall = 175,193). Why did adding a cache make it *slower*?
   What does the answer tell you about when a cache is worth having at all?
   (Hint: what is the miss penalty *relative to* a 6502's memory?)
2. `thrash.asm` places its arrays 256 bytes apart. Move `A3` to `$2210` and
   rebuild. Which geometries recover, and why?
3. Set `config d repl=fifo` and rerun `make assoc`. Find a program where FIFO
   beats LRU. (They exist. LRU is not optimal — it is just usually good.)
4. Nano BASIC is a real program with real locality:
   `h6502/h6502 -m mod -a 800 basic/1-nano/basic.bin -r`. What is the I$ hit
   rate of an interpreter's dispatch loop, and how does it change between
   tiers 1 and 3?
5. In Harvard mode, load a program into I-space only (`load prog.bin 0800 i`)
   and run it. Which instruction fails first? Now write the startup code that
   would fix it.
6. The device page is uncacheable. Delete that check from `memsys.c`, rebuild,
   and run any demo that reads input. Explain the failure in terms of line
   fills.
7. Add an L2: a second, larger, slower unified cache behind both L1s. Where in
   `memsys.c` does it go, and what happens to the coherence story?

---

## 9. What this model is, and what it is not

**The anachronism is deliberate.** No 6502 ever shipped with a cache, and the
chip's timing assumes single-cycle memory throughout. Bolting an L1 onto it is
historically false. It is also the right teaching move: the 6502 is small
enough to hold entirely in your head, so when the hit rate changes you can
account for every access that caused it. On a machine with a pipeline, a
prefetcher, three cache levels and speculative execution, you cannot.

**Faithful:** address decomposition, hit/miss classification, LRU and FIFO
victim selection, write-back and write-through, write-allocate, dirty
write-back on eviction, clean/invalidate semantics and their ordering,
snoop-based invalidation, uncacheable device memory, and the split of the
access stream into instruction and data sides.

**Not modelled:** pipelining, prefetch, write buffers, victim caches,
non-blocking misses, bank conflicts, TLBs and virtual memory, multi-level
hierarchies, multi-core coherence protocols (MESI and friends), and any
relationship between the miss penalty and a real memory's timing — it is a
flat configurable number, not a DRAM model. Stall cycles are reported
separately from CPU cycles rather than being interleaved into instruction
timing, so `cycles` still matches what `m6502` reports for the same program.

**How the split is possible at all.** A real 6502 bus cannot distinguish an
opcode fetch from a data load — that is what makes it von Neumann, and it is
the whole difficulty. The CPU core in `m6502.c` therefore publishes the
*reason* for each access in `cpu->access` (`OPCODE`, `OPERAND`, `DATA`, `PTR`,
`STACK`, `VECTOR`) immediately before each bus callback. Nothing in the core
reads it back; it changes no behaviour, and `m6502` ignores it entirely. It
exists so that `memsys.c` can route the two sides to different places. You can
audit the tagging directly:

```bash
$ python3 tests/run_mem_tests.py access_kinds
by kind: OPCODE=6  OPERAND=9  DATA=3  PTR=0  STACK=4  VECTOR=0
```

for a hand-assembled six-instruction program whose expected census is worked
out by hand in `tests/cases/memsys/access_kinds.cmd`.

---

## 10. Command reference

```
CPU / memory
  s [n]                step n instructions          r    registers + cycles
  c | run              run until halt or breakpoint  g <addr>   set PC and run
  d [addr] [n]         disassemble from I-space
  m  [lo] [hi]         dump data space          mi [lo] [hi]  dump instruction space
  e  <addr> <b>...     write data space         ei <addr> <b>...  write instruction space
  load <f> [addr] [i|d|both]                    b [addr] / bc <addr>   breakpoints
  reset                reset CPU (reads $FFFC from I-space)

Memory model
  mode [vn|harvard|mod]        pick the architecture
  cache [on|off]               bypass the caches entirely
  config <i|d|u|all> k=v ...   size= line= ways= repl= write= alloc= penalty=
  snoop [on|off]               modified Harvard: D-writes invalidate I$
  warn  [on|off]               narrate stale-line coherence violations
  clean                        write back dirty data lines, keep them resident
  flush [i|d|all]              write back and invalidate

Observation
  stats                cache and bus statistics    zero   clear statistics
  ci | cd | cu [set]   dump cache contents         sets <i|d|u>   occupancy map
  map <addr>           tag/index/offset, and what collides with it
  trace [on|off|N]     print every bus access
```

Numbers are hex by default; `$` or `0x` also hex, `#` decimal.

Device page (uncacheable in every model):

| address | dir | function |
|---------|-----|----------|
| `$F001` | w | character out |
| `$F002` | r | `$FF` if input waiting |
| `$F003` | r | next input character |
| `$F004` | r | `$FF` if Ctrl-C pending (read clears) |
| `$F0FC` | w | clean the data cache (`DC CVAU`) |
| `$F0FD` | w | invalidate the instruction cache (`IC IVAU`) |
| `$F0FE` | w | reset statistics — mark the start of a region of interest |
| `$F0FF` | w | halt |
