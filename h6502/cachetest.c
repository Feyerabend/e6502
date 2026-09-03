/*
 * cachetest.c  --  unit tests for the cache model
 *
 * These check the mechanism itself: tag/index/offset decomposition, hit and
 * miss classification, LRU vs FIFO victim choice, write-back vs write-through,
 * write-allocate, snooping, and the traffic counters.  If a demo's hit rate
 * ever looks surprising, run this first: it says whether the surprise is in
 * the program or in the model.
 *
 *   cc -o cachetest cachetest.c cache.c && ./cachetest
 */
#include <stdio.h>
#include <string.h>
#include "cache.h"

static uint8_t MEM[0x10000];
static uint8_t bsr(void *ctx, uint16_t a)            { (void)ctx; return MEM[a]; }
static void    bsw(void *ctx, uint16_t a, uint8_t v) { (void)ctx; MEM[a] = v; }

static int failures, checks;

static void ck(int cond, const char *what) {
    checks++;
    if (!cond) { printf("  FAIL  %s\n", what); failures++; }
}
static void ck_eq(unsigned long long got, unsigned long long want, const char *what) {
    checks++;
    if (got != want) {
        printf("  FAIL  %s: got %llu, want %llu\n", what, got, want);
        failures++;
    }
}

static Cache C;
static void mk(unsigned size, unsigned line, unsigned ways,
               CacheRepl repl, CacheWPol wpol, int alloc) {
    const char *err;
    cache_free(&C);
    memset(&C, 0, sizeof C);
    C.repl = repl; C.wpol = wpol; C.write_alloc = alloc; C.miss_penalty = 10;
    if (cache_config(&C, "T$", size, line, ways, &err) < 0) {
        printf("  FAIL  cache_config(%u,%u,%u): %s\n", size, line, ways, err);
        failures++;
    }
    cache_attach(&C, bsr, bsw, NULL);
}

static void t_geometry(void) {
    const char *err;
    Cache c;
    printf("geometry\n");

    /* 256 B, 16 B lines, 2 ways -> 8 sets; offset 4 bits, index 3, tag 9 */
    mk(256, 16, 2, REPL_LRU, WPOL_BACK, 1);
    ck_eq(C.sets, 8, "sets");
    ck_eq(C.off_bits, 4, "offset bits");
    ck_eq(C.idx_bits, 3, "index bits");
    {
        uint16_t tag; unsigned set, off;
        /* $1234 = tag 0x24, set 3, offset 4 */
        cache_decode(&C, 0x1234u, &tag, &set, &off);
        ck_eq(tag, 0x1234u >> 7, "tag of $1234");
        ck_eq(set, (0x1234u >> 4) & 7u, "set of $1234");
        ck_eq(off, 4, "offset of $1234");
    }

    /* direct-mapped: ways == 1 */
    mk(256, 16, 1, REPL_LRU, WPOL_BACK, 1);
    ck_eq(C.sets, 16, "direct-mapped sets");

    /* fully associative: one set */
    mk(256, 16, 16, REPL_LRU, WPOL_BACK, 1);
    ck_eq(C.sets, 1, "fully associative sets");
    ck_eq(C.idx_bits, 0, "fully associative index bits");

    /* rejected geometries leave *err set */
    memset(&c, 0, sizeof c);
    ck(cache_config(&c, "X$", 256, 24, 2, &err) < 0, "non-power-of-two line rejected");
    ck(cache_config(&c, "X$", 100, 16, 2, &err) < 0, "non-integral set count rejected");
    ck(cache_config(&c, "X$",   8, 16, 2, &err) < 0, "cache smaller than a set rejected");
    cache_free(&c);
}

