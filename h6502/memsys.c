/*
 * memsys.c  --  address spaces, cache routing, and the three memory models
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "memsys.h"

/* the two physical memories.  In the non-Harvard models dmem aliases imem,
 * so "code space" and "data space" are literally the same bytes. */
static uint8_t MEM_I[0x10000];
static uint8_t MEM_D[0x10000];

/* ------------------------------------------------------------------ *
 * Device page.  Hosted by the monitor (hmon.c) so the emulator keeps
 * its console I/O; uncacheable in every model.
 * ------------------------------------------------------------------ */
extern uint8_t h_io_read (uint16_t addr, int *handled);
extern void    h_io_write(uint16_t addr, uint8_t val, int *handled);

const char *ms_mode_name(MemMode m) {
    switch (m) {
        case MODE_VONNEUMANN: return "von Neumann (unified memory, unified L1)";
        case MODE_HARVARD:    return "Harvard (split memory, split L1)";
        case MODE_MODIFIED:   return "modified Harvard (unified memory, split L1)";
    }
    return "?";
}
const char *ms_kind_name(unsigned kind) {
    static const char *n[6] = { "OPCODE", "OPERAND", "DATA",
                                "PTR", "STACK", "VECTOR" };
    return kind < 6 ? n[kind] : "?";
}

/* ------------------------------------------------------------------ *
 * Backing-store callbacks handed to each cache
 * ------------------------------------------------------------------ */
static uint8_t bs_read_i (void *ctx, uint16_t a) { return ((MemSys*)ctx)->imem[a]; }
static void    bs_write_i(void *ctx, uint16_t a, uint8_t v) { ((MemSys*)ctx)->imem[a] = v; }
static uint8_t bs_read_d (void *ctx, uint16_t a) { return ((MemSys*)ctx)->dmem[a]; }
static void    bs_write_d(void *ctx, uint16_t a, uint8_t v) { ((MemSys*)ctx)->dmem[a] = v; }

static void cache_defaults(Cache *c, const char *name) {
    const char *err;
    memset(c, 0, sizeof *c);
    c->repl         = REPL_LRU;
    c->wpol         = WPOL_BACK;
    c->write_alloc  = 1;
    c->miss_penalty = 8;
    /* 256 bytes, 16-byte lines, 2-way: 8 sets.  Small on purpose -- a cache
     * big enough to hold the whole program teaches you nothing. */
    cache_config(c, name, 256, 16, 2, &err);
}

void ms_init(MemSys *ms, M6502 *cpu) {
    memset(ms, 0, sizeof *ms);
    ms->cpu        = cpu;
    ms->mode       = MODE_VONNEUMANN;
    ms->caches_on  = 1;
    ms->snoop      = 0;
    ms->warn_stale = 1;
    ms->stale_warn_left = 8;    /* enough to make the point, not a flood */
    ms->imem       = MEM_I;
    ms->dmem       = MEM_I;          /* aliased until Harvard is selected */

    cache_defaults(&ms->ci, "I$");
    cache_defaults(&ms->cd, "D$");
    cache_defaults(&ms->cu, "U$");
    cache_attach(&ms->ci, bs_read_i, bs_write_i, ms);
    cache_attach(&ms->cd, bs_read_d, bs_write_d, ms);
    cache_attach(&ms->cu, bs_read_i, bs_write_i, ms);
}

void ms_free(MemSys *ms) {
    cache_free(&ms->ci); cache_free(&ms->cd); cache_free(&ms->cu);
}

int ms_set_mode(MemSys *ms, MemMode m) {
    /* flush before changing the shape of the machine: dirty write-back data
     * has to land somewhere, and after the switch "somewhere" may differ. */
    cache_flush(&ms->ci); cache_flush(&ms->cd); cache_flush(&ms->cu);
    ms->mode = m;
    ms->imem = MEM_I;
    ms->dmem = (m == MODE_HARVARD) ? MEM_D : MEM_I;
    return 0;
}

