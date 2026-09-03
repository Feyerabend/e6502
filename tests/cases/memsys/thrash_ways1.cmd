-m mod -a 0800 h6502/demos/thrash.bin -x "config d ways=1; g 800; stats; q"
# Direct-mapped, three colliding streams: 0% hit.
