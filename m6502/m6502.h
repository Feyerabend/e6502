/*
 * m6502.h  --  MOS 6502 CPU emulator
 * ANSI C99, no external dependencies
 *
 * Usage:
 *   1. Implement read/write callbacks for your memory map.
 *   2. Call m6502_init(), then m6502_reset().
 *   3. Call m6502_step() in a loop; it returns the cycles consumed.
 *   4. Call m6502_nmi() / m6502_irq() to signal interrupts.
 */
#ifndef M6502_H
#define M6502_H

#include <stdint.h>
#include <stddef.h>

typedef uint8_t (*m6502_read_fn) (void *ctx, uint16_t addr);
typedef void    (*m6502_write_fn)(void *ctx, uint16_t addr, uint8_t val);

/*
 * Bus access kind.
 *
 * A real 6502 has ONE bus: the memory system cannot tell an opcode fetch from
 * a data load, which is exactly what makes it a von Neumann machine.  The core
 * publishes the reason for each access in cpu->access purely so that a *model*
 * built on top of it (see h6502/) can split the stream into an instruction
 * side and a data side and simulate a Harvard machine or a split L1 cache.
 *
 * cpu->access is set immediately before every read()/write() callback and is
 * always valid inside the callback.  Ignore it and behaviour is unchanged.
 */
typedef enum {
    M6502_ACC_OPCODE  = 0,  /* instruction stream: the opcode byte        */
    M6502_ACC_OPERAND = 1,  /* instruction stream: operand byte(s)        */
    M6502_ACC_DATA    = 2,  /* operand data: load / store                 */
    M6502_ACC_PTR     = 3,  /* pointer indirection ((zp,X), (zp),Y, (abs))*/
    M6502_ACC_STACK   = 4,  /* push / pull on page $01                    */
    M6502_ACC_VECTOR  = 5   /* RESET / NMI / IRQ vector fetch             */
} M6502Access;

#define M6502_ACC_IS_CODE(k) ((k) <= M6502_ACC_OPERAND)

typedef struct {
    uint16_t pc;
    uint8_t  sp, a, x, y;
    /* flags stored as individual bytes (0 or 1) for speed */
    uint8_t  c, z, i, d, v, n;
    /* cumulative cycle count since last reset */
    uint64_t cycles;
    /* reason for the bus access in flight; see M6502Access above.  Read-only
     * to the outside world -- valid while a read/write callback is running. */
    uint8_t  access;
    /* bus interface -- must be set before any step/reset call */
    m6502_read_fn  read;
    m6502_write_fn write;
    void          *ctx;
} M6502;

void    m6502_init  (M6502 *cpu,
                     m6502_read_fn read, m6502_write_fn write, void *ctx);
int     m6502_reset (M6502 *cpu);   /* 7 cycles; reads RESET vector $FFFC */
int     m6502_step  (M6502 *cpu);   /* execute one instruction; return cycles */
int     m6502_nmi   (M6502 *cpu);   /* 7 cycles; reads NMI vector $FFFA */
int     m6502_irq   (M6502 *cpu);   /* 7 cycles; no-op if I flag is set */

uint8_t m6502_getP  (const M6502 *cpu);  /* pack flags into P byte */
void    m6502_setP  (M6502 *cpu, uint8_t p);

/* disassemble one instruction at addr into buf; returns byte length */
int m6502_disasm(m6502_read_fn read, void *ctx,
                 uint16_t addr, char *buf, size_t sz);

#endif /* M6502_H */
