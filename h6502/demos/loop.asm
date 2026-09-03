; loop.asm -- instruction locality
;
; Sum a 256-byte array, 40 times over.  The loop body is a dozen bytes, so
; after the first pass the instruction side never misses again.  The data
; side misses once per cache line and hits for every other byte in it.
;
;   h6502 -a 0800 demos/loop.bin -x "g 800; stats"
;
; Watch what happens to the D$ hit rate as you change the line size:
;   config d line=1    -- no spatial locality at all: every access misses
;   config d line=16   -- 15 of every 16 accesses hit
;   config d line=64   -- 63 of every 64

IO_OUT = $F001
STATS  = $F0FE          ; write: zero the statistics
HALT   = $F0FF          ; write: stop the machine

ARRAY  = $2000
TOTAL  = $80            ; zero-page running total

        .org $0800

start:
        ; ---- setup: fill the array (before the measured region) ----
        LDX #0
fill:
        TXA
        STA ARRAY,X
        INX
        BNE fill

        STA STATS       ; <<< everything before this point is not counted

        ; ---- the measured region ----
        LDY #40         ; outer: 40 passes
outer:
        LDA #0
        STA TOTAL
        LDX #0
inner:
        LDA TOTAL
        CLC
        ADC ARRAY,X     ; the only data-side load in the loop
        STA TOTAL
        INX
        BNE inner       ; 256 iterations
        DEY
        BNE outer

        STA HALT
