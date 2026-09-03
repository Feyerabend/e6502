-m harvard -a 0800 h6502/demos/smc_fixed.bin -x "warn off; g 800; q"
# The same correct sequence still fails on a true Harvard machine: cache
# maintenance cannot create a bus that does not exist. AAAAA.
