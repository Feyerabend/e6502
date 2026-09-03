-m mod -a 0800 h6502/demos/loop.bin -x "g 800; stats; q"
# A tight loop: the instruction side misses twice in 113,000 fetches.
