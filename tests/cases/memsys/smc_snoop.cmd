-m mod -a 0800 h6502/demos/smc.bin -x "snoop on; g 800; stats; q"
# Hardware coherence: D-side writes invalidate the matching I$ line. ABCDE,
# at the cost of I$ invalidations (visible in the statistics).