static void t_hit_miss(void) {
    CacheEvent ev;
    unsigned i;
    printf("hits and misses\n");

    for (i = 0; i < 0x100; i++) MEM[0x2000 + i] = (uint8_t)i;
    mk(256, 16, 2, REPL_LRU, WPOL_BACK, 1);

    ck_eq(cache_read(&C, 0x2000u, &ev), 0x00, "value on cold miss");
    ck(!ev.hit, "first touch is a miss");
    ck_eq(ev.stall, 10, "miss costs the penalty");

    /* the other 15 bytes of that line are now free */
    for (i = 1; i < 16; i++) { cache_read(&C, (uint16_t)(0x2000 + i), &ev);
                               ck(ev.hit, "rest of the line hits"); }
    ck_eq(C.read_miss, 1, "one miss for a 16-byte line");
    ck_eq(C.read_hit, 15, "fifteen hits");
    ck_eq(C.bytes_in, 16, "one line fetched");
    ck_eq(C.stall_cycles, 10, "one penalty charged");

    /* crossing into the next line misses again */
    cache_read(&C, 0x2010u, &ev);
    ck(!ev.hit, "next line misses");
}

static void t_replacement(void) {
    CacheEvent ev;
    printf("replacement policy\n");

    /* 2 ways, 1 set (fully associative, 2 lines of 16 B) */
    mk(32, 16, 2, REPL_LRU, WPOL_BACK, 1);
    cache_read(&C, 0x1000u, &ev);      /* way A */
    cache_read(&C, 0x2000u, &ev);      /* way B */
    cache_read(&C, 0x1000u, &ev);      /* touch A: B is now least recent */
    ck(ev.hit, "A still resident");
    cache_read(&C, 0x3000u, &ev);      /* evicts B under LRU */
    ck(cache_probe(&C, 0x1000u, NULL), "LRU kept the recently used line");
    ck(!cache_probe(&C, 0x2000u, NULL), "LRU evicted the least recently used line");

    /* FIFO ignores the re-touch and evicts the oldest fill */
    mk(32, 16, 2, REPL_FIFO, WPOL_BACK, 1);
    cache_read(&C, 0x1000u, &ev);
    cache_read(&C, 0x2000u, &ev);
    cache_read(&C, 0x1000u, &ev);
    ck(ev.hit, "A still resident (FIFO)");
    cache_read(&C, 0x3000u, &ev);
    ck(!cache_probe(&C, 0x1000u, NULL), "FIFO evicted the oldest fill, re-touch or not");
    ck(cache_probe(&C, 0x2000u, NULL),  "FIFO kept the newer fill");
}

static void t_conflict(void) {
    CacheEvent ev;
    int i;
    printf("conflict misses and associativity\n");

    /* direct-mapped, 8 sets of 16 B: $2000 and $2080 collide */
    mk(128, 16, 1, REPL_LRU, WPOL_BACK, 1);
    for (i = 0; i < 10; i++) { cache_read(&C, 0x2000u, &ev); cache_read(&C, 0x2080u, &ev); }
    ck_eq(C.read_hit, 0, "direct-mapped: two colliding streams never hit");
    ck_eq(C.read_miss, 20, "...and always miss");

    /* same capacity, 2 ways: both streams fit */
    mk(128, 16, 2, REPL_LRU, WPOL_BACK, 1);
    for (i = 0; i < 10; i++) { cache_read(&C, 0x2000u, &ev); cache_read(&C, 0x2080u, &ev); }
    ck_eq(C.read_miss, 2, "2-way: two cold misses and nothing else");
    ck_eq(C.read_hit, 18, "2-way: everything else hits");

    /* a third stream on the same set defeats 2 ways again */
    mk(128, 16, 2, REPL_LRU, WPOL_BACK, 1);
    for (i = 0; i < 10; i++) {
        cache_read(&C, 0x2000u, &ev);
        cache_read(&C, 0x2080u, &ev);
        cache_read(&C, 0x2100u, &ev);
    }
    ck_eq(C.read_hit, 0, "three streams, two ways: LRU evicts what you need next");
}

