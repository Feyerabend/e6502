; smc.asm -- self-modifying code meets a split cache
;
; The loop patches the immediate operand of the LDA at `patch`, then executes
; it.  This was ordinary practice in 1980; it is the clearest way to see what
; a Harvard split actually costs you.
;
;   mode vn        prints  ABCDE   one memory, one cache: the patch is seen
;   mode mod       prints  AAAAA   the store went into D$; I$ still holds the
;                                  old line, and nothing tells the program so
;   mode mod + snoop on
;                  prints  ABCDE   hardware coherence -- correct, and not free
;   mode harvard   prints  AAAAA   the store went to a different memory; the
;                                  instruction space cannot be written at all
;
;   h6502 -m vn      -a 0800 demos/smc.bin -x "g 800; q"
;   h6502 -m mod     -a 0800 demos/smc.bin -x "g 800; q"
;   h6502 -m harvard -a 0800 demos/smc.bin -x "g 800; q"
;
; See smc_icbi.asm and smc_fixed.asm for what it takes to repair this.

IO_OUT = $F001
DCLEAN = $F0FC          ; write: clean (write back) the data cache
ICLEAR = $F0FD          ; write: invalidate the instruction cache
HALT   = $F0FF

        .org $0800

start:
        LDX #0
next:
        TXA
        CLC
        ADC #65         ; 'A' + X
        STA patch+1     ; <<< write into our own instruction stream

patch:
        LDA #65         ; the operand byte just overwritten
        STA IO_OUT

        INX
        CPX #5
        BNE next

        LDA #13
        STA IO_OUT
        STA HALT