/* ------------------------------------------------------------------ *
 * Routing
 * ------------------------------------------------------------------ */
static MemSide side_of(unsigned kind) {
    /* Opcode and operand bytes are the instruction stream.  Vectors are part
     * of the program image too -- on a Harvard machine the reset vector lives
     * in program ROM -- so they are fetched from code space.  Everything else
     * (operand data, pointer indirection, the stack) is the data side. */
    switch (kind) {
        case M6502_ACC_OPCODE:
        case M6502_ACC_OPERAND:
        case M6502_ACC_VECTOR: return SIDE_CODE;
        default:               return SIDE_DATA;
    }
}

Cache *ms_cache_for(MemSys *ms, MemSide side) {
    if (!ms->caches_on) return NULL;
    if (ms->mode == MODE_VONNEUMANN) return &ms->cu;
    return side == SIDE_CODE ? &ms->ci : &ms->cd;
}

static uint8_t *space_for(MemSys *ms, MemSide side) {
    return side == SIDE_CODE ? ms->imem : ms->dmem;
}

uint8_t ms_peek(const MemSys *ms, MemSide side, uint16_t addr) {
    return (side == SIDE_CODE ? ms->imem : ms->dmem)[addr];
}
void ms_poke(MemSys *ms, MemSide side, uint16_t addr, uint8_t val) {
    (side == SIDE_CODE ? ms->imem : ms->dmem)[addr] = val;
}
uint8_t ms_peek_code(void *ctx, uint16_t addr) {
    return ((MemSys *)ctx)->imem[addr];
}

/* ------------------------------------------------------------------ *
 * Trace
 * ------------------------------------------------------------------ */
static void trace_line(MemSys *ms, const char *op, unsigned kind,
                       uint16_t addr, uint8_t val, Cache *c, CacheEvent *ev)
{
    if (!ms->trace) return;
    if (ms->trace_left == 0) return;
    if (ms->trace_left > 0) ms->trace_left--;

    printf("  %-5s %-7s $%04X = $%02X  ", op, ms_kind_name(kind), addr, val);
    if (!c) {
        printf("[uncached]\n");
        return;
    }
    printf("%s set %2u way %u tag $%03X  %s",
           c->name, ev->set, ev->way, ev->tag, ev->hit ? "HIT " : "MISS");
    if (!ev->hit) printf(" +%uc", ev->stall);
    if (ev->evicted)
        printf("  evict $%04X%s", ev->evicted_base, ev->wrote_back ? " (dirty->mem)" : "");
    putchar('\n');
}

/* ------------------------------------------------------------------ *
 * The bus
 * ------------------------------------------------------------------ */
uint8_t ms_read(void *ctx, uint16_t addr) {
    MemSys   *ms   = (MemSys *)ctx;
    unsigned  kind = ms->cpu->access;
    MemSide   side = side_of(kind);
    Cache    *c;
    CacheEvent ev;
    uint8_t   v;
    int       handled = 0;

    ms->n_kind[kind < 6 ? kind : 2]++;
    if (side == SIDE_CODE) ms->n_code++; else ms->n_data++;

    /* device page: uncacheable, and it must see every access */
    if (addr >= MS_IO_LO && addr <= MS_IO_HI) {
        ms->n_uncached++;
        v = h_io_read(addr, &handled);
        if (!handled) v = space_for(ms, side)[addr];
        trace_line(ms, "read", kind, addr, v, NULL, NULL);
        return v;
    }

    c = ms_cache_for(ms, side);
    if (!c) {
        v = space_for(ms, side)[addr];
        trace_line(ms, "read", kind, addr, v, NULL, NULL);
        return v;
    }
    v = cache_read(c, addr, &ev);
    trace_line(ms, "read", kind, addr, v, c, &ev);
    return v;
}

