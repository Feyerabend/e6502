; smc_fixed.asm -- self-modifying code done correctly
;
; Two maintenance operations, in this order:
;
;   1. clean the data cache   -- push the patched byte out to main memory
;   2. invalidate I$          -- force the fetch side to go back and get it
;
; Reversing them fails.  Omitting the first fails (see smc_icbi.asm).  This is
; ARM's  DC CVAU / DSB / IC IVAU / DSB / ISB  sequence with the barriers taken
; out, and it is the reason a JIT compiler cannot just write bytes and jump to
; them.  Every runtime that generates code at runtime -- a JIT, a trampoline,
; a debugger planting a breakpoint -- performs some version of this dance.
;
;   mode mod   prints ABCDE
;
; In Harvard mode it still prints AAAAA.  No amount of cache maintenance helps
; when the store physically cannot reach the instruction memory: that is the
; difference between a cache problem and an architecture problem.
;
; Compare `stats` against smc.bin.  The fix is not free -- invalidating the
; instruction cache throws away every line in it, including all the ones that
; had nothing to do with the patch.

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
        STA DCLEAN      ; 1. push the store out to main memory  (ARM: DC CVAU)
        STA ICLEAR      ; 2. drop the stale instruction line     (ARM: IC IVAU)
patch:
        LDA #65         ; the operand byte just overwritten
        STA IO_OUT

        INX
        CPX #5
        BNE next

        LDA #13
        STA IO_OUT
        STA HALT
