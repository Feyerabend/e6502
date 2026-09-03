/*
 * hmon.c  --  h6502: a 6502 with a memory hierarchy you can see
 *
 * The m6502 emulator models a 6502 with flat, infinitely fast memory: every
 * access costs nothing and every byte is reachable from every instruction.
 * That is a fine model of a 1975 machine and a useless model of any machine
 * built since.  h6502 keeps the same CPU core and replaces the memory with
 * something you can misconfigure: two address spaces, split or unified
 * caches, and a miss penalty.
 *
 * Device page (uncacheable in every model):
 *
 *   $F001  write  character out
 *   $F002  read   $FF if a character is waiting
 *   $F003  read   next character in
 *   $F004  read   $FF if Ctrl-C pending (read clears)
 *   $F0FC  write  clean the data cache: push dirty lines out to memory
 *   $F0FD  write  invalidate the instruction cache
 *
 * Those last two are this machine's cache-maintenance instructions.  They come
 * in that order for the same reason ARM's do (DC CVAU then IC IVAU): with a
 * write-back data cache, invalidating I$ first only refills it from a main
 * memory that has not received the store yet.
 *   $F0FE  write  reset cache statistics  (mark start of region of interest)
 *   $F0FF  write  halt the machine
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>
#include <termios.h>
#include <sys/select.h>
#include <unistd.h>

#include "../m6502/m6502.h"
#include "cache.h"
#include "memsys.h"

static M6502  cpu;
static MemSys ms;
static int    halted;

/* ------------------------------------------------------------------ *
 * Console
 * ------------------------------------------------------------------ */
static int    tty_raw;
static struct termios saved_term;
static int    io_staged = -1;
static volatile sig_atomic_t break_pending = 0;

static void on_sigint(int sig) { (void)sig; break_pending = 1; }

static void tty_restore(void) {
    if (tty_raw) { tcsetattr(STDIN_FILENO, TCSANOW, &saved_term); tty_raw = 0; }
}
static void tty_setup(void) {
    struct termios t;
    if (!isatty(STDIN_FILENO)) return;
    if (tcgetattr(STDIN_FILENO, &saved_term)) return;
    t = saved_term;
    t.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
    t.c_cc[VMIN] = 1; t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0) { tty_raw = 1; atexit(tty_restore); }
}
static int io_peek(void) {
    fd_set fds; struct timeval tv; char ch;
    if (io_staged >= 0) return 1;
    FD_ZERO(&fds); FD_SET(STDIN_FILENO, &fds);
    tv.tv_sec = 0; tv.tv_usec = 0;
    if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0)
        if (read(STDIN_FILENO, &ch, 1) == 1) { io_staged = (unsigned char)ch; return 1; }
    return 0;
}
static uint8_t io_getc(void) {
    char ch;
    if (io_staged >= 0) { uint8_t v = (uint8_t)io_staged; io_staged = -1; return v; }
    return (read(STDIN_FILENO, &ch, 1) == 1) ? (uint8_t)ch : 0;
}

/* the device page, called from memsys.c */
uint8_t h_io_read(uint16_t addr, int *handled) {
    *handled = 1;
    switch (addr) {
        case 0xF002u: return io_peek() ? 0xFF : 0x00;
        case 0xF003u: return io_getc();
        case 0xF004u: { uint8_t v = break_pending ? 0xFF : 0x00;
                        break_pending = 0; return v; }
        default: *handled = 0; return 0;
    }
}
void h_io_write(uint16_t addr, uint8_t val, int *handled) {
    *handled = 1;
    switch (addr) {
        case 0xF001u: putchar(val); fflush(stdout); return;
        case 0xF0FCu: ms_clean(&ms); return;         /* clean D$      */
        case 0xF0FDu: ms_flush(&ms, 1, 0); return;   /* invalidate I$ */
        case 0xF0FEu: ms_reset_stats(&ms); cpu.cycles = 0; return;
        case 0xF0FFu: halted = 1; return;
        default: *handled = 0; return;
    }
}

/* ------------------------------------------------------------------ *
 * Small helpers
 * ------------------------------------------------------------------ */