void ms_write(void *ctx, uint16_t addr, uint8_t val) {
    MemSys   *ms   = (MemSys *)ctx;
    unsigned  kind = ms->cpu->access;
    MemSide   side = side_of(kind);
    Cache    *c;
    CacheEvent ev;
    int       handled = 0;
    int       coherence;

    ms->n_kind[kind < 6 ? kind : 2]++;
    if (side == SIDE_CODE) ms->n_code++; else ms->n_data++;

    if (addr >= MS_IO_LO && addr <= MS_IO_HI) {
        ms->n_uncached++;
        h_io_write(addr, val, &handled);
        if (!handled) space_for(ms, side)[addr] = val;
        trace_line(ms, "write", kind, addr, val, NULL, NULL);
        return;
    }

    /* Every store the 6502 can issue is a data-side access.  If it lands
     * inside the loaded program image it was (or looks like) self-modifying
     * code, which each model treats differently. */
    if (ms->code_known && addr >= ms->code_lo && addr <= ms->code_hi)
        ms->code_stores++;

    c = ms_cache_for(ms, side);

    /*
     * Coherence.  Only the modified-Harvard model has a problem: one memory,
     * two caches.  A store goes into D$; if I$ is holding the same line, the
     * fetch side keeps serving the old bytes.
     * Note this has to be DECIDED before the store but ACTED ON after it:
     * dropping the stale I$ line is not enough on its own, because the I$
     * refill reads main memory, which a write-back D$ has not reached yet.
     * Snooping hardware must first push the data to the point where both
     * caches can see it, and only then invalidate.  That is what coherence
     * costs, and it is why the software sequence has the same two steps.
     */
    coherence = (ms->mode == MODE_MODIFIED && side == SIDE_DATA &&
                 ms->caches_on && cache_probe(&ms->ci, addr, NULL));
    if (coherence && !ms->snoop) {
        ms->stale_writes++;
        if (ms->warn_stale && ms->stale_warn_left != 0) {
            if (ms->stale_warn_left > 0) ms->stale_warn_left--;
            printf("  [coherence] store to $%04X is now stale in I$ "
                   "(line $%04X) -- the fetch side will not see it\n",
                   addr, (uint16_t)(addr & ~(uint16_t)(ms->ci.line_bytes - 1u)));
        }
    }
    if (!c) {
        space_for(ms, side)[addr] = val;
        trace_line(ms, "write", kind, addr, val, NULL, NULL);
        return;
    }
    cache_write(c, addr, val, &ev);
    trace_line(ms, "write", kind, addr, val, c, &ev);

    if (coherence && ms->snoop) {
        cache_clean_addr(&ms->cd, addr);   /* make the store visible ...    */
        cache_snoop(&ms->ci, addr);        /* ... then drop the stale line  */
    }
}

/* ------------------------------------------------------------------ */
void ms_flush(MemSys *ms, int code, int data) {
    if (ms->mode == MODE_VONNEUMANN) { if (code || data) cache_flush(&ms->cu); return; }
    if (code) cache_flush(&ms->ci);
    if (data) cache_flush(&ms->cd);
}

void ms_clean(MemSys *ms) {
    if (ms->mode == MODE_VONNEUMANN) cache_clean(&ms->cu);
    else cache_clean(&ms->cd);
}

void ms_reset_stats(MemSys *ms) {
    cache_reset_stats(&ms->ci);
    cache_reset_stats(&ms->cd);
    cache_reset_stats(&ms->cu);
    memset(ms->n_kind, 0, sizeof ms->n_kind);
    ms->n_code = ms->n_data = ms->n_uncached = 0;
    ms->stale_writes = ms->code_stores = 0;
    ms->stale_warn_left = 8;
}

uint64_t ms_stall_cycles(const MemSys *ms) {
    if (!ms->caches_on) return 0;
    if (ms->mode == MODE_VONNEUMANN) return ms->cu.stall_cycles;
    return ms->ci.stall_cycles + ms->cd.stall_cycles;
}
