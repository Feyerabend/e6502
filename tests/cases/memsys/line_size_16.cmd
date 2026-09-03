-m mod -a 0800 h6502/demos/stride.bin -x "config d line=16 ways=1; e 12 04; g 800; stats; q"
# 256 loads with a 4-byte stride over 1 KB. Capacity is pinned at 256 bytes
# and direct-mapped throughout; only the line size changes. The miss count is
# not monotone -- it is a U:
#
#     line     2    4    8   16   32   64  128
#     misses 261  260  140   92   92  140  260
#     bytes  522 1040 1120 1472 2944 8960 33280
#
# Going up from 2, longer lines buy spatial locality: one miss now serves
# several loads. Past 32 the win reverses, because a fixed 256 bytes divided
# into longer lines is FEWER lines, and the walk starts evicting itself.
# Meanwhile the bytes fetched from memory climb without pause: at line=128 the
# machine hauls 33 KB out of memory to read 256 bytes it wanted.
#
# This is the classic miss-rate-versus-block-size curve, and it is why real
# L1 line sizes cluster around 32-64 bytes rather than growing indefinitely.