static long parse_num(const char *s, int *ok) {
    char *end; long v;
    if (ok) *ok = 0;
    if (!s || !*s) return 0;
    if (*s == '$') v = strtol(s + 1, &end, 16);
    else if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) v = strtol(s + 2, &end, 16);
    else if (*s == '#') v = strtol(s + 1, &end, 10);
    else v = strtol(s, &end, 16);          /* monitor default: hex */
    if (end == s || *end) return 0;
    if (ok) *ok = 1;
    return v;
}
static char *tok(char **p) {
    char *s = *p, *start;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) { *p = s; return NULL; }
    start = s;
    while (*s && *s != ' ' && *s != '\t') s++;
    if (*s) *s++ = '\0';
    *p = s;
    return start;
}
static int eqi(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *b) { if (tolower((unsigned char)*a++) != tolower((unsigned char)*b++)) return 0; }
    return !*a && !*b;
}

/* ------------------------------------------------------------------ *
 * Breakpoints
 * ------------------------------------------------------------------ */
#define MAX_BP 8
static uint16_t bp[MAX_BP];
static int      n_bp;

static int is_bp(uint16_t a) {
    int i; for (i = 0; i < n_bp; i++) if (bp[i] == a) return 1; return 0;
}

/* ------------------------------------------------------------------ *
 * Display
 * ------------------------------------------------------------------ */
static void show_regs(void) {
    uint8_t p = m6502_getP(&cpu);
    char f[9];
    const char *names = "NV-BDIZC";
    int i;
    for (i = 0; i < 8; i++) f[i] = (p & (0x80u >> i)) ? names[i] : '.';
    f[8] = '\0';
    printf("PC=$%04X A=$%02X X=$%02X Y=$%02X SP=$%02X P=$%02X [%s]\n",
           cpu.pc, cpu.a, cpu.x, cpu.y, cpu.sp, p, f);
    printf("cycles=%llu  stall=%llu  total=%llu\n",
           (unsigned long long)cpu.cycles,
           (unsigned long long)ms_stall_cycles(&ms),
           (unsigned long long)(cpu.cycles + ms_stall_cycles(&ms)));
}

static void disasm(uint16_t addr, int n) {
    char buf[48];
    int i;
    for (i = 0; i < n; i++) {
        int len = m6502_disasm(ms_peek_code, &ms, addr, buf, sizeof buf);
        printf("%c%c $%04X  %s\n",
               addr == cpu.pc ? '>' : ' ', is_bp(addr) ? '*' : ' ', addr, buf);
        addr = (uint16_t)(addr + len);
    }
}

static void dump(MemSide side, uint16_t lo, uint16_t hi) {
    uint32_t a;
    for (a = lo & 0xfff0u; a <= hi; a += 16) {
        int i;
        printf("$%04X ", (unsigned)a);
        for (i = 0; i < 16; i++) printf(" %02X", ms_peek(&ms, side, (uint16_t)(a + i)));
        printf("  ");
        for (i = 0; i < 16; i++) {
            uint8_t v = ms_peek(&ms, side, (uint16_t)(a + i));
            putchar(isprint(v) ? v : '.');
        }
        putchar('\n');
        if (a + 16 > 0xffffu) break;
    }
}

/* ------------------------------------------------------------------ *
 * Cache reporting
 * ------------------------------------------------------------------ */
static const char *repl_name(CacheRepl r) {
    return r == REPL_LRU ? "LRU" : r == REPL_FIFO ? "FIFO" : "random";
}
static void show_cache_config(const Cache *c) {
    printf("  %-3s %5u B = %u sets x %u ways x %u B/line   tag %u : index %u : offset %u bits\n",
           c->name, c->capacity, c->sets, c->ways, c->line_bytes,
           16 - c->off_bits - c->idx_bits, c->idx_bits, c->off_bits);
    printf("      %s replacement, write-%s, %s-allocate, miss penalty %u cycles\n",
           repl_name(c->repl),
           c->wpol == WPOL_BACK ? "back" : "through",
           c->write_alloc ? "write" : "no-write",
           c->miss_penalty);
}

static void show_config(void) {
    printf("model: %s\n", ms_mode_name(ms.mode));
    printf("caches: %s", ms.caches_on ? "on" : "OFF (every access goes to memory)");
    if (ms.mode == MODE_MODIFIED)
        printf(", I$ snooping %s", ms.snoop ? "on" : "off");
    putchar('\n');
    if (!ms.caches_on) return;
    if (ms.mode == MODE_VONNEUMANN) show_cache_config(&ms.cu);
    else { show_cache_config(&ms.ci); show_cache_config(&ms.cd); }
}

