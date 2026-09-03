-m mod -a 0800 h6502/demos/smc_fixed.bin -x "warn off; g 800; stats; q"
# Clean D$ then invalidate I$ -- ARM's DC CVAU / IC IVAU order. ABCDE.
