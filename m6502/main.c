/*
 * main.c  --  6502 monitor / debugger / driver
 *
 * Features (always compiled in):
 *   - Single-step with register display
 *   - Breakpoints (up to 16)
 *   - Watchpoints on read and/or write (up to 8)
 *   - Instruction history ring buffer (last 16)
 *   - Stack dump
 *   - Memory dump / fill / enter bytes
 *   - Disassembler ('d')
 *   - Inline line assembler ('a')
 *   - Register set ('set pc 1234' etc.)
 *   - IRQ / NMI injection from monitor
 *   - Load flat binary at any address
 *   - Trace mode
 *
 * Memory map:
 *   $0000-$EFFF  RAM (60 KB)
 *   $F001        Console out (write byte -> putchar)
 *   $F002        Console in status (0xFF if a char is waiting)
 *   $F003        Console in data
 *   $F004        BREAK status (0xFF if Ctrl-C pending; read clears it)
 *   $FFFA-$FFFF  Vectors (in RAM; set by loader or user)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>
#include <termios.h>
#include <sys/select.h>
#include <unistd.h>
#include "m6502.h"

/*
 * Memory
 */
#define RAM_SIZE    0x10000u
#define IO_OUT      0xF001u   /* write: console out                       */
#define IO_IN_STAT  0xF002u   /* read:  0xFF if an input char is waiting  */
#define IO_IN_DATA  0xF003u   /* read:  next input char                   */
#define IO_BRK      0xF004u   /* read:  0xFF if Ctrl-C/BREAK pending, else 0 */
#define CODE_START  0x0800u

static uint8_t RAM[RAM_SIZE];

/*
 * Watchpoints
 */
#define MAX_WATCH 8
typedef struct { uint16_t addr; int mode; /* 1=r 2=w 3=rw */ } Watch;
static Watch   watches[MAX_WATCH];
static int     n_watches;
static int     watch_fired;
static uint16_t watch_fired_addr;
static int     watch_fired_mode;   /* 1=read 2=write */

static void check_watch(uint16_t addr, int mode) {
    int i;
    for (i = 0; i < n_watches; i++) {
        if (watches[i].addr == addr && (watches[i].mode & mode)) {
            watch_fired = 1;
            watch_fired_addr = addr;
            watch_fired_mode = mode;
        }
    }
}

/*
 * Console input  (non-blocking single-char lookahead from stdin)
 */
static int running    = 1;   /* forward-declared here; also in run-state section */
static int io_staged  = -1;  /* -1 = nothing ready */

/* Ctrl-C / BREAK: SIGINT sets this; the CPU reads it through $F004 and the
 * BASIC run loop stops with "BREAK".  volatile sig_atomic_t for signal safety. */
static volatile sig_atomic_t break_pending = 0;

static void on_sigint(int sig) { (void)sig; break_pending = 1; }

/* Interactive terminal setup: on a TTY switch to cbreak (chars arrive without
 * Enter, no line buffering) while keeping ECHO and ISIG, so typing is visible
 * and Ctrl-C still raises SIGINT.  Restored on exit.  Piped input is untouched
 * so the test harness and scripts behave exactly as before. */
static struct termios saved_term;
static int term_raw = 0;

static void restore_term(void) {
    if (term_raw) { tcsetattr(STDIN_FILENO, TCSANOW, &saved_term); term_raw = 0; }
}

static void setup_term(void) {
    struct termios t;
    if (!isatty(STDIN_FILENO)) return;
    if (tcgetattr(STDIN_FILENO, &saved_term) != 0) return;
    t = saved_term;
    t.c_lflag &= (tcflag_t)~ICANON;   /* char-at-a-time; keep ECHO and ISIG */
    t.c_cc[VMIN]  = 1;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0) {
        term_raw = 1;
        atexit(restore_term);
    }
}

static int io_peek(void) {
    if (io_staged >= 0) return 1;
    fd_set fds; FD_ZERO(&fds); FD_SET(STDIN_FILENO, &fds);
    struct timeval tv = {0, 0};
    if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
        uint8_t c;
        if (read(STDIN_FILENO, &c, 1) == 1) { io_staged = c; return 1; }
        running = 0;   /* EOF: shut down */
    }
    return 0;
}

static uint8_t io_getc(void) {
    if (io_staged >= 0) { uint8_t c = (uint8_t)io_staged; io_staged = -1; return c; }
    uint8_t c;
    return (read(STDIN_FILENO, &c, 1) == 1) ? c : 0;
}

/*
 * Bus callbacks (with watchpoint + I/O)
 */
static uint8_t mem_read(void *ctx, uint16_t addr) {
    (void)ctx;
    check_watch(addr, 1);
    if (addr == IO_IN_STAT) return io_peek() ? 0xFF : 0;
    if (addr == IO_IN_DATA) return io_getc();
    if (addr == IO_BRK)     { uint8_t v = break_pending ? 0xFF : 0;
                              break_pending = 0; return v; }
    return RAM[addr];
}
static void mem_write(void *ctx, uint16_t addr, uint8_t val) {
    (void)ctx;
    check_watch(addr, 2);
    if (addr == IO_OUT) { putchar(val); fflush(stdout); return; }
    RAM[addr] = val;
}

/*
 * History ring buffer
 */
#define HIST_SIZE 16
typedef struct {
    uint16_t pc;
    uint8_t  sp, a, x, y, flags;
    uint64_t cycles;
    char     dasm[48];
} HistEntry;
static HistEntry history[HIST_SIZE];
static int hist_head;   /* index of next slot to write */
static int hist_count;  /* total valid entries (0..HIST_SIZE) */

