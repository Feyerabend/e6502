-m mod -a 0800 h6502/demos/stride.bin -x "e 12 10; g 800; stats; q"
# Stride equals the line size: every load is a miss. 256 of them.