static void t_write_policy(void) {
    CacheEvent ev;
    printf("write policy\n");

    /* write-back: memory is not updated until the line is evicted */
    MEM[0x3000] = 0x11;
    mk(32, 16, 1, REPL_LRU, WPOL_BACK, 1);
    cache_write(&C, 0x3000u, 0x99, &ev);
    ck(!ev.hit, "write miss");
    ck_eq(C.write_miss, 1, "counted as a write miss");
    ck_eq(C.bytes_in, 16, "write-allocate fetched the line first");
    ck_eq(MEM[0x3000], 0x11, "write-back: memory still holds the old byte");
    ck_eq(cache_read(&C, 0x3000u, &ev), 0x99, "cache holds the new byte");
    /* 32 B / 16 B lines / 1 way = 2 sets, so the colliding address is +32 */
    cache_read(&C, 0x3020u, &ev);      /* same set, evicts the dirty line */
    ck_eq(MEM[0x3000], 0x99, "eviction wrote the dirty line back");
    ck_eq(C.writebacks, 1, "one write-back");

    /* write-through: memory is updated immediately, nothing is ever dirty */
    MEM[0x4000] = 0x11;
    mk(32, 16, 1, REPL_LRU, WPOL_THROUGH, 1);
    cache_write(&C, 0x4000u, 0x99, &ev);
    ck_eq(MEM[0x4000], 0x99, "write-through reached memory at once");
    cache_read(&C, 0x4020u, &ev);
    ck_eq(C.writebacks, 0, "write-through never writes back");

    /* no-write-allocate: a write miss does not pull the line in */
    MEM[0x5000] = 0x11;
    mk(32, 16, 1, REPL_LRU, WPOL_BACK, 0);
    cache_write(&C, 0x5000u, 0x99, &ev);
    ck_eq(MEM[0x5000], 0x99, "no-write-allocate stored straight to memory");
    ck(!cache_probe(&C, 0x5000u, NULL), "...and left the cache alone");
    ck_eq(C.bytes_in, 0, "no line was fetched");
}

static void t_maintenance(void) {
    CacheEvent ev;
    printf("flush, clean and snoop\n");

    MEM[0x6000] = 0x11;
    mk(32, 16, 1, REPL_LRU, WPOL_BACK, 1);
    cache_write(&C, 0x6000u, 0x99, &ev);
    cache_clean(&C);
    ck_eq(MEM[0x6000], 0x99, "clean pushed the dirty byte to memory");
    ck(cache_probe(&C, 0x6000u, NULL), "clean kept the line resident");

    cache_write(&C, 0x6000u, 0xAA, &ev);
    cache_flush(&C);
    ck_eq(MEM[0x6000], 0xAA, "flush wrote back");
    ck(!cache_probe(&C, 0x6000u, NULL), "flush invalidated");

    /* snoop drops exactly the line covering the address */
    cache_read(&C, 0x6000u, &ev);
    ck(cache_snoop(&C, 0x6005u), "snoop found the line covering $6005");
    ck(!cache_probe(&C, 0x6000u, NULL), "snoop invalidated it");
    ck(!cache_snoop(&C, 0x6005u), "snooping an absent line reports nothing");
    ck_eq(C.invalidations, 1, "one invalidation counted");
}

static void t_stats(void) {
    CacheEvent ev;
    printf("statistics\n");
    mk(256, 16, 2, REPL_LRU, WPOL_BACK, 1);
    cache_read(&C, 0x7000u, &ev);          /* miss */
    cache_read(&C, 0x7001u, &ev);          /* hit  */
    cache_read(&C, 0x7002u, &ev);          /* hit  */
    cache_read(&C, 0x7003u, &ev);          /* hit  */
    ck(cache_hit_rate(&C) > 74.9 && cache_hit_rate(&C) < 75.1, "hit rate is 75%");
    cache_reset_stats(&C);
    ck_eq(C.reads, 0, "stats cleared");
    ck(cache_probe(&C, 0x7000u, NULL), "clearing stats does not clear the cache");
}

int main(void) {
    t_geometry();
    t_hit_miss();
    t_replacement();
    t_conflict();
    t_write_policy();
    t_maintenance();
    t_stats();
    cache_free(&C);
    printf("---- %d checks, %d failed ----\n", checks, failures);
    return failures ? 1 : 0;
}