static void hist_push(const M6502 *cpu) {
    HistEntry *e = &history[hist_head];
    e->pc     = cpu->pc;
    e->sp     = cpu->sp;
    e->a      = cpu->a;
    e->x      = cpu->x;
    e->y      = cpu->y;
    e->flags  = m6502_getP(cpu);
    e->cycles = cpu->cycles;
    m6502_disasm(mem_read, NULL, cpu->pc, e->dasm, sizeof e->dasm);
    hist_head = (hist_head + 1) % HIST_SIZE;
    if (hist_count < HIST_SIZE) hist_count++;
}

/*
 * Breakpoints
 */
#define MAX_BREAK 16
static uint16_t bpoints[MAX_BREAK];
static int n_bpoints;

static int bp_hit(uint16_t addr) {
    int i;
    for (i = 0; i < n_bpoints; i++) if (bpoints[i] == addr) return 1;
    return 0;
}

/*
 * Emulator run state
 */
static M6502 cpu;
/* running declared earlier (before io_peek needs it) */
static int   in_monitor = 1;
static int   trace      = 0;
static uint64_t total_cycles;

/*
 * Display helpers
 */
static void show_regs(const M6502 *c) {
    uint8_t p = m6502_getP(c);
    printf("PC=$%04X SP=$%02X A=$%02X X=$%02X Y=$%02X P=$%02X [%c%c-%c%c%c%c%c]\n",
           c->pc, c->sp, c->a, c->x, c->y, p,
           (p & 0x80) ? 'N' : 'n',
           (p & 0x40) ? 'V' : 'v',
           (p & 0x08) ? 'D' : 'd',
           (p & 0x04) ? 'I' : 'i',
           (p & 0x02) ? 'Z' : 'z',
           (p & 0x01) ? 'C' : 'c',
           ' ');
}

static void show_dasm(uint16_t addr, int n) {
    int i;
    for (i = 0; i < n; i++) {
        char buf[64];
        int len = m6502_disasm(mem_read, NULL, addr, buf, sizeof buf);
        char marker = (addr == cpu.pc) ? '>' : (bp_hit(addr) ? '*' : ' ');
        printf("%c %s\n", marker, buf);
        addr = (uint16_t)(addr + len);
        if (addr < (uint16_t)(addr - len)) break;  /* overflow */
    }
}

