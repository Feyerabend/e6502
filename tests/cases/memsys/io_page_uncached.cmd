-a 0800 h6502/demos/smc.bin -m mod -x "warn off; g 800; stats; q"
# The device page is never cached. Seven uncached accesses -- five character
# stores to $F001, the trailing CR, and the halt store to $F0FF -- appear in
# the by-kind census as DATA but in no cache's statistics, and cost no stall.
# Caching a device register would be a bug: a line fill would read four
# registers at once (consuming input!) and a write-back would replay stale
# writes to the console. This is why real systems mark MMIO uncacheable.