static void show_cache_stats(const Cache *c) {
    uint64_t tot = c->reads + c->writes;
    printf("  %-3s %8llu acc  %8llu hit  %8llu miss   hit rate %6.2f%%\n",
           c->name, (unsigned long long)tot,
           (unsigned long long)(c->read_hit + c->write_hit),
           (unsigned long long)(c->read_miss + c->write_miss),
           cache_hit_rate(c));
    printf("      reads  %8llu (%llu hit / %llu miss)   writes %8llu (%llu hit / %llu miss)\n",
           (unsigned long long)c->reads, (unsigned long long)c->read_hit,
           (unsigned long long)c->read_miss, (unsigned long long)c->writes,
           (unsigned long long)c->write_hit, (unsigned long long)c->write_miss);
    printf("      evictions %llu (%llu dirty)  stall %llu cyc  traffic in %llu B / out %llu B\n",
           (unsigned long long)c->evictions, (unsigned long long)c->writebacks,
           (unsigned long long)c->stall_cycles,
           (unsigned long long)c->bytes_in, (unsigned long long)c->bytes_out);
    if (c->invalidations)
        printf("      snoop invalidations %llu\n", (unsigned long long)c->invalidations);
}

static void show_stats(void) {
    uint64_t bus = ms.n_code + ms.n_data;
    uint64_t stall = ms_stall_cycles(&ms);
    unsigned i;

    printf("model: %s\n", ms_mode_name(ms.mode));
    printf("bus accesses %llu   instruction side %llu (%.1f%%)   data side %llu (%.1f%%)"
           "   uncached %llu\n",
           (unsigned long long)bus,
           (unsigned long long)ms.n_code, bus ? 100.0 * (double)ms.n_code / (double)bus : 0.0,
           (unsigned long long)ms.n_data, bus ? 100.0 * (double)ms.n_data / (double)bus : 0.0,
           (unsigned long long)ms.n_uncached);
    printf("  by kind: ");
    for (i = 0; i < 6; i++)
        printf("%s=%llu%s", ms_kind_name(i), (unsigned long long)ms.n_kind[i],
               i == 5 ? "\n" : "  ");

    if (ms.caches_on) {
        if (ms.mode == MODE_VONNEUMANN) show_cache_stats(&ms.cu);
        else { show_cache_stats(&ms.ci); show_cache_stats(&ms.cd); }
    } else {
        printf("  (caches off -- nothing to report)\n");
    }

    printf("cycles: cpu %llu + stall %llu = %llu",
           (unsigned long long)cpu.cycles, (unsigned long long)stall,
           (unsigned long long)(cpu.cycles + stall));
    if (cpu.cycles)
        printf("   (%.2fx the ideal-memory time)",
               (double)(cpu.cycles + stall) / (double)cpu.cycles);
    putchar('\n');
    if (bus) {
        /* average memory access time, in stall cycles per access */
        printf("AMAT: %.3f stall cycles per bus access\n",
               (double)stall / (double)bus);
    }
    if (ms.code_known)
        printf("stores into the program image ($%04X-$%04X): %llu\n",
               ms.code_lo, ms.code_hi, (unsigned long long)ms.code_stores);
    if (ms.stale_writes)
        printf("STALE: %llu store(s) landed in D$ while I$ held the same line\n",
               (unsigned long long)ms.stale_writes);
}

static void dump_cache(const Cache *c, long only_set) {
    unsigned s, w;
    printf("%s  %u sets x %u ways x %uB\n", c->name, c->sets, c->ways, c->line_bytes);
    for (s = 0; s < c->sets; s++) {
        if (only_set >= 0 && (unsigned)only_set != s) continue;
        printf(" set %2u |", s);
        for (w = 0; w < c->ways; w++) {
            const CacheLine *l = &c->line[s * c->ways + w];
            if (!l->valid) printf("   ---------  ");
            else printf("  $%04X%s a=%-4u", l->base, l->dirty ? "*" : " ", l->stamp);
        }
        putchar('\n');
    }
    printf(" (base address of the resident line; * = dirty; a = age stamp)\n");
}