static void show_mem(uint16_t start, uint16_t end) {
    uint16_t addr;
    for (addr = start; addr <= end; addr = (uint16_t)(addr + 16)) {
        int i;
        printf("%04X: ", addr);
        for (i = 0; i < 16 && (uint16_t)(addr + i) <= end; i++)
            printf("%02X ", RAM[(uint16_t)(addr + i)]);
        printf(" ");
        for (i = 0; i < 16 && (uint16_t)(addr + i) <= end; i++) {
            uint8_t c = RAM[(uint16_t)(addr + i)];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("\n");
        if ((uint16_t)(addr + 16) < addr) break;  /* overflow */
    }
}

static void show_stack(void) {
    int i;
    uint16_t top = (uint16_t)(0x0101u + cpu.sp);
    printf("Stack (SP=$%02X, $%04X...$01FF):\n", cpu.sp, top);
    if (cpu.sp == 0xff) { printf("  (empty)\n"); return; }
    for (i = 0; i < 16 && top + i <= 0x01ff; i++)
        printf("  $%04X: $%02X\n", (uint16_t)(top + i), RAM[(uint16_t)(top + i)]);
}

static void show_history(void) {
    int i, count = hist_count;
    printf("Instruction history (oldest first):\n");
    if (count == 0) { printf("  (none)\n"); return; }
    for (i = 0; i < count; i++) {
        int idx = (hist_head - count + i + HIST_SIZE) % HIST_SIZE;
        HistEntry *e = &history[idx];
        uint8_t p = e->flags;
        printf("  %s  A=%02X X=%02X Y=%02X SP=%02X P=[%c%c%c%c%c%c] cyc=%" PRIu64 "\n",
               e->dasm, e->a, e->x, e->y, e->sp,
               (p&0x80)?'N':'n',(p&0x40)?'V':'v',(p&0x08)?'D':'d',
               (p&0x04)?'I':'i',(p&0x02)?'Z':'z',(p&0x01)?'C':'c',
               e->cycles);
    }
}

/*
 * Hex parser
 */
static int parse_hex(const char *s, uint32_t *out) {
    char *end;
    if (!s || !*s) return 0;
    *out = strtoul(s, &end, 16);
    return (*end == '\0' || isspace((unsigned char)*end));
}

/*
 * Inline assembler
 *
 * Supports all official opcodes.  Enter raw bytes with .byte for
 * unlisted encodings.  Operand syntax:
 *   IMP  : (nothing)          e.g. NOP
 *   ACC  : A                  e.g. LSR A
 *   IMM  : #$xx               e.g. LDA #$42
 *   ZP   : $xx   (2 hex dig)  e.g. LDA $20
 *   ZPX  : $xx,X              e.g. LDA $20,X
 *   ZPY  : $xx,Y              e.g. LDX $20,Y
 *   ABS  : $xxxx (4 hex dig)  e.g. LDA $1234
 *   ABSX : $xxxx,X            e.g. LDA $1234,X
 *   ABSY : $xxxx,Y            e.g. LDA $1234,Y
 *   IND  : ($xxxx)            e.g. JMP ($1234)
 *   INDX : ($xx,X)            e.g. LDA ($20,X)
 *   INDY : ($xx),Y            e.g. LDA ($20),Y
 *   REL  : $xxxx (target addr e.g. BNE $0810
 */
#define AM_IMP  0
#define AM_ACC  1
#define AM_IMM  2
#define AM_ZP   3
#define AM_ZPX  4
#define AM_ZPY  5
#define AM_ABS  6
#define AM_ABSX 7
#define AM_ABSY 8
#define AM_IND  9
#define AM_INDX 10
#define AM_INDY 11
#define AM_REL  12

typedef struct { const char mn[4]; uint8_t mode; uint8_t byte; } AsmEntry;

static const AsmEntry asm_tab[] = {
    {"ADC",AM_IMM, 0x69},{"ADC",AM_ZP,  0x65},{"ADC",AM_ZPX, 0x75},
    {"ADC",AM_ABS, 0x6D},{"ADC",AM_ABSX,0x7D},{"ADC",AM_ABSY,0x79},
    {"ADC",AM_INDX,0x61},{"ADC",AM_INDY,0x71},
    {"AND",AM_IMM, 0x29},{"AND",AM_ZP,  0x25},{"AND",AM_ZPX, 0x35},
    {"AND",AM_ABS, 0x2D},{"AND",AM_ABSX,0x3D},{"AND",AM_ABSY,0x39},
    {"AND",AM_INDX,0x21},{"AND",AM_INDY,0x31},
    {"ASL",AM_ACC, 0x0A},{"ASL",AM_ZP,  0x06},{"ASL",AM_ZPX, 0x16},
    {"ASL",AM_ABS, 0x0E},{"ASL",AM_ABSX,0x1E},
    {"BCC",AM_REL, 0x90},{"BCS",AM_REL, 0xB0},{"BEQ",AM_REL, 0xF0},
    {"BIT",AM_ZP,  0x24},{"BIT",AM_ABS, 0x2C},
    {"BMI",AM_REL, 0x30},{"BNE",AM_REL, 0xD0},{"BPL",AM_REL, 0x10},
    {"BRK",AM_IMP, 0x00},
    {"BVC",AM_REL, 0x50},{"BVS",AM_REL, 0x70},
    {"CLC",AM_IMP, 0x18},{"CLD",AM_IMP, 0xD8},{"CLI",AM_IMP, 0x58},
    {"CLV",AM_IMP, 0xB8},
    {"CMP",AM_IMM, 0xC9},{"CMP",AM_ZP,  0xC5},{"CMP",AM_ZPX, 0xD5},
    {"CMP",AM_ABS, 0xCD},{"CMP",AM_ABSX,0xDD},{"CMP",AM_ABSY,0xD9},
    {"CMP",AM_INDX,0xC1},{"CMP",AM_INDY,0xD1},
    {"CPX",AM_IMM, 0xE0},{"CPX",AM_ZP,  0xE4},{"CPX",AM_ABS, 0xEC},
    {"CPY",AM_IMM, 0xC0},{"CPY",AM_ZP,  0xC4},{"CPY",AM_ABS, 0xCC},
    {"DEC",AM_ZP,  0xC6},{"DEC",AM_ZPX, 0xD6},{"DEC",AM_ABS, 0xCE},
    {"DEC",AM_ABSX,0xDE},
    {"DEX",AM_IMP, 0xCA},{"DEY",AM_IMP, 0x88},
    {"EOR",AM_IMM, 0x49},{"EOR",AM_ZP,  0x45},{"EOR",AM_ZPX, 0x55},
    {"EOR",AM_ABS, 0x4D},{"EOR",AM_ABSX,0x5D},{"EOR",AM_ABSY,0x59},
    {"EOR",AM_INDX,0x41},{"EOR",AM_INDY,0x51},
    {"INC",AM_ZP,  0xE6},{"INC",AM_ZPX, 0xF6},{"INC",AM_ABS, 0xEE},
    {"INC",AM_ABSX,0xFE},
    {"INX",AM_IMP, 0xE8},{"INY",AM_IMP, 0xC8},
    {"JMP",AM_ABS, 0x4C},{"JMP",AM_IND, 0x6C},
    {"JSR",AM_ABS, 0x20},
    {"LDA",AM_IMM, 0xA9},{"LDA",AM_ZP,  0xA5},{"LDA",AM_ZPX, 0xB5},
    {"LDA",AM_ABS, 0xAD},{"LDA",AM_ABSX,0xBD},{"LDA",AM_ABSY,0xB9},
    {"LDA",AM_INDX,0xA1},{"LDA",AM_INDY,0xB1},
    {"LDX",AM_IMM, 0xA2},{"LDX",AM_ZP,  0xA6},{"LDX",AM_ZPY, 0xB6},
    {"LDX",AM_ABS, 0xAE},{"LDX",AM_ABSY,0xBE},
    {"LDY",AM_IMM, 0xA0},{"LDY",AM_ZP,  0xA4},{"LDY",AM_ZPX, 0xB4},
    {"LDY",AM_ABS, 0xAC},{"LDY",AM_ABSX,0xBC},
    {"LSR",AM_ACC, 0x4A},{"LSR",AM_ZP,  0x46},{"LSR",AM_ZPX, 0x56},
    {"LSR",AM_ABS, 0x4E},{"LSR",AM_ABSX,0x5E},
    {"NOP",AM_IMP, 0xEA},
    {"ORA",AM_IMM, 0x09},{"ORA",AM_ZP,  0x05},{"ORA",AM_ZPX, 0x15},
    {"ORA",AM_ABS, 0x0D},{"ORA",AM_ABSX,0x1D},{"ORA",AM_ABSY,0x19},
    {"ORA",AM_INDX,0x01},{"ORA",AM_INDY,0x11},
    {"PHA",AM_IMP, 0x48},{"PHP",AM_IMP, 0x08},
    {"PLA",AM_IMP, 0x68},{"PLP",AM_IMP, 0x28},
    {"ROL",AM_ACC, 0x2A},{"ROL",AM_ZP,  0x26},{"ROL",AM_ZPX, 0x36},
    {"ROL",AM_ABS, 0x2E},{"ROL",AM_ABSX,0x3E},
    {"ROR",AM_ACC, 0x6A},{"ROR",AM_ZP,  0x66},{"ROR",AM_ZPX, 0x76},
    {"ROR",AM_ABS, 0x6E},{"ROR",AM_ABSX,0x7E},
    {"RTI",AM_IMP, 0x40},{"RTS",AM_IMP, 0x60},
    {"SBC",AM_IMM, 0xE9},{"SBC",AM_ZP,  0xE5},{"SBC",AM_ZPX, 0xF5},
    {"SBC",AM_ABS, 0xED},{"SBC",AM_ABSX,0xFD},{"SBC",AM_ABSY,0xF9},
    {"SBC",AM_INDX,0xE1},{"SBC",AM_INDY,0xF1},
    {"SEC",AM_IMP, 0x38},{"SED",AM_IMP, 0xF8},{"SEI",AM_IMP, 0x78},
    {"STA",AM_ZP,  0x85},{"STA",AM_ZPX, 0x95},{"STA",AM_ABS, 0x8D},
    {"STA",AM_ABSX,0x9D},{"STA",AM_ABSY,0x99},{"STA",AM_INDX,0x81},
    {"STA",AM_INDY,0x91},
    {"STX",AM_ZP,  0x86},{"STX",AM_ZPY, 0x96},{"STX",AM_ABS, 0x8E},
    {"STY",AM_ZP,  0x84},{"STY",AM_ZPX, 0x94},{"STY",AM_ABS, 0x8C},
    {"TAX",AM_IMP, 0xAA},{"TAY",AM_IMP, 0xA8},{"TSX",AM_IMP, 0xBA},
    {"TXA",AM_IMP, 0x8A},{"TXS",AM_IMP, 0x9A},{"TYA",AM_IMP, 0x98},
};
#define ASM_TAB_LEN ((int)(sizeof asm_tab / sizeof asm_tab[0]))

/* parse one operand string and produce mode + 16-bit value */
static int parse_operand(const char *s, int *mode_out, uint32_t *val_out) {
    char tmp[64];
    int  ndig;
    const char *p;

    /* skip leading space */
    while (isspace((unsigned char)*s)) s++;

    if (!*s || *s == '\0') { *mode_out = AM_IMP; *val_out = 0; return 1; }

    /* accumulator */
    if ((s[0] == 'A' || s[0] == 'a') && (!s[1] || isspace((unsigned char)s[1]))) {
        *mode_out = AM_ACC; *val_out = 0; return 1;
    }

    /* immediate: #$xx or #decimal */
    if (s[0] == '#') {
        s++;
        if (*s == '$') { *val_out = strtoul(s+1, NULL, 16); }
        else           { *val_out = strtoul(s,   NULL, 10); }
        *mode_out = AM_IMM;
        return 1;
    }

    /* indirect modes: ($... */
    if (s[0] == '(') {
        s++;
        if (*s != '$') return 0;
        s++;
        *val_out = strtoul(s, (char**)&p, 16);
        ndig = (int)(p - s);
        /* ($xx,X) */
        if (strncmp(p, ",X)", 3) == 0 || strncmp(p, ",x)", 3) == 0) {
            *mode_out = AM_INDX; return 1;
        }
        /* ($xx),Y */
        if (p[0] == ')' && (p[1] == ',') &&
            (p[2] == 'Y' || p[2] == 'y')) {
            *mode_out = AM_INDY; return 1;
        }
        /* ($xxxx) */
        if (p[0] == ')') {
            *mode_out = (ndig <= 2 && *val_out <= 0xff) ? AM_INDX : AM_IND;
            /* For real indirect JMP only ABS ind makes sense, but let caller sort */
            *mode_out = AM_IND; return 1;
        }
        return 0;
    }

    /* absolute/zp modes: $... */
    if (s[0] == '$') {
        s++;
        *val_out = strtoul(s, (char**)&p, 16);
        ndig = (int)(p - s);
        /* ,X */
        if (*p == ',' && (p[1] == 'X' || p[1] == 'x')) {
            *mode_out = (ndig <= 2 && *val_out <= 0xff) ? AM_ZPX : AM_ABSX;
            return 1;
        }
        /* ,Y */
        if (*p == ',' && (p[1] == 'Y' || p[1] == 'y')) {
            *mode_out = (ndig <= 2 && *val_out <= 0xff) ? AM_ZPY : AM_ABSY;
            return 1;
        }
        /* plain */
        *mode_out = (ndig <= 2 && *val_out <= 0xff) ? AM_ZP : AM_ABS;
        return 1;
    }

    /* decimal number (for relative branch target) */
    if (isdigit((unsigned char)*s)) {
        *val_out = strtoul(s, NULL, 10);
        *mode_out = AM_ABS;
        return 1;
    }

    /* raw hex with no $ (treat as decimal for simplicity, reject) */
    snprintf(tmp, sizeof tmp, "%s", s);
    return 0;
}

/* assemble one line; write bytes into RAM[addr]; return byte count or -1 */
static int asm_line(uint16_t addr, const char *line) {
    char     mn[8] = "";
    const char *p  = line;
    int      i, mode, blen;
    uint32_t val;
    uint8_t  opbyte;

    /* skip whitespace */
    while (isspace((unsigned char)*p)) p++;
    if (!*p || *p == ';') return 0;

    /* .byte directive: .byte $xx $xx ... */
    if (strncasecmp(p, ".byte", 5) == 0) {
        p += 5; blen = 0;
        while (*p) {
            while (isspace((unsigned char)*p)) p++;
            if (!*p) break;
            if (*p == '$') p++;
            uint32_t b = strtoul(p, (char**)&p, 16);
            RAM[(uint16_t)(addr + blen)] = (uint8_t)b; blen++;
        }
        return blen;
    }

    /* read mnemonic (up to 4 chars) */
    for (i = 0; i < 3 && *p && !isspace((unsigned char)*p); i++, p++)
        mn[i] = (char)toupper((unsigned char)*p);
    mn[i] = '\0';
    while (isspace((unsigned char)*p)) p++;

    if (!parse_operand(p, &mode, &val)) {
        printf("  ? bad operand: %s\n", p); return -1;
    }

    /* look up (mnemonic, mode) in table; allow ZP->ABS fallback */
    opbyte = 0; blen = -1;
    for (i = 0; i < ASM_TAB_LEN; i++) {
        if (strcmp(asm_tab[i].mn, mn) == 0 && asm_tab[i].mode == (uint8_t)mode) {
            opbyte = asm_tab[i].byte;
            blen   = 0; break;
        }
    }
    /* ZP->ABS fallback */
    if (blen < 0 && (mode == AM_ZP || mode == AM_ZPX || mode == AM_ZPY)) {
        int abs_mode = (mode == AM_ZP) ? AM_ABS : (mode == AM_ZPX) ? AM_ABSX : AM_ABSY;
        for (i = 0; i < ASM_TAB_LEN; i++) {
            if (strcmp(asm_tab[i].mn, mn) == 0 && asm_tab[i].mode == (uint8_t)abs_mode) {
                opbyte = asm_tab[i].byte; mode = abs_mode; blen = 0; break;
            }
        }
    }
    /* IMP->ACC fallback */
    if (blen < 0 && mode == AM_IMP) {
        for (i = 0; i < ASM_TAB_LEN; i++) {
            if (strcmp(asm_tab[i].mn, mn) == 0 && asm_tab[i].mode == AM_ACC) {
                opbyte = asm_tab[i].byte; mode = AM_ACC; blen = 0; break;
            }
        }
    }
    if (blen < 0) {
        printf("  ? unknown: %s mode=%d\n", mn, mode); return -1;
    }

    /* emit opcode + operand */
    RAM[addr] = opbyte; blen = 1;
    switch (mode) {
        case AM_IMP: case AM_ACC: break;
        case AM_IMM: case AM_ZP: case AM_ZPX: case AM_ZPY:
        case AM_INDX: case AM_INDY:
            RAM[(uint16_t)(addr+1)] = (uint8_t)val; blen = 2; break;
        case AM_REL: {
            int off = (int)val - (int)(addr + 2);
            if (off < -128 || off > 127) { printf("  ? branch out of range\n"); return -1; }
            RAM[(uint16_t)(addr+1)] = (uint8_t)(int8_t)off; blen = 2; break;
        }
        case AM_ABS: case AM_ABSX: case AM_ABSY: case AM_IND:
            RAM[(uint16_t)(addr+1)] = (uint8_t)val;
            RAM[(uint16_t)(addr+2)] = (uint8_t)(val >> 8);
            blen = 3; break;
    }
    return blen;
}

/* line reader using read() to stay consistent with io_peek/io_getc */
static char *read_line(char *buf, int size) {
    int n = 0;
    while (n < size - 1) {
        uint8_t c;
        ssize_t r = read(STDIN_FILENO, &c, 1);
        if (r <= 0) { if (n == 0) return NULL; break; }
        if (c == '\r') continue;
        if (c == '\n') break;
        buf[n++] = (char)c;
    }
    buf[n] = '\0';
    return buf;
}

/* interactive assemble mode: 'a [addr]' */
static void do_assemble(uint16_t start_addr) {
    char line[128];
    uint16_t addr = start_addr;
    printf("Assembling from $%04X  (empty line to exit)\n", addr);
    for (;;) {
        printf("%04X: ", addr);
        fflush(stdout);
        if (!read_line(line, sizeof line)) break;
        if (line[0] == '\0') break;
        int n = asm_line(addr, line);
        if (n > 0) {
            char buf[64];
            m6502_disasm(mem_read, NULL, addr, buf, sizeof buf);
            printf("  %s\n", buf);
            addr = (uint16_t)(addr + n);
        }
    }
}

/*
 * Binary loader
 */
static int load_binary(const char *path, uint16_t at) {
    FILE *f = fopen(path, "rb");
    long  sz;
    if (!f) { fprintf(stderr, "Cannot open '%s'\n", path); return -1; }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > (long)(RAM_SIZE - at)) {
        fprintf(stderr, "File too large (%ld bytes at $%04X)\n", sz, at);
        fclose(f); return -1;
    }
    if ((long)fread(&RAM[at], 1, (size_t)sz, f) != sz) {
        fprintf(stderr, "Read error\n"); fclose(f); return -1;
    }
    fclose(f);
    printf("Loaded %ld bytes at $%04X\n", sz, at);
    return (int)sz;
}

