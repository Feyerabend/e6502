-m mod -a 0800 h6502/demos/thrash.bin -x "config d ways=4; g 800; stats; q"
# Four ways, same 256 bytes of capacity: 99.6%.
