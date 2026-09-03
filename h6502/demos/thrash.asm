; thrash.asm -- conflict misses, and what associativity buys you
;
; Three 64-byte arrays, 256 bytes apart, walked in lockstep.  256 is a
; multiple of the set stride in every geometry below, so all three arrays
; always land on the SAME set.  What changes is how many lines that set can
; hold at once:
;
;   config d ways=1    0.0% hit   direct-mapped: each array evicts the last
;   config d ways=2    0.0% hit   still hopeless: three streams, two ways,
;                                 and LRU throws out exactly the line you
;                                 are about to ask for next
;   config d ways=4   99.6% hit   room for all three
;
; The cache never changed size.  It stayed 256 bytes throughout.  All that
; changed was permission to keep more than N lines that happen to share an
; index -- and the program went from every access missing to almost none.
;
; This is the pathology behind "my program got 10x slower when I padded that
; struct to a power of two".  Power-of-two strides are exactly the ones that
; concentrate on a single set.  Try moving one array off the boundary:
;
;   (rebuild with A3 = $2210 instead of $2200 and watch ways=2 recover)

STATS = $F0FE
HALT  = $F0FF

A1    = $2000
A2    = $2100           ; +256
A3    = $2200           ; +512

        .org $0800

start:
        STA STATS

        LDY #16         ; 16 passes over the three arrays
pass:
        LDX #0
step:
        LDA A1,X
        LDA A2,X
        LDA A3,X
        INX
        CPX #64
        BNE step
        DEY
        BNE pass

        STA HALT
