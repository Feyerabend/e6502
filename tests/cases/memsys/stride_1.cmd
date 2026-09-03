-m mod -a 0800 h6502/demos/stride.bin -x "e 12 01; g 800; stats; q"
# 256 loads over 256 bytes: 16 misses, one per 16-byte line.