/*
 * Monitor
 */
static void show_help(void) {
    printf(
        "\nMonitor commands (all numbers hex unless noted):\n"
        "  s [n]              step n instructions (default 1)\n"
        "  c / g [addr]       continue; g sets PC first\n"
        "  d [addr] [n]       disassemble (default: PC, 10 lines)\n"
        "  r                  show registers\n"
        "  set <reg> <val>    set register: pc sp a x y p\n"
        "  m [start] [end]    memory dump (default $0000..$00FF)\n"
        "  e <addr> <b>...    enter bytes\n"
        "  f <s> <e> <v>      fill memory s..e with byte v\n"
        "  a [addr]           assemble at addr (default PC)\n"
        "  b [addr]           set/list breakpoints\n"
        "  bc <addr>          clear breakpoint\n"
        "  w <addr> [r|w|rw]  set watchpoint (default rw)\n"
        "  wc <addr>          clear watchpoint\n"
        "  k                  stack dump\n"
        "  hist               instruction history\n"
        "  t                  toggle trace\n"
        "  irq                inject IRQ\n"
        "  nmi                inject NMI\n"
        "  reset              reset CPU\n"
        "  load <file> [addr] load binary (default $0800)\n"
        "  q                  quit\n"
        "  h / ?              this help\n\n"
        "Markers: '>' current PC, '*' breakpoint\n\n"
        "Nano BASIC (load at $0800, entry $0800):\n"
        "  from shell:    m6502 -r -a 800 basic/basic.bin\n"
        "  from monitor:  load basic/basic.bin 800  then  g\n\n");
}

