; stride.asm -- spatial locality, and why the line size matters
;
; Perform exactly 256 loads, each STRIDE bytes past the last.  The number of
; accesses is fixed, so the miss count is directly comparable across strides.
;
;   h6502 -a 0800 demos/stride.bin -x "e 12 01; g 800; stats"
;   h6502 -a 0800 demos/stride.bin -x "e 12 04; g 800; stats"
;   h6502 -a 0800 demos/stride.bin -x "e 12 10; g 800; stats"
;
; Read the MISS COUNT, not the hit rate.  The zero-page pointer arithmetic
; adds about nine always-hitting accesses per iteration and dilutes the
; percentage; the misses are all the array walk.  With 16-byte lines:
;
;   stride 1   ($01)   256 loads over  256 bytes  ->  ~16 misses
;   stride 4   ($04)   256 loads over  1 KB       ->  ~64 misses
;   stride 16  ($10)   256 loads over  4 KB       -> ~256 misses
;
; Once the stride reaches the line size, every load lands on a fresh line and
; the cache stops helping: the machine is fetching sixteen bytes to use one.
; Nothing about the code changed -- only the order in which it walks memory.
; This is why an array-of-structs traversal that touches one field can run an
; order of magnitude slower than the struct-of-arrays version of the same loop.

STATS  = $F0FE
HALT   = $F0FF

PTR    = $10            ; $10/$11 -- 16-bit walk pointer
STRIDE = $12            ; patch this byte to change the experiment
CNT    = $13

ARRAY  = $2000

        .org $0800

start:
        LDA STRIDE      ; the monitor patches $12 before the run;
        BNE have        ; 0 means "not set", so fall back to 1
        LDA #1
        STA STRIDE
have:
        STA STATS       ; <<< start measuring

        LDA #(ARRAY % 256)
        STA PTR
        LDA #(ARRAY / 256)
        STA PTR+1
        LDA #0
        STA CNT         ; 0 means 256 iterations below

walk:
        LDY #0
        LDA (PTR),Y     ; <-- the one access we are measuring

        CLC             ; PTR += STRIDE
        LDA PTR
        ADC STRIDE
        STA PTR
        LDA PTR+1
        ADC #0
        STA PTR+1

        DEC CNT
        BNE walk

        STA HALT