static void dump_sets(const Cache *c) {
    unsigned s, w, max = 0;
    unsigned occ[CACHE_MAX_LINES];
    printf("%s set occupancy\n", c->name);
    for (s = 0; s < c->sets; s++) {
        unsigned n = 0;
        for (w = 0; w < c->ways; w++) if (c->line[s * c->ways + w].valid) n++;
        occ[s] = n; if (n > max) max = n;
    }
    for (s = 0; s < c->sets; s++) {
        unsigned i;
        printf(" %3u |", s);
        for (i = 0; i < c->ways; i++) putchar(i < occ[s] ? '#' : '.');
        printf("| %u/%u\n", occ[s], c->ways);
    }
    (void)max;
}

static void show_map(uint16_t addr) {
    Cache *cs[3]; int n = 0, i;
    if (ms.mode == MODE_VONNEUMANN) cs[n++] = &ms.cu;
    else { cs[n++] = &ms.ci; cs[n++] = &ms.cd; }
    printf("address $%04X = %%%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c\n", addr,
           (addr>>15&1)+'0',(addr>>14&1)+'0',(addr>>13&1)+'0',(addr>>12&1)+'0',
           (addr>>11&1)+'0',(addr>>10&1)+'0',(addr>> 9&1)+'0',(addr>> 8&1)+'0',
           (addr>> 7&1)+'0',(addr>> 6&1)+'0',(addr>> 5&1)+'0',(addr>> 4&1)+'0',
           (addr>> 3&1)+'0',(addr>> 2&1)+'0',(addr>> 1&1)+'0',(addr    &1)+'0');
    for (i = 0; i < n; i++) {
        Cache *c = cs[i];
        uint16_t tag; unsigned set, off, way;
        int here = cache_probe(c, addr, &way);
        cache_decode(c, addr, &tag, &set, &off);
        printf("  %-3s tag $%03X | set %u | offset %u    -> %s",
               c->name, tag, set, off,
               here ? "RESIDENT" : "not resident");
        if (here) printf(" in way %u", way);
        putchar('\n');
        printf("      addresses that collide with it: $%04X, $%04X, $%04X, ... "
               "(every %u bytes)\n",
               (unsigned)((set << c->off_bits)),
               (unsigned)((set << c->off_bits) + (c->sets << c->off_bits)),
               (unsigned)((set << c->off_bits) + 2 * (c->sets << c->off_bits)),
               (unsigned)(c->sets << c->off_bits));
    }
}

/* ------------------------------------------------------------------ *
 * config command
 * ------------------------------------------------------------------ */
static void reconfig(Cache *c, unsigned size, unsigned line, unsigned ways) {
    const char *err;
    Cache tmp = *c;
    if (cache_config(c, c->name, size, line, ways, &err) < 0) {
        printf("config: %s (unchanged)\n", err);
        *c = tmp;
        return;
    }
    show_cache_config(c);
}

static void cmd_config(char *rest) {
    Cache *targets[3]; int n = 0, i;
    char *what = tok(&rest);
    unsigned size, line, ways;
    int geom_changed = 0;

    if (!what) { show_config(); return; }
    if      (eqi(what, "i")) targets[n++] = &ms.ci;
    else if (eqi(what, "d")) targets[n++] = &ms.cd;
    else if (eqi(what, "u")) targets[n++] = &ms.cu;
    else if (eqi(what, "all")) { targets[n++] = &ms.ci; targets[n++] = &ms.cd; targets[n++] = &ms.cu; }
    else { printf("config <i|d|u|all> [size=N] [line=N] [ways=N] [repl=lru|fifo|rand]"
                  " [write=wb|wt] [alloc=0|1] [penalty=N]\n"); return; }

    for (i = 0; i < n; i++) {
        Cache *c = targets[i];
        char *save = rest, *kv;
        size = c->capacity; line = c->line_bytes; ways = c->ways;
        geom_changed = 0;
        while ((kv = tok(&rest)) != NULL) {
            char *eq = strchr(kv, '=');
            char *v;
            if (!eq) { printf("config: expected key=value, got '%s'\n", kv); break; }
            *eq = '\0'; v = eq + 1;
            if      (eqi(kv, "size"))    { size = (unsigned)strtoul(v, NULL, 0); geom_changed = 1; }
            else if (eqi(kv, "line"))    { line = (unsigned)strtoul(v, NULL, 0); geom_changed = 1; }
            else if (eqi(kv, "ways"))    { ways = (unsigned)strtoul(v, NULL, 0); geom_changed = 1; }
            else if (eqi(kv, "penalty")) c->miss_penalty = (unsigned)strtoul(v, NULL, 0);
            else if (eqi(kv, "alloc"))   c->write_alloc = atoi(v) != 0;
            else if (eqi(kv, "repl")) {
                if (eqi(v, "lru")) c->repl = REPL_LRU;
                else if (eqi(v, "fifo")) c->repl = REPL_FIFO;
                else if (eqi(v, "rand") || eqi(v, "random")) c->repl = REPL_RANDOM;
                else printf("config: repl must be lru, fifo or rand\n");
            }
            else if (eqi(kv, "write")) {
                if (eqi(v, "wb") || eqi(v, "back")) c->wpol = WPOL_BACK;
                else if (eqi(v, "wt") || eqi(v, "through")) c->wpol = WPOL_THROUGH;
                else printf("config: write must be wb or wt\n");
            }
            else printf("config: unknown key '%s'\n", kv);
            *eq = '=';   /* restore so the next target parses the same string */
        }
        rest = save;
        if (geom_changed) reconfig(c, size, line, ways);
        else show_cache_config(c);
    }
}

