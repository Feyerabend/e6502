/*
 * cache.h  --  a configurable set-associative cache
 *
 * One structure serves as instruction cache, data cache, or unified cache.
 * Everything a textbook lets you vary is a parameter here: capacity,
 * line size, associativity, replacement policy, write policy, and the
 * miss penalty.  The point is to let you change one knob at a time and
 * watch the hit rate move.
 *
 * Address decomposition (16-bit 6502 address):
 *
 *      15                              0
 *     +----------------+-------+--------+
 *     |      tag       | index | offset |
 *     +----------------+-------+--------+
 *
 *   offset  selects a byte within a line   (log2 line_bytes bits)
 *   index   selects the set                (log2 sets bits)
 *   tag     the rest -- stored alongside the line to identify it
 *
 * ANSI-C-friendly C99: no VLAs, no designated initialisers, declarations
 * at the top of each block.
 */
#ifndef H6502_CACHE_H
#define H6502_CACHE_H

#include <stdint.h>

typedef enum { REPL_LRU = 0, REPL_FIFO, REPL_RANDOM } CacheRepl;
typedef enum { WPOL_BACK = 0, WPOL_THROUGH }          CacheWPol;

#define CACHE_MAX_LINES 4096

typedef struct {
    uint16_t tag;
    uint8_t  valid;
    uint8_t  dirty;
    uint32_t stamp;      /* LRU: last touch.  FIFO: fill time. */
    uint16_t base;       /* address of byte 0 of this line (cached for dumps) */
} CacheLine;

/* backing store callbacks -- how the cache refills and writes back */
typedef uint8_t (*cache_rd_fn)(void *ctx, uint16_t addr);
typedef void    (*cache_wr_fn)(void *ctx, uint16_t addr, uint8_t val);

typedef struct {
    char      name[4];       /* "I$", "D$", "U$" -- for messages */

    /* geometry */
    unsigned  line_bytes;    /* power of two, 1..256                */
    unsigned  ways;          /* 1 = direct-mapped, sets = 1 => full */
    unsigned  sets;
    unsigned  capacity;      /* line_bytes * ways * sets            */
    unsigned  off_bits, idx_bits;

    /* policy */
    CacheRepl repl;
    CacheWPol wpol;
    int       write_alloc;   /* 1 = fetch line on a write miss      */
    unsigned  miss_penalty;  /* stall cycles charged on a miss      */

    /* state */
    CacheLine line[CACHE_MAX_LINES];
    uint8_t  *store;                 /* capacity bytes, owned       */
    uint32_t  clock;

    /* backing store */
    cache_rd_fn bs_read;
    cache_wr_fn bs_write;
    void       *bs_ctx;

    /* statistics */
    uint64_t reads, writes;
    uint64_t read_hit, read_miss, write_hit, write_miss;
    uint64_t evictions, writebacks, invalidations;
    uint64_t stall_cycles;
    uint64_t bytes_in, bytes_out;    /* traffic to/from backing store */
} Cache;

/* what happened on the last access -- filled in for the trace display */
typedef struct {
    int      hit;
    unsigned set;
    unsigned way;
    uint16_t tag;
    unsigned stall;
    int      evicted;        /* a valid line was displaced          */
    uint16_t evicted_base;
    int      wrote_back;     /* ...and it was dirty                 */
} CacheEvent;

/* Configure/allocate.  size_bytes, line_bytes and ways must make a whole
 * number of sets; returns 0 on success, -1 with *err set on bad geometry. */
int  cache_config(Cache *c, const char *name,
                  unsigned size_bytes, unsigned line_bytes, unsigned ways,
                  const char **err);
void cache_attach(Cache *c, cache_rd_fn rd, cache_wr_fn wr, void *ctx);
void cache_free  (Cache *c);

uint8_t cache_read (Cache *c, uint16_t addr, CacheEvent *ev);
void    cache_write(Cache *c, uint16_t addr, uint8_t val, CacheEvent *ev);

void cache_clean     (Cache *c);   /* write back dirty lines, keep them resident */
int  cache_clean_addr(Cache *c, uint16_t addr);  /* ...just the line covering addr */
void cache_flush     (Cache *c);   /* write back dirty lines, invalidate all */
void cache_invalidate(Cache *c);   /* drop everything, dirty data included   */
/* snoop: drop the line covering addr (writing it back first).  Returns 1 if
 * a line was actually present.  This is the coherence hook. */
int  cache_snoop     (Cache *c, uint16_t addr);

void cache_reset_stats(Cache *c);

/* address decomposition, for the `map` command */
void cache_decode(const Cache *c, uint16_t addr,
                  uint16_t *tag, unsigned *set, unsigned *off);
/* is addr resident?  fills *way if so. */
int  cache_probe(const Cache *c, uint16_t addr, unsigned *way);

double cache_hit_rate(const Cache *c);

#endif /* H6502_CACHE_H */
