-m mod -a 0800 h6502/demos/thrash.bin -x "cache off; g 800; stats; q"
# Baseline machine: no caches, no stalls, and the flat-memory cycle count the
# plain m6502 emulator reports.