/* ------------------------------------------------------------------ *
 * Loading
 * ------------------------------------------------------------------ */
static int load_file(const char *path, uint16_t at, int to_i, int to_d) {
    FILE *f = fopen(path, "rb");
    long sz;
    uint8_t *buf;
    if (!f) { printf("cannot open %s\n", path); return -1; }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz <= 0 || (long)at + sz > 0x10000L) {
        printf("bad size %ld for load at $%04X\n", sz, at); fclose(f); return -1;
    }
    buf = (uint8_t *)malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        printf("read error\n"); free(buf); fclose(f); return -1;
    }
    fclose(f);
    if (to_i) memcpy(ms.imem + at, buf, (size_t)sz);
    if (to_d) memcpy(ms.dmem + at, buf, (size_t)sz);
    free(buf);

    ms.code_lo = at; ms.code_hi = (uint16_t)(at + sz - 1); ms.code_known = 1;
    printf("loaded %ld bytes at $%04X into %s%s%s\n", sz, at,
           to_i ? "I-space" : "", (to_i && to_d) ? " and " : "", to_d ? "D-space" : "");
    if (ms.mode == MODE_HARVARD && to_i && to_d)
        printf("  (mirrored into both, the way a Harvard toolchain copies .data "
               "from ROM to RAM at startup)\n");
    return 0;
}

/* ------------------------------------------------------------------ *
 * Running
 * ------------------------------------------------------------------ */
static void run(long max_steps) {
    long i;
    halted = 0;
    for (i = 0; max_steps < 0 || i < max_steps; i++) {
        if (break_pending && !ms.trace) { /* let the program see it via $F004 */ }
        m6502_step(&cpu);
        if (halted) { printf("\n[halted at $%04X]\n", cpu.pc); return; }
        if (is_bp(cpu.pc)) { printf("\n[breakpoint $%04X]\n", cpu.pc); return; }
    }
}

/* ------------------------------------------------------------------ *
 * Help
 * ------------------------------------------------------------------ */
static void help(void) {
    puts(
"CPU / memory\n"
"  s [n]                step n instructions (default 1)\n"
"  c | run              run until halt ($F0FF) or breakpoint\n"
"  g <addr>             set PC, then run\n"
"  r                    registers, cycles and stall cycles\n"
"  d [addr] [n]         disassemble from I-space\n"
"  m  [lo] [hi]         dump data space\n"
"  mi [lo] [hi]         dump instruction space\n"
"  e  <addr> <b>...     write bytes into data space\n"
"  ei <addr> <b>...     write bytes into instruction space\n"
"  load <f> [addr] [i|d|both]   default $0800, both spaces\n"
"  b [addr] / bc <addr> breakpoints\n"
"  reset                reset CPU (reads $FFFC from I-space)\n"
"\n"
"Memory model\n"
"  mode [vn|harvard|mod]        pick the architecture\n"
"  cache [on|off]               bypass the caches entirely\n"
"  config <i|d|u|all> k=v ...   size= line= ways= repl= write= alloc= penalty=\n"
"  snoop [on|off]               modified Harvard: D-writes invalidate I$\n"
"  warn [on|off]                narrate stale-line coherence violations\n"
"  flush [i|d|all]              write back + invalidate\n"
"  clean                        write back dirty data lines, keep them resident\n"
"\n"
"Observation\n"
"  stats                cache and bus statistics\n"
"  zero                 reset statistics (not memory)\n"
"  ci | cd | cu [set]   dump cache contents\n"
"  sets <i|d|u>         set-occupancy map\n"
"  map <addr>           tag/index/offset breakdown and what collides with it\n"
"  trace [on|off|N]     print every bus access (N = limit)\n"
"\n"
"  q                    quit          h | ?   this help\n"
"Numbers are hex by default; $ or 0x also hex, # decimal.");
}

