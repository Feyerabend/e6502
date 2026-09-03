CC      = cc
CFLAGS  = -std=c99 -Wall -Wextra -O2 -pedantic
TARGET  = m6502/m6502
HTARGET = h6502/h6502
HTEST   = h6502/cachetest
ASM     = python3 a6502/asm.py

# h6502 memory-hierarchy demos
DEMOS   = $(patsubst %.asm,%.bin,$(wildcard h6502/demos/*.asm))

# BASIC versions (Apple II-style evolution)
NANO    = basic/1-nano/basic.bin
INTEGER = basic/2-integer/basic.bin
MSBASIC = basic/3-msbasic/basic.bin
FLOAT   = basic/4-float/basic.bin

# newest tier that currently exists is what `make run` launches
LATEST  = $(MSBASIC)

all: $(TARGET) $(HTARGET) $(DEMOS)

$(TARGET): m6502/m6502.c m6502/main.c m6502/m6502.h
	$(CC) $(CFLAGS) -o $(TARGET) m6502/m6502.c m6502/main.c

# ---- h6502: the same CPU core behind a visible memory hierarchy ----
H_SRC = h6502/cache.c h6502/memsys.c h6502/hmon.c m6502/m6502.c
H_HDR = h6502/cache.h h6502/memsys.h m6502/m6502.h

$(HTARGET): $(H_SRC) $(H_HDR)
	$(CC) $(CFLAGS) -o $(HTARGET) $(H_SRC)

$(HTEST): h6502/cachetest.c h6502/cache.c h6502/cache.h
	$(CC) $(CFLAGS) -o $(HTEST) h6502/cachetest.c h6502/cache.c

h6502: $(HTARGET) $(DEMOS)

h6502/demos/%.bin: h6502/demos/%.asm
	$(ASM) $< $@

# ---- assemble rules (one per tier) ----
$(NANO): basic/1-nano/basic.asm
	$(ASM) basic/1-nano/basic.asm $(NANO)

$(INTEGER): basic/2-integer/basic.asm
	$(ASM) basic/2-integer/basic.asm $(INTEGER)

$(MSBASIC): basic/3-msbasic/basic.asm
	$(ASM) basic/3-msbasic/basic.asm $(MSBASIC)

$(FLOAT): basic/4-float/basic.asm
	$(ASM) basic/4-float/basic.asm $(FLOAT)

# ---- run rules ----
run: $(TARGET) $(LATEST)
	./$(TARGET) -r -a 800 $(LATEST)

basic1: $(TARGET) $(NANO)
	./$(TARGET) -r -a 800 $(NANO)

basic2: $(TARGET) $(INTEGER)
	./$(TARGET) -r -a 800 $(INTEGER)

basic3: $(TARGET) $(MSBASIC)
	./$(TARGET) -r -a 800 $(MSBASIC)

basic4: $(TARGET) $(FLOAT)
	./$(TARGET) -r -a 800 $(FLOAT)

assemble: $(NANO)
	@echo "Assembled -> $(NANO)"

# ---- h6502 demo runs (each prints its statistics and exits) ----
# the same self-modifying program under all three memory architectures
smc: $(HTARGET) h6502/demos/smc.bin
	@echo "--- von Neumann: one memory, one cache ---"
	@./$(HTARGET) -m vn      -a 800 h6502/demos/smc.bin -x "g 800; q" </dev/null
	@echo "--- modified Harvard: one memory, split L1 ---"
	@./$(HTARGET) -m mod     -a 800 h6502/demos/smc.bin -x "g 800; q" </dev/null
	@echo "--- Harvard: two memories, split L1 ---"
	@./$(HTARGET) -m harvard -a 800 h6502/demos/smc.bin -x "warn off; g 800; q" </dev/null

# what it takes to repair self-modifying code on a split-cache machine
smc-fix: $(HTARGET) h6502/demos/smc_icbi.bin h6502/demos/smc_fixed.bin
	@echo "--- invalidate I\$$ only: still wrong, the store is dirty in D\$$ ---"
	@./$(HTARGET) -m mod -a 800 h6502/demos/smc_icbi.bin  -x "warn off; g 800; q" </dev/null
	@echo "--- clean D\$$, then invalidate I\$$ ---"
	@./$(HTARGET) -m mod -a 800 h6502/demos/smc_fixed.bin -x "warn off; g 800; q" </dev/null

# associativity at constant capacity
assoc: $(HTARGET) h6502/demos/thrash.bin
	@for w in 1 2 4; do printf "%s-way: " $$w; \
	  ./$(HTARGET) -m mod -a 800 h6502/demos/thrash.bin \
	    -x "config d ways=$$w; g 800; stats; q" </dev/null \
	    | grep 'hit rate' | tail -1; done

# spatial locality: same instruction count, different walk
stride: $(HTARGET) h6502/demos/stride.bin
	@for s in 01 04 10; do printf "stride \$$%s: " $$s; \
	  ./$(HTARGET) -m mod -a 800 h6502/demos/stride.bin \
	    -x "e 12 $$s; g 800; stats; q" </dev/null \
	    | grep 'hit rate' | tail -1; done

# miss rate versus line size at fixed capacity -- the U-curve
lines: $(HTARGET) h6502/demos/stride.bin
	@for l in 2 4 8 16 32 64 128; do printf "line %3s: " $$l; \
	  ./$(HTARGET) -m mod -a 800 h6502/demos/stride.bin \
	    -x "config d line=$$l ways=1; e 12 04; g 800; stats; q" </dev/null \
	    | grep 'traffic in' | tail -1; done

# ---- tests ----
test: $(TARGET)
	python3 tests/run_tests.py all

test-nano: $(TARGET)
	python3 tests/run_tests.py nano

# memory-model tests: cache unit tests + end-to-end model cases
test-mem: $(HTARGET) $(HTEST) $(DEMOS)
	python3 tests/run_mem_tests.py

test-all: test test-mem

# BREAK (Ctrl-C) test - signal-based, kept separate from the .bas suite
test-break: $(TARGET) $(NANO) $(INTEGER) $(MSBASIC)
	python3 tests/test_break.py

clean:
	rm -f $(TARGET) $(HTARGET) $(HTEST) $(DEMOS)

.PHONY: all run basic1 basic2 basic3 basic4 assemble h6502 \
        smc smc-fix assoc stride lines \
        test test-nano test-break test-mem test-all clean
