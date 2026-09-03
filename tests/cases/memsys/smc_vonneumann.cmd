-m vn -a 0800 h6502/demos/smc.bin -x "g 800; q"
# von Neumann: one memory, one cache. The patch is visible to the fetch side,
# so the program prints ABCDE.