static void run_monitor(void) {
    char line[256];
    char *tok, *a1, *a2, *a3;
    uint32_t v1, v2, v3;

    printf("\n--- 6502 Monitor  (h for help) ---\n");
    show_regs(&cpu);
    show_dasm(cpu.pc, 3);

    while (running) {
        printf("$> "); fflush(stdout);
        if (!fgets(line, sizeof line, stdin)) { running = 0; break; }
        { int n = (int)strlen(line); if (n > 0 && line[n-1] == '\n') line[n-1] = '\0'; }

        tok = strtok(line, " \t\n");
        if (!tok) continue;
        a1 = strtok(NULL, " \t\n");
        a2 = strtok(NULL, " \t\n");
        a3 = strtok(NULL, " \t\n");

        /* ---- step ---- */
        if (!strcmp(tok,"s") || !strcmp(tok,"step")) {
            int n = a1 ? (int)strtol(a1, NULL, 16) : 1;
            if (n <= 0) n = 1;
            while (n-- > 0 && running) {
                char buf[64];
                m6502_disasm(mem_read, NULL, cpu.pc, buf, sizeof buf);
                printf("  %s\n", buf);
                hist_push(&cpu);
                watch_fired = 0;
                int cy = m6502_step(&cpu); total_cycles += cy;
                show_regs(&cpu);
                if (watch_fired) {
                    printf("Watchpoint %s $%04X\n",
                           watch_fired_mode == 1 ? "READ" : "WRITE",
                           watch_fired_addr);
                    break;
                }
            }

        /* ---- continue / go ---- */
        } else if (!strcmp(tok,"c") || !strcmp(tok,"g") || !strcmp(tok,"cont")) {
            if (a1 && parse_hex(a1,&v1)) cpu.pc = (uint16_t)v1;
            in_monitor = 0;
            printf("Running...\n"); break;

        /* ---- disassemble ---- */
        } else if (!strcmp(tok,"d") || !strcmp(tok,"dis")) {
            uint16_t at = cpu.pc; int n = 10;
            if (a1 && parse_hex(a1,&v1)) at = (uint16_t)v1;
            if (a2) n = (int)strtol(a2, NULL, 10);
            show_dasm(at, n);

        /* ---- registers ---- */
        } else if (!strcmp(tok,"r") || !strcmp(tok,"regs")) {
            show_regs(&cpu);
            printf("Cycles: %" PRIu64 "\n", total_cycles);

        /* ---- set register ---- */
        } else if (!strcmp(tok,"set")) {
            if (!a1 || !a2 || !parse_hex(a2,&v1)) {
                printf("Usage: set <reg> <hex-val>\n");
            } else {
                char *reg = a1;
                if      (!strcasecmp(reg,"pc")) cpu.pc = (uint16_t)v1;
                else if (!strcasecmp(reg,"sp")) cpu.sp = (uint8_t)v1;
                else if (!strcasecmp(reg,"a"))  cpu.a  = (uint8_t)v1;
                else if (!strcasecmp(reg,"x"))  cpu.x  = (uint8_t)v1;
                else if (!strcasecmp(reg,"y"))  cpu.y  = (uint8_t)v1;
                else if (!strcasecmp(reg,"p"))  m6502_setP(&cpu,(uint8_t)v1);
                else printf("Unknown register: %s\n", reg);
                show_regs(&cpu);
            }

        /* ---- memory dump ---- */
        } else if (!strcmp(tok,"m") || !strcmp(tok,"mem")) {
            uint16_t s = 0x0000, e = 0x00ff;
            if (a1 && parse_hex(a1,&v1)) { s=(uint16_t)v1; e=(uint16_t)(v1+0xff); }
            if (a2 && parse_hex(a2,&v2)) e=(uint16_t)v2;
            if (e < s) e = s;
            show_mem(s, e);

        /* ---- enter bytes ---- */
        } else if (!strcmp(tok,"e") || !strcmp(tok,"enter")) {
            if (!a1 || !parse_hex(a1,&v1)) { printf("Usage: e <addr> <byte>...\n"); }
            else {
                uint16_t at = (uint16_t)v1;
                char *b = a2;
                while (b) {
                    uint32_t bv;
                    if (parse_hex(b,&bv)) { RAM[at++] = (uint8_t)bv; }
                    b = strtok(NULL, " \t\n");
                }
            }

        /* ---- fill memory ---- */
        } else if (!strcmp(tok,"f") || !strcmp(tok,"fill")) {
            if (!a1||!a2||!a3||!parse_hex(a1,&v1)||!parse_hex(a2,&v2)||!parse_hex(a3,&v3)) {
                printf("Usage: f <start> <end> <byte>\n");
            } else {
                uint16_t s=(uint16_t)v1, e=(uint16_t)v2;
                uint8_t  bv=(uint8_t)v3;
                uint16_t at;
                for (at=s;;at++) { RAM[at]=bv; if(at==e) break; }
                printf("Filled $%04X..$%04X with $%02X\n",s,e,bv);
            }

        /* ---- assemble ---- */
        } else if (!strcmp(tok,"a") || !strcmp(tok,"asm")) {
            uint16_t at = cpu.pc;
            if (a1 && parse_hex(a1,&v1)) at = (uint16_t)v1;
            do_assemble(at);

        /* ---- breakpoints ---- */
        } else if (!strcmp(tok,"b") || !strcmp(tok,"break")) {
            if (!a1) {
                int i;
                if (!n_bpoints) { printf("No breakpoints\n"); }
                else { for (i=0;i<n_bpoints;i++) printf("  %d: $%04X\n",i+1,bpoints[i]); }
            } else if (parse_hex(a1,&v1)) {
                int i;
                if (n_bpoints >= MAX_BREAK) { printf("Too many breakpoints\n"); }
                else {
                    for (i=0;i<n_bpoints;i++) if(bpoints[i]==(uint16_t)v1){printf("Already set\n");goto bp_done;}
                    bpoints[n_bpoints++]=(uint16_t)v1;
                    printf("Breakpoint %d at $%04X\n",n_bpoints,(uint16_t)v1);
                }
                bp_done:;
            }

        } else if (!strcmp(tok,"bc")) {
            if (a1 && parse_hex(a1,&v1)) {
                int i;
                for (i=0;i<n_bpoints;i++) {
                    if (bpoints[i]==(uint16_t)v1) {
                        int j;
                        for(j=i;j<n_bpoints-1;j++) bpoints[j]=bpoints[j+1];
                        n_bpoints--;
                        printf("Cleared breakpoint at $%04X\n",(uint16_t)v1);
                        goto bc_done;
                    }
                }
                printf("No breakpoint at $%04X\n",(uint16_t)v1);
                bc_done:;
            }

        /* ---- watchpoints ---- */
        } else if (!strcmp(tok,"w") || !strcmp(tok,"watch")) {
            if (!a1) {
                int i;
                if (!n_watches) { printf("No watchpoints\n"); }
                else {
                    const char *mnames[]={"","r","w","rw"};
                    for(i=0;i<n_watches;i++)
                        printf("  %d: $%04X [%s]\n",i+1,watches[i].addr,mnames[watches[i].mode]);
                }
            } else if (parse_hex(a1,&v1)) {
                int wm = 3;
                if (a2) {
                    if      (!strcasecmp(a2,"r"))  wm=1;
                    else if (!strcasecmp(a2,"w"))  wm=2;
                    else if (!strcasecmp(a2,"rw")) wm=3;
                }
                if (n_watches >= MAX_WATCH) { printf("Too many watchpoints\n"); }
                else {
                    watches[n_watches].addr=(uint16_t)v1;
                    watches[n_watches].mode=wm;
                    n_watches++;
                    printf("Watchpoint at $%04X [%s]\n",(uint16_t)v1,
                           wm==1?"r":wm==2?"w":"rw");
                }
            }

        } else if (!strcmp(tok,"wc")) {
            if (a1 && parse_hex(a1,&v1)) {
                int i;
                for(i=0;i<n_watches;i++){
                    if(watches[i].addr==(uint16_t)v1){
                        int j;
                        for(j=i;j<n_watches-1;j++) watches[j]=watches[j+1];
                        n_watches--;
                        printf("Cleared watchpoint at $%04X\n",(uint16_t)v1);
                        goto wc_done;
                    }
                }
                printf("No watchpoint at $%04X\n",(uint16_t)v1);
                wc_done:;
            }

        /* ---- stack ---- */
        } else if (!strcmp(tok,"k") || !strcmp(tok,"stack")) {
            show_stack();

        /* ---- history ---- */
        } else if (!strcmp(tok,"hist") || !strcmp(tok,"history")) {
            show_history();

        /* ---- trace ---- */
        } else if (!strcmp(tok,"t") || !strcmp(tok,"trace")) {
            trace = !trace;
            printf("Trace %s\n", trace ? "ON" : "OFF");

        /* ---- IRQ / NMI ---- */
        } else if (!strcmp(tok,"irq")) {
            int cy = m6502_irq(&cpu); total_cycles += cy;
            if (!cy) printf("IRQ ignored (I flag set)\n");
            else { printf("IRQ\n"); show_regs(&cpu); }

        } else if (!strcmp(tok,"nmi")) {
            int cy = m6502_nmi(&cpu); total_cycles += cy;
            printf("NMI\n"); show_regs(&cpu);

        /* ---- reset ---- */
        } else if (!strcmp(tok,"reset")) {
            memset(RAM, 0, sizeof RAM);
            total_cycles = 0; hist_count = hist_head = 0;
            n_bpoints = n_watches = 0;
            m6502_reset(&cpu); total_cycles = 7;
            printf("CPU reset\n"); show_regs(&cpu);

        /* ---- load ---- */
        } else if (!strcmp(tok,"load")) {
            uint16_t at = CODE_START;
            if (!a1) { printf("Usage: load <file> [addr]\n"); }
            else {
                if (a2 && parse_hex(a2,&v1)) at=(uint16_t)v1;
                if (load_binary(a1, at) >= 0) {
                    cpu.pc = at;
                    /* set reset vector to load address so 'reset' works */
                    RAM[0xfffc] = (uint8_t)at;
                    RAM[0xfffd] = (uint8_t)(at >> 8);
                    show_regs(&cpu);
                }
            }

        /* ---- quit ---- */
        } else if (!strcmp(tok,"q") || !strcmp(tok,"quit")) {
            running = 0; break;

        /* ---- help ---- */
        } else if (!strcmp(tok,"h") || !strcmp(tok,"?") || !strcmp(tok,"help")) {
            show_help();

        } else {
            printf("Unknown command '%s' (h for help)\n", tok);
        }
    }
}

