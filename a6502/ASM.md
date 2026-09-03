# a6502 — MOS 6502 Assembler

Two-pass assembler for the MOS 6502.  Written in Python 3, no dependencies
beyond the standard library.

---

## Usage

```
python3 asm.py <source.asm> [output.bin] [-v]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `source.asm` | — | Assembly source file (required) |
| `output.bin` | `a.bin` | Binary output file |
| `-v` | off | Verbose: print symbol table and addresses |

---

## Syntax

### Comments

```asm
; Everything after a semicolon is a comment
LDA #$42    ; inline comment
```

### Numbers

| Format | Example | Value |
|--------|---------|-------|
| Decimal | `42` | 42 |
| Hex (`$`) | `$2A` | 42 |
| Hex (`0x`) | `0x2A` | 42 |
| Binary | `%00101010` | 42 |
| Negative | `-5` | −5 |

### Labels

```asm
loop:
    INX
    BNE loop
```

- Must start with a letter or `_`
- May contain letters, digits, `_`
- Case-sensitive
- Terminated by `:`

### Constants

```asm
IO_OUT = $F001
MAX    = 255

    LDA #MAX
    STA IO_OUT
```

Constants are evaluated at assembly time and do not reserve memory.

---

## Directives

### `.org` — set origin

```asm
.org $0800
```

Sets the current assembly address.  May appear more than once.

### `.byte` — emit bytes

```asm
.byte $0D, $0A, $00
.byte 10, 20, 30
.byte %11110000
.byte MAX - 1           ; expression
```

### `.word` — emit 16-bit little-endian words

```asm
.word $1234             ; emits $34, $12
.word start             ; address of label
.word $FFFC, $FFFE
```

### `.asc` — emit ASCII string

```asm
.asc "Hello, world!"
```

Emits the characters as raw bytes.  No null terminator is added automatically;
add one with `.byte 0`.  Only double-quoted strings are accepted.

```asm
message:
    .asc "OK"
    .byte 13, 10, 0     ; CR LF NUL
```

### `.fill` — fill a region

```asm
.fill 256, $EA          ; 256 × NOP ($EA)
.fill 16                ; 16 × $00
```

---

## Expressions

Expressions may appear wherever a numeric value is expected.

### Operators (lowest to highest precedence)

| Operator | Meaning |
|----------|---------|
| `+` `-`  | addition, subtraction |
| `*` `/` `%` | multiply, divide, modulo |

Parentheses override precedence.

### Program counter

`*` refers to the current assembly address:

```asm
    JMP * + 3           ; skip next two bytes
table = *               ; label for current position
```

### Examples

```asm
BASE   = $0800
OFFSET = $100
ENTRY  = BASE + OFFSET  ; $0900

    LDA ENTRY + 5       ; absolute $0905
    LDX #(MAX / 2)
```

---

## Addressing modes

| Mode | Syntax | Example |
|------|--------|---------|
| Implied | — | `NOP` |
| Accumulator | `A` | `ASL A` |
| Immediate | `#val` | `LDA #$42` |
| Zero page | `zp` | `LDA $80` |
| Zero page, X | `zp,X` | `LDA $80,X` |
| Zero page, Y | `zp,Y` | `LDX $80,Y` |
| Absolute | `addr` | `JMP $0800` |
| Absolute, X | `addr,X` | `STA $0400,X` |
| Absolute, Y | `addr,Y` | `LDA $0400,Y` |
| Indirect | `(addr)` | `JMP ($FFFC)` |
| Indexed indirect | `(zp,X)` | `LDA ($40,X)` |
| Indirect indexed | `(zp),Y` | `STA ($40),Y` |
| Relative | `label` | `BEQ loop` |

Branches are relative and have a reach of ±127 bytes from the
following instruction.

---

## Instruction set

### Load / store

```asm
LDA  LDX  LDY          ; load A / X / Y
STA  STX  STY          ; store A / X / Y
```

### Transfer

```asm
TAX  TAY               ; A → X / Y
TXA  TYA               ; X / Y → A
TSX  TXS               ; SP ↔ X
```

### Stack

```asm
PHA  PHP               ; push A / P
PLA  PLP               ; pull A / P
```

### Arithmetic

```asm
ADC  SBC               ; add / subtract with carry
INC  DEC               ; increment / decrement memory
INX  INY               ; increment X / Y
DEX  DEY               ; decrement X / Y
```

### Logic

```asm
AND  ORA  EOR          ; bitwise AND / OR / XOR
BIT                    ; bit test (sets N, V, Z)
```

### Shift / rotate

```asm
ASL  LSR               ; shift left / right
ROL  ROR               ; rotate left / right
```

### Compare

```asm
CMP  CPX  CPY          ; compare A / X / Y
```

### Branch

```asm
BCC  BCS               ; carry clear / set
BEQ  BNE               ; zero set / clear
BMI  BPL               ; negative set / clear
BVC  BVS               ; overflow clear / set
```

### Jump / call

```asm
JMP                    ; unconditional jump (absolute or indirect)
JSR                    ; jump to subroutine
RTS                    ; return from subroutine
RTI                    ; return from interrupt
```

### Flags

```asm
CLC  SEC               ; clear / set carry
CLD  SED               ; clear / set decimal
CLI  SEI               ; clear / set interrupt disable
CLV                    ; clear overflow
```

### Miscellaneous

```asm
NOP                    ; no operation
BRK                    ; software interrupt (drops to monitor in m6502)
```

---

## Registers

| Register | Width | Description |
|----------|-------|-------------|
| A  | 8-bit  | Accumulator |
| X  | 8-bit  | Index register |
| Y  | 8-bit  | Index register |
| SP | 8-bit  | Stack pointer (page $01, full-descending) |
| PC | 16-bit | Program counter |
| P  | 8-bit  | Status: N V — B D I Z C |

---

## Complete example

```asm
; hello.asm — write "HELLO" then halt
;
; Memory-mapped I/O (m6502 emulator):
;   $F001  write = character output
;   $F002  read  = $FF if input ready
;   $F003  read  = next input character

IO_OUT = $F001

        .org $0800

start:
        ldx  #0
loop:
        lda  msg,x
        beq  done
        sta  IO_OUT
        inx
        bne  loop
done:
        brk             ; enter monitor

msg:    .asc "HELLO"
        .byte 13, 10, 0

        .org $FFFC
        .word start     ; RESET vector
        .word start     ; IRQ vector
```

Assemble and run:

```
python3 a6502/asm.py hello.asm hello.bin
m6502/m6502 -r -a 800 hello.bin
```