/* ------------------------------------------------------------------ *
 * Monitor loop
 * ------------------------------------------------------------------ */
static uint16_t last_dis, last_dump;

static int do_command(char *line) {
    char *rest = line;
    char *cmd  = tok(&rest);
    int ok;

    if (!cmd) return 0;

    if (eqi(cmd, "q") || eqi(cmd, "quit")) return 1;
    if (eqi(cmd, "h") || eqi(cmd, "?") || eqi(cmd, "help")) { help(); return 0; }

    if (eqi(cmd, "r")) { show_regs(); return 0; }
    if (eqi(cmd, "s")) {
        char *a = tok(&rest); long n = a ? parse_num(a, &ok) : 1;
        if (n < 1) n = 1;
        while (n-- > 0) {
            char buf[48];
            m6502_disasm(ms_peek_code, &ms, cpu.pc, buf, sizeof buf);
            /* with the bus trace on, the accesses this instruction makes are
             * printed between these two lines -- that is the point of it */
            printf("%-24s%s", buf, ms.trace ? "\n" : "");
            m6502_step(&cpu);
            printf("  -> A=$%02X X=$%02X Y=$%02X SP=$%02X\n", cpu.a, cpu.x, cpu.y, cpu.sp);
            if (halted) { printf("[halted]\n"); break; }
        }
        return 0;
    }
    if (eqi(cmd, "c") || eqi(cmd, "run")) { run(-1); return 0; }
    if (eqi(cmd, "g")) {
        char *a = tok(&rest);
        if (a) { long v = parse_num(a, &ok); if (ok) cpu.pc = (uint16_t)v; }
        run(-1); return 0;
    }
    if (eqi(cmd, "reset")) { m6502_reset(&cpu); show_regs(); return 0; }

    if (eqi(cmd, "d")) {
        char *a = tok(&rest), *b = tok(&rest);
        uint16_t at = a ? (uint16_t)parse_num(a, &ok) : (last_dis ? last_dis : cpu.pc);
        int n = b ? (int)parse_num(b, &ok) : 10;
        disasm(at, n > 0 ? n : 10);
        last_dis = (uint16_t)(at + 3 * n);
        return 0;
    }
    if (eqi(cmd, "m") || eqi(cmd, "mi")) {
        MemSide side = eqi(cmd, "mi") ? SIDE_CODE : SIDE_DATA;
        char *a = tok(&rest), *b = tok(&rest);
        uint16_t lo = a ? (uint16_t)parse_num(a, &ok) : last_dump;
        uint16_t hi = b ? (uint16_t)parse_num(b, &ok) : (uint16_t)(lo + 0x7f);
        dump(side, lo, hi);
        last_dump = (uint16_t)(hi + 1);
        return 0;
    }
    if (eqi(cmd, "e") || eqi(cmd, "ei")) {
        MemSide side = eqi(cmd, "ei") ? SIDE_CODE : SIDE_DATA;
        char *a = tok(&rest), *v;
        uint16_t at;
        if (!a) { printf("usage: %s <addr> <byte>...\n", cmd); return 0; }
        at = (uint16_t)parse_num(a, &ok);
        while ((v = tok(&rest)) != NULL) ms_poke(&ms, side, at++, (uint8_t)parse_num(v, &ok));
        return 0;
    }
    if (eqi(cmd, "load")) {
        char *f = tok(&rest), *a = tok(&rest), *w = tok(&rest);
        uint16_t at = 0x0800u;
        int to_i = 1, to_d = 1;
        if (!f) { printf("usage: load <file> [addr] [i|d|both]\n"); return 0; }
        if (a) { long v = parse_num(a, &ok); if (ok) at = (uint16_t)v; }
        if (w) { if (eqi(w, "i")) to_d = 0; else if (eqi(w, "d")) to_i = 0; }
        load_file(f, at, to_i, to_d);
        return 0;
    }
    if (eqi(cmd, "b")) {
        char *a = tok(&rest);
        if (!a) { int i; if (!n_bp) printf("no breakpoints\n");
                  for (i = 0; i < n_bp; i++) printf("  $%04X\n", bp[i]); return 0; }
        if (n_bp < MAX_BP) { bp[n_bp++] = (uint16_t)parse_num(a, &ok); printf("set\n"); }
        else printf("breakpoint table full\n");
        return 0;
    }
    if (eqi(cmd, "bc")) {
        char *a = tok(&rest);
        uint16_t v = a ? (uint16_t)parse_num(a, &ok) : 0;
        int i, j = 0;
        for (i = 0; i < n_bp; i++) if (bp[i] != v) bp[j++] = bp[i];
        n_bp = j;
        return 0;
    }

    /* ---- memory model ---- */
    if (eqi(cmd, "mode")) {
        char *a = tok(&rest);
        if (!a) { printf("%s\n", ms_mode_name(ms.mode)); return 0; }
        if (eqi(a, "vn") || eqi(a, "vonneumann")) ms_set_mode(&ms, MODE_VONNEUMANN);
        else if (eqi(a, "harvard") || eqi(a, "h")) ms_set_mode(&ms, MODE_HARVARD);
        else if (eqi(a, "mod") || eqi(a, "modified")) ms_set_mode(&ms, MODE_MODIFIED);
        else { printf("mode vn | harvard | mod\n"); return 0; }
        printf("%s\n", ms_mode_name(ms.mode));
        if (ms.mode == MODE_HARVARD)
            printf("  note: I-space and D-space are now separate 64K memories.\n"
                   "        Reload the program if you want both populated.\n");
        return 0;
    }
    if (eqi(cmd, "cache")) {
        char *a = tok(&rest);
        if (a) { if (eqi(a, "on")) ms.caches_on = 1;
                 else if (eqi(a, "off")) { ms_flush(&ms, 1, 1); ms.caches_on = 0; } }
        show_config();
        return 0;
    }
    if (eqi(cmd, "config")) { cmd_config(rest); return 0; }
    if (eqi(cmd, "snoop")) {
        char *a = tok(&rest);
        if (a) ms.snoop = eqi(a, "on");
        printf("I$ snooping %s%s\n", ms.snoop ? "on" : "off",
               ms.mode == MODE_MODIFIED ? "" : "  (only meaningful in modified Harvard mode)");
        return 0;
    }
    if (eqi(cmd, "warn")) {
        char *a = tok(&rest);
        if (a) { ms.warn_stale = eqi(a, "on"); ms.stale_warn_left = 8; }
        printf("stale-line warnings %s\n", ms.warn_stale ? "on" : "off");
        return 0;
    }
    if (eqi(cmd, "clean")) { ms_clean(&ms); printf("dirty data lines written back\n"); return 0; }
    if (eqi(cmd, "flush")) {
        char *a = tok(&rest);
        int ci = 1, cd = 1;
        if (a) { if (eqi(a, "i")) cd = 0; else if (eqi(a, "d")) ci = 0; }
        ms_flush(&ms, ci, cd);
        printf("flushed%s%s\n", ci ? " I$" : "", cd ? " D$" : "");
        return 0;
    }

    /* ---- observation ---- */
    if (eqi(cmd, "stats")) { show_stats(); return 0; }
    if (eqi(cmd, "zero"))  { ms_reset_stats(&ms); cpu.cycles = 0; printf("statistics cleared\n"); return 0; }
    if (eqi(cmd, "ci") || eqi(cmd, "cd") || eqi(cmd, "cu")) {
        char *a = tok(&rest);
        long only = a ? parse_num(a, &ok) : -1;
        dump_cache(eqi(cmd, "ci") ? &ms.ci : eqi(cmd, "cd") ? &ms.cd : &ms.cu, only);
        return 0;
    }
    if (eqi(cmd, "sets")) {
        char *a = tok(&rest);
        dump_sets(eqi(a, "i") ? &ms.ci : eqi(a, "d") ? &ms.cd : &ms.cu);
        return 0;
    }
    if (eqi(cmd, "map")) {
        char *a = tok(&rest);
        if (!a) { printf("usage: map <addr>\n"); return 0; }
        show_map((uint16_t)parse_num(a, &ok));
        return 0;
    }
    if (eqi(cmd, "trace")) {
        char *a = tok(&rest);
        if (!a) ms.trace = !ms.trace;
        else if (eqi(a, "on"))  { ms.trace = 1; ms.trace_left = -1; }
        else if (eqi(a, "off"))   ms.trace = 0;
        else { ms.trace = 1; ms.trace_left = parse_num(a, &ok); }
        printf("bus trace %s", ms.trace ? "on" : "off");
        if (ms.trace && ms.trace_left > 0) printf(" (next %ld accesses)", ms.trace_left);
        putchar('\n');
        return 0;
    }

    printf("? %s   (h for help)\n", cmd);
    return 0;
}

