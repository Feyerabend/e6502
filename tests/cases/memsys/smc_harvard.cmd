-m harvard -a 0800 h6502/demos/smc.bin -x "warn off; g 800; q"
# True Harvard: the store goes to a different physical memory. AAAAA, and no
# coherence warning -- there is no coherence problem, just no path at all.