/*
 * Main emulation loop
 */
static void run_loop(void) {
    while (running) {
        if (in_monitor) {
            run_monitor();
            if (!running) break;
            in_monitor = 0;
            continue;
        }

        if (bp_hit(cpu.pc)) {
            printf("\nBreakpoint at $%04X\n", cpu.pc);
            show_regs(&cpu);
            in_monitor = 1; continue;
        }

        /* BRK stops execution and drops to monitor; advance past it so 'c' resumes */
        if (RAM[cpu.pc] == 0x00) {
            printf("\nBRK at $%04X (cycles=%" PRIu64 ")\n", cpu.pc, total_cycles);
            cpu.pc++;
            show_regs(&cpu);
            in_monitor = 1; continue;
        }

        if (trace) {
            char buf[64];
            m6502_disasm(mem_read, NULL, cpu.pc, buf, sizeof buf);
            printf("%s  ", buf);
        }

        hist_push(&cpu);
        watch_fired = 0;
        int cy = m6502_step(&cpu); total_cycles += cy;

        if (trace) show_regs(&cpu);

        if (watch_fired) {
            printf("\nWatchpoint %s $%04X  (cycles=%" PRIu64 ")\n",
                   watch_fired_mode == 1 ? "READ" : "WRITE",
                   watch_fired_addr, total_cycles);
            show_regs(&cpu);
            in_monitor = 1;
        }
    }
}