static char *read_line(char *buf, int size) {
    int n = 0;
    for (;;) {
        char ch;
        ssize_t r = read(STDIN_FILENO, &ch, 1);
        if (r != 1) { if (!n) return NULL; break; }
        if (ch == '\n' || ch == '\r') { if (tty_raw) putchar('\n'); break; }
        if ((ch == 8 || ch == 127)) {
            if (n) { n--; if (tty_raw) { printf("\b \b"); fflush(stdout); } }
            continue;
        }
        if (n < size - 1) { buf[n++] = ch; if (tty_raw) { putchar(ch); fflush(stdout); } }
    }
    buf[n] = '\0';
    return buf;
}

int main(int argc, char **argv) {
    char line[256];
    const char *file = NULL;
    uint16_t at = 0x0800u;
    int autorun = 0, i, ok;
    const char *want_mode = NULL;
    const char *script = NULL;

    m6502_init(&cpu, ms_read, ms_write, &ms);
    ms_init(&ms, &cpu);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-r")) autorun = 1;
        else if (!strcmp(argv[i], "-a") && i + 1 < argc) at = (uint16_t)parse_num(argv[++i], &ok);
        else if (!strcmp(argv[i], "-m") && i + 1 < argc) want_mode = argv[++i];
        else if (!strcmp(argv[i], "-x") && i + 1 < argc) script = argv[++i];
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            puts("h6502 [-r] [-a <hex>] [-m vn|harvard|mod] [-x <cmds>] [file]");
            puts("  -r          run immediately");
            puts("  -a <hex>    load address (default 0800)");
            puts("  -m <model>  memory model");
            puts("  -x <cmds>   run ';'-separated monitor commands at startup");
            return 0;
        }
        else file = argv[i];
    }

    if (want_mode) {
        if (!strcmp(want_mode, "vn")) ms_set_mode(&ms, MODE_VONNEUMANN);
        else if (!strcmp(want_mode, "harvard")) ms_set_mode(&ms, MODE_HARVARD);
        else if (!strcmp(want_mode, "mod")) ms_set_mode(&ms, MODE_MODIFIED);
    }
    if (file) load_file(file, at, 1, 1);

    m6502_reset(&cpu);
    if (file) cpu.pc = at;

    if (script) {
        char *copy = strdup(script), *p = copy, *semi;
        while (p && *p) {
            semi = strchr(p, ';');
            if (semi) *semi = '\0';
            if (do_command(p)) { free(copy); ms_free(&ms); return 0; }
            p = semi ? semi + 1 : NULL;
        }
        free(copy);
    }

    {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_sigint;
        sa.sa_flags = SA_RESTART;
        sigaction(SIGINT, &sa, NULL);
    }
    tty_setup();

    if (autorun) { run(-1); }

    printf("h6502 -- 6502 with a visible memory hierarchy.  'h' for help.\n");
    show_config();
    for (;;) {
        printf("h> "); fflush(stdout);
        if (!read_line(line, sizeof line)) break;
        if (do_command(line)) break;
    }
    tty_restore();
    ms_free(&ms);
    return 0;
}
