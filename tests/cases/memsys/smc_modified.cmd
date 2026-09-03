-m mod -a 0800 h6502/demos/smc.bin -x "g 800; stats; q"
# Modified Harvard, no snooping: the store lands in D$, I$ keeps serving the
# stale line, the program prints AAAAA, and `stats` reports 5 stale stores.
