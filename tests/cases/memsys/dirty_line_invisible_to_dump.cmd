-m mod -a 0800 h6502/demos/smc.bin -x "warn off; g 800; m 0800 080F; clean; m 0800 080F; q"
# A write-back cache means a memory dump can lie to you. The first dump reads
# main memory and still shows $41 at $080A; the store is sitting dirty in D$.
# After `clean` pushes it out, the second dump shows $45. This is why a
# debugger on a real machine has to perform cache maintenance before it
# believes what it reads -- and why JTAG probes have a cache-flush button.
