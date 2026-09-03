-m mod -a 0800 h6502/demos/stride.bin -x "e 12 04; g 800; stats; q"
# 256 loads over 1 KB: 64 misses.
