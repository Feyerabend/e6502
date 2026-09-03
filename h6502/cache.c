/*
 * cache.c  --  configurable set-associative cache
 *
 * The whole model in one page: an access decomposes into (tag, set, offset);
 * we search the `ways` lines of that set for a matching valid tag; on a miss
 * we pick a victim, write it back if dirty, refill the line from the backing
 * store, and charge the miss penalty.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cache.h"

static unsigned log2u(unsigned v) {
    unsigned n = 0;
    while (v > 1) { v >>= 1; n++; }
    return n;
}
static int is_pow2(unsigned v) { return v && !(v & (v - 1)); }

int cache_config(Cache *c, const char *name,
                 unsigned size_bytes, unsigned line_bytes, unsigned ways,
                 const char **err)
{
    unsigned sets, nlines;
    uint8_t *store;

    if (!is_pow2(line_bytes) || line_bytes < 1 || line_bytes > 256) {
        *err = "line size must be a power of two, 1..256"; return -1;
    }
    if (ways < 1) { *err = "ways must be >= 1"; return -1; }
    if (size_bytes < line_bytes * ways) {
        *err = "cache is smaller than one set"; return -1;
    }
    if (size_bytes % (line_bytes * ways)) {
        *err = "size must be a whole number of sets (line * ways)"; return -1;
    }
    sets = size_bytes / (line_bytes * ways);
    if (!is_pow2(sets)) { *err = "set count must be a power of two"; return -1; }
    nlines = sets * ways;
    if (nlines > CACHE_MAX_LINES) { *err = "too many lines"; return -1; }
    if (size_bytes > 0x10000u) { *err = "cache larger than the address space"; return -1; }

    store = (uint8_t *)calloc(size_bytes, 1);
    if (!store) { *err = "out of memory"; return -1; }

    free(c->store);
    memset(c->line, 0, sizeof c->line);
    c->store      = store;
    c->line_bytes = line_bytes;
    c->ways       = ways;
    c->sets       = sets;
    c->capacity   = size_bytes;
    c->off_bits   = log2u(line_bytes);
    c->idx_bits   = log2u(sets);
    c->clock      = 0;
    if (name) { strncpy(c->name, name, sizeof c->name - 1);
                c->name[sizeof c->name - 1] = '\0'; }
    *err = NULL;
    return 0;
}

void cache_attach(Cache *c, cache_rd_fn rd, cache_wr_fn wr, void *ctx) {
    c->bs_read = rd; c->bs_write = wr; c->bs_ctx = ctx;
}
void cache_free(Cache *c) { free(c->store); c->store = NULL; }

void cache_decode(const Cache *c, uint16_t addr,
                  uint16_t *tag, unsigned *set, unsigned *off)
{
    unsigned o = (unsigned)addr & (c->line_bytes - 1u);
    unsigned s = ((unsigned)addr >> c->off_bits) & (c->sets - 1u);
    if (off) *off = o;
    if (set) *set = s;
    if (tag) *tag = (uint16_t)((unsigned)addr >> (c->off_bits + c->idx_bits));
}

static CacheLine *line_at(Cache *c, unsigned set, unsigned way) {
    return &c->line[set * c->ways + way];
}
static uint8_t *data_at(Cache *c, unsigned set, unsigned way) {
    return c->store + (size_t)(set * c->ways + way) * c->line_bytes;
}

int cache_probe(const Cache *c, uint16_t addr, unsigned *way) {
    uint16_t tag; unsigned set, w;
    cache_decode(c, addr, &tag, &set, NULL);
    for (w = 0; w < c->ways; w++) {
        const CacheLine *l = &c->line[set * c->ways + w];
        if (l->valid && l->tag == tag) { if (way) *way = w; return 1; }
    }
    return 0;
}

/* pick a victim way in `set` according to the replacement policy */
static unsigned pick_victim(Cache *c, unsigned set) {
    unsigned w, best = 0;
    uint32_t beststamp = 0xffffffffu;

    /* an invalid line is always the cheapest victim (a cold miss) */
    for (w = 0; w < c->ways; w++)
        if (!line_at(c, set, w)->valid) return w;

    if (c->repl == REPL_RANDOM) return (unsigned)(rand() % (int)c->ways);

    /* LRU and FIFO differ only in when `stamp` is updated (see below) */
    for (w = 0; w < c->ways; w++) {
        CacheLine *l = line_at(c, set, w);
        if (l->stamp < beststamp) { beststamp = l->stamp; best = w; }
    }
    return best;
}

static void writeback(Cache *c, unsigned set, unsigned way) {
    CacheLine *l = line_at(c, set, way);
    uint8_t   *d = data_at(c, set, way);
    unsigned   i;
    if (!l->valid || !l->dirty) return;
    for (i = 0; i < c->line_bytes; i++)
        c->bs_write(c->bs_ctx, (uint16_t)(l->base + i), d[i]);
    c->writebacks++;
    c->bytes_out += c->line_bytes;
    l->dirty = 0;
}

static void refill(Cache *c, unsigned set, unsigned way, uint16_t addr, uint16_t tag) {
    CacheLine *l = line_at(c, set, way);
    uint8_t   *d = data_at(c, set, way);
    uint16_t   base = (uint16_t)(addr & ~(uint16_t)(c->line_bytes - 1u));
    unsigned   i;
    for (i = 0; i < c->line_bytes; i++)
        d[i] = c->bs_read(c->bs_ctx, (uint16_t)(base + i));
    l->valid = 1; l->dirty = 0; l->tag = tag; l->base = base;
    l->stamp = ++c->clock;
    c->bytes_in += c->line_bytes;
}

