-m mod -a 0800 h6502/demos/smc_icbi.bin -x "config d write=wt; warn off; g 800; q"
# Same binary, write-through D$: stores reach memory immediately, so there is
# nothing to clean and the I$ invalidate is sufficient. ABCDE.
