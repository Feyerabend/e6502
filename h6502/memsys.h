/*
 * memsys.h  --  the memory system: address spaces, caches, and the model
 *
 * Three models, selectable at runtime:
 *
 *   von Neumann   one 64K memory, one unified L1.
 *                 Code and data are the same bytes; self-modifying code
 *                 works; instruction fetches and data loads compete for
 *                 the same cache lines.
 *
 *   Harvard       two separate 64K memories with separate buses and
 *                 separate L1 caches.  An instruction fetch physically
 *                 cannot reach the data memory and vice versa.  There is
 *                 no coherence problem because there is nothing to cohere:
 *                 they are different memories.  Self-modifying code is
 *                 impossible, and so is reading a constant out of your own
 *                 program text -- which is why real Harvard machines add an
 *                 instruction for it (AVR's LPM, PIC's RETLW).
 *
 *   modified      one 64K memory (as on any real machine you have used)
 *   Harvard       but two separate L1 caches, one per side.  This is what
 *                 essentially every processor since the 1990s actually is.
 *                 You get the Harvard bandwidth win at L1, and you inherit
 *                 a coherence problem: a store lands in D$, the matching
 *                 line sits stale in I$, and the CPU keeps executing the
 *                 old bytes.  That is what icache flush instructions are
 *                 for.
 *
 * The device page $F0xx is never cached, in any model, for the same reason
 * real systems mark MMIO uncacheable: a cache line fill would read four
 * device registers at once and a write-back would replay stale writes.
 */
#ifndef H6502_MEMSYS_H
#define H6502_MEMSYS_H

#include <stdint.h>
#include "cache.h"
#include "../m6502/m6502.h"

typedef enum {
    MODE_VONNEUMANN = 0,
    MODE_HARVARD    = 1,
    MODE_MODIFIED   = 2
} MemMode;

#define MS_IO_LO  0xF000u          /* device page: never cached */
#define MS_IO_HI  0xF0FFu

/* which side of the machine an access belongs to */
typedef enum { SIDE_CODE = 0, SIDE_DATA = 1 } MemSide;

typedef struct {
    MemMode  mode;
    int      caches_on;         /* 0 = bypass all caches (baseline machine) */
    int      snoop;             /* modified Harvard: D-writes invalidate I$ */
    int      warn_stale;        /* report writes that go stale in I$        */

    Cache    ci;                /* instruction cache (Harvard modes)        */
    Cache    cd;                /* data cache        (Harvard modes)        */
    Cache    cu;                /* unified cache     (von Neumann)          */

    uint8_t *imem;              /* 64K instruction space                    */
    uint8_t *dmem;              /* 64K data space (== imem unless Harvard)  */

    /* access census, by M6502_ACC_* kind */
    uint64_t n_kind[6];
    uint64_t n_code, n_data, n_uncached;
    uint64_t stale_writes;      /* modified mode, snoop off: silent staleness */
    uint64_t code_stores;       /* stores landing inside the loaded program   */
    long     stale_warn_left;   /* cap the running commentary                 */

    /* extent of the last loaded program image, for code_stores */
    uint16_t code_lo, code_hi;
    int      code_known;

    /* tracing */
    int      trace;
    long     trace_left;

    M6502   *cpu;               /* to read cpu->access inside the callback  */
} MemSys;

void ms_init (MemSys *ms, M6502 *cpu);
void ms_free (MemSys *ms);
int  ms_set_mode(MemSys *ms, MemMode m);   /* re-points spaces, flushes caches */

/* the two callbacks handed to m6502_init() */
uint8_t ms_read (void *ctx, uint16_t addr);
void    ms_write(void *ctx, uint16_t addr, uint8_t val);

/* raw, side-door access for the monitor and disassembler: no cache, no stats */
uint8_t ms_peek (const MemSys *ms, MemSide side, uint16_t addr);
void    ms_poke (MemSys *ms, MemSide side, uint16_t addr, uint8_t val);
/* a m6502_read_fn wrapper over I-space, so disassembly never disturbs the model */
uint8_t ms_peek_code(void *ctx, uint16_t addr);

/* the cache serving a given side in the current mode, or NULL if bypassed */
Cache *ms_cache_for(MemSys *ms, MemSide side);

void ms_flush(MemSys *ms, int code, int data);
void ms_clean(MemSys *ms);      /* push dirty data lines out to memory */
void ms_reset_stats(MemSys *ms);
uint64_t ms_stall_cycles(const MemSys *ms);

const char *ms_mode_name(MemMode m);
const char *ms_kind_name(unsigned kind);

#endif /* H6502_MEMSYS_H */
