-m harvard -a 0800 h6502/demos/smc.bin -x "warn off; g 800; clean; mi 0800 080F; m 0800 080F; q"
# After the run the two memories have diverged. I-space still holds the
# original operand $41 ('A') at $080A; D-space holds $45 ('E'), the last value
# the program tried to patch in. The store went somewhere -- just not anywhere
# the fetch side can reach.