/* common miss path: evict, refill, charge the penalty */
static unsigned handle_miss(Cache *c, uint16_t addr, uint16_t tag,
                            unsigned set, CacheEvent *ev)
{
    unsigned   way = pick_victim(c, set);
    CacheLine *l   = line_at(c, set, way);

    if (l->valid) {
        c->evictions++;
        if (ev) { ev->evicted = 1; ev->evicted_base = l->base;
                  ev->wrote_back = l->dirty; }
        writeback(c, set, way);
    }
    refill(c, set, way, addr, tag);
    c->stall_cycles += c->miss_penalty;
    if (ev) ev->stall = c->miss_penalty;
    return way;
}

/* LRU touches on every access; FIFO only on fill (already done in refill) */
static void touch(Cache *c, unsigned set, unsigned way) {
    if (c->repl == REPL_LRU) line_at(c, set, way)->stamp = ++c->clock;
}

static void ev_init(CacheEvent *ev, unsigned set, uint16_t tag) {
    if (!ev) return;
    ev->hit = 0; ev->set = set; ev->way = 0; ev->tag = tag;
    ev->stall = 0; ev->evicted = 0; ev->evicted_base = 0; ev->wrote_back = 0;
}

uint8_t cache_read(Cache *c, uint16_t addr, CacheEvent *ev) {
    uint16_t tag; unsigned set, off, w;

    cache_decode(c, addr, &tag, &set, &off);
    ev_init(ev, set, tag);
    c->reads++;

    for (w = 0; w < c->ways; w++) {
        CacheLine *l = line_at(c, set, w);
        if (l->valid && l->tag == tag) {
            c->read_hit++;
            touch(c, set, w);
            if (ev) { ev->hit = 1; ev->way = w; }
            return data_at(c, set, w)[off];
        }
    }
    c->read_miss++;
    w = handle_miss(c, addr, tag, set, ev);
    if (ev) ev->way = w;
    return data_at(c, set, w)[off];
}

void cache_write(Cache *c, uint16_t addr, uint8_t val, CacheEvent *ev) {
    uint16_t tag; unsigned set, off, w;
    int found = 0;

    cache_decode(c, addr, &tag, &set, &off);
    ev_init(ev, set, tag);
    c->writes++;

    for (w = 0; w < c->ways; w++) {
        CacheLine *l = line_at(c, set, w);
        if (l->valid && l->tag == tag) { found = 1; break; }
    }

    if (found) {
        c->write_hit++;
        touch(c, set, w);
        if (ev) { ev->hit = 1; ev->way = w; }
    } else {
        c->write_miss++;
        if (!c->write_alloc) {
            /* no-write-allocate: the store goes straight to memory and the
             * cache is left untouched.  Still costs the miss penalty. */
            c->bs_write(c->bs_ctx, addr, val);
            c->bytes_out++;
            c->stall_cycles += c->miss_penalty;
            if (ev) ev->stall = c->miss_penalty;
            return;
        }
        w = handle_miss(c, addr, tag, set, ev);
        if (ev) ev->way = w;
    }

    data_at(c, set, w)[off] = val;
    if (c->wpol == WPOL_THROUGH) {
        c->bs_write(c->bs_ctx, addr, val);
        c->bytes_out++;
    } else {
        line_at(c, set, w)->dirty = 1;
    }
}

void cache_clean(Cache *c) {
    unsigned s, w;
    for (s = 0; s < c->sets; s++)
        for (w = 0; w < c->ways; w++) writeback(c, s, w);
}
int cache_clean_addr(Cache *c, uint16_t addr) {
    uint16_t tag; unsigned set, w;
    cache_decode(c, addr, &tag, &set, NULL);
    for (w = 0; w < c->ways; w++) {
        CacheLine *l = line_at(c, set, w);
        if (l->valid && l->tag == tag) { writeback(c, set, w); return 1; }
    }
    return 0;
}
void cache_flush(Cache *c) {
    unsigned s, w;
    for (s = 0; s < c->sets; s++)
        for (w = 0; w < c->ways; w++) {
            writeback(c, s, w);
            line_at(c, s, w)->valid = 0;
        }
}
void cache_invalidate(Cache *c) {
    unsigned s, w;
    for (s = 0; s < c->sets; s++)
        for (w = 0; w < c->ways; w++) {
            CacheLine *l = line_at(c, s, w);
            l->valid = 0; l->dirty = 0;
        }
}

int cache_snoop(Cache *c, uint16_t addr) {
    uint16_t tag; unsigned set, w;
    cache_decode(c, addr, &tag, &set, NULL);
    for (w = 0; w < c->ways; w++) {
        CacheLine *l = line_at(c, set, w);
        if (l->valid && l->tag == tag) {
            writeback(c, set, w);
            l->valid = 0;
            c->invalidations++;
            return 1;
        }
    }
    return 0;
}

void cache_reset_stats(Cache *c) {
    c->reads = c->writes = 0;
    c->read_hit = c->read_miss = c->write_hit = c->write_miss = 0;
    c->evictions = c->writebacks = c->invalidations = 0;
    c->stall_cycles = c->bytes_in = c->bytes_out = 0;
}

double cache_hit_rate(const Cache *c) {
    uint64_t tot = c->reads + c->writes;
    if (!tot) return 0.0;
    return (double)(c->read_hit + c->write_hit) * 100.0 / (double)tot;
}
