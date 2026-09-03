; smc_icbi.asm -- the obvious fix, which does not work
;
; After patching the instruction stream the program invalidates the
; instruction cache, so the stale line is dropped and refetched.  That is the
; whole fix, surely?
;
;   mode mod   prints AAAAA anyway.
;
; The patched byte is sitting DIRTY in the data cache.  It has not reached
; main memory.  Invalidating I$ only forces a refill from a memory that never
; received the store, so the old byte comes straight back.
;
; This is exactly why ARM's sequence is two instructions and not one, and why
; it is ordered clean-then-invalidate.  Two ways to make this program work
; without changing it:
;
;   config d write=wt    make the data cache write-through: stores reach
;                        memory immediately, so there is nothing to clean
;   snoop on             let the hardware do the coherence for you
;
; Or fix the program: see smc_fixed.asm.

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
        STA ICLEAR      ; <<< invalidate I$ ... and nothing else
patch:
        LDA #65         ; the operand byte just overwritten
        STA IO_OUT

        INX
        CPX #5
        BNE next

        LDA #13
        STA IO_OUT
        STA HALT
