-m mod -a 0800 h6502/demos/loop.bin -x "config d write=wt; g 800; stats; q"
# Write-through: every store also goes to memory, so bytes-out tracks the
# store count instead of the eviction count.
