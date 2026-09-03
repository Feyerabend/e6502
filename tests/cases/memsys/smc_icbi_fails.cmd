-m mod -a 0800 h6502/demos/smc_icbi.bin -x "warn off; g 800; q"
# Invalidating I$ alone is NOT enough with a write-back D$: the refill reads a
# main memory that never received the store. Still AAAAA.