/*
 * Entry point
 */
static void usage(const char *prog) {
    printf("Usage: %s [options] [binary]\n", prog);
    printf("  -r          run immediately (skip initial monitor)\n");
    printf("  -t          enable trace\n");
    printf("  -a <addr>   load address (hex, default %04X)\n", (unsigned)CODE_START);
    printf("  binary      flat binary to load\n");
    printf("\nNano BASIC:  %s -r -a 800 basic/basic.bin\n", prog);
}

int main(int argc, char *argv[]) {
    char    *file  = NULL;
    uint16_t load_at = CODE_START;
    int      i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"-r"))        { in_monitor = 0; }
        else if (!strcmp(argv[i],"-t"))   { trace = 1; }
        else if (!strcmp(argv[i],"-a") && i+1 < argc) {
            uint32_t v; if (parse_hex(argv[++i],&v)) load_at=(uint16_t)v;
        } else if (!strcmp(argv[i],"-h")) { usage(argv[0]); return 0; }
        else if (argv[i][0] != '-')       { file = argv[i]; }
        else { fprintf(stderr,"Unknown option: %s\n",argv[i]); usage(argv[0]); return 1; }
    }

    memset(RAM, 0, sizeof RAM);
    m6502_init(&cpu, mem_read, mem_write, NULL);

    if (file) {
        if (load_binary(file, load_at) < 0) return 1;
        /* point reset vector at load address */
        RAM[0xfffc] = (uint8_t)load_at;
        RAM[0xfffd] = (uint8_t)(load_at >> 8);
    }

    m6502_reset(&cpu);
    total_cycles = 7;
    printf("m6502  --  PC=$%04X  (h for help)\n", cpu.pc);

    {   /* Ctrl-C sets a BREAK flag instead of killing the process */
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_sigint;
        sa.sa_flags = SA_RESTART;   /* let blocking reads resume */
        sigaction(SIGINT, &sa, NULL);
    }
    setup_term();

    run_loop();
    restore_term();

    printf("\nDone.  Total cycles: %" PRIu64 "\n", total_cycles);
    return 0;
}
