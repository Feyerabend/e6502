/*
 * m6502.c  --  MOS 6502 CPU emulator core
 *
 * Cycle-accurate timing (ticktable + page-cross penalties + decimal extra cycle).
 * All 56 official opcodes + stable NMOS undocumented opcodes.
 * CPU state is held in an M6502 struct; no global mutable state is exposed.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "m6502.h"

/* -------------------------------------------------------------------------
 * Per-instruction transient state (file-static, set at start of step())
 * ------------------------------------------------------------------------- */
static M6502   *g_cpu;
static uint16_t g_ea;       /* effective address computed by addr mode */
static uint32_t g_ticks;    /* cycles for this instruction */
static uint8_t  g_op;       /* opcode byte */
static uint8_t  g_paddr;    /* 1 if address calc crossed a page */
static uint8_t  g_pop;      /* 1 if this opcode cares about page crossing */
static uint8_t  g_acc;      /* 1 if accumulator addressing mode */
static uint8_t  g_imm;      /* 1 if immediate mode (operand lives in code) */

/* -------------------------------------------------------------------------
 * Bus helpers
 * ------------------------------------------------------------------------- */
/* Every bus access is tagged with the reason for it (M6502_ACC_*) before the
 * callback runs.  On real silicon there is one undifferentiated bus; the tag
 * exists only so a memory model layered on top can split code from data.
 * The tag never influences what the core itself does. */
static uint8_t rdk(uint16_t a, uint8_t kind) {
    g_cpu->access = kind;
    return g_cpu->read(g_cpu->ctx, a);
}
static void wrk(uint16_t a, uint8_t v, uint8_t kind) {
    g_cpu->access = kind;
    g_cpu->write(g_cpu->ctx, a, v);
}
static uint16_t rdk16(uint16_t a, uint8_t kind) {
    return (uint16_t)rdk(a, kind) |
           ((uint16_t)rdk((uint16_t)(a + 1), kind) << 8);
}

/* operand data (the default for LDA/STA/... targets) */
static uint8_t rd(uint16_t a)          { return rdk(a, M6502_ACC_DATA); }
static void    wr(uint16_t a, uint8_t v) { wrk(a, v, M6502_ACC_DATA); }

/* instruction stream: operand bytes trailing the opcode */
static uint8_t  rdc  (uint16_t a) { return rdk (a, M6502_ACC_OPERAND); }
static uint16_t rdc16(uint16_t a) { return rdk16(a, M6502_ACC_OPERAND); }

/* pointer indirection: the address itself is fetched from memory */
static uint8_t  rdp  (uint16_t a) { return rdk (a, M6502_ACC_PTR); }
static uint16_t rdp16w(uint16_t a) {  /* 6502 indirect-JMP page-wrap bug */
    uint16_t b = (a & 0xff00u) | (uint16_t)((a + 1) & 0x00ffu);
    return (uint16_t)rdp(a) | ((uint16_t)rdp(b) << 8);
}

/* interrupt / reset vectors */
static uint16_t rdv16(uint16_t a) { return rdk16(a, M6502_ACC_VECTOR); }

/* -------------------------------------------------------------------------
 * Stack helpers
 * ------------------------------------------------------------------------- */
static void    push8 (uint8_t  v) { wrk(0x0100u | g_cpu->sp--, v, M6502_ACC_STACK); }
static uint8_t pull8 (void)       { return rdk(0x0100u | (uint16_t)(++g_cpu->sp),
                                               M6502_ACC_STACK); }
static void    push16(uint16_t v) { push8((uint8_t)(v >> 8)); push8((uint8_t)v); }
static uint16_t pull16(void) {
    uint8_t lo = pull8(); uint8_t hi = pull8();
    return (uint16_t)lo | ((uint16_t)hi << 8);
}

/* -------------------------------------------------------------------------
 * Processor status register
 * ------------------------------------------------------------------------- */
uint8_t m6502_getP(const M6502 *cpu) {
    return (uint8_t)((cpu->n << 7) | (cpu->v << 6) | (1 << 5) |
                     (cpu->d << 3) | (cpu->i << 2) | (cpu->z << 1) | cpu->c);
}
void m6502_setP(M6502 *cpu, uint8_t p) {
    cpu->n = (p >> 7) & 1; cpu->v = (p >> 6) & 1;
    cpu->d = (p >> 3) & 1; cpu->i = (p >> 2) & 1;
    cpu->z = (p >> 1) & 1; cpu->c =  p       & 1;
}

static void calcZ  (uint8_t  v) { g_cpu->z = (v == 0); }
static void calcN  (uint8_t  v) { g_cpu->n = (v >> 7) & 1; }
static void calcZN (uint8_t  v) { calcZ(v); calcN(v); }
static void calcC16(uint16_t v) { g_cpu->c = (v >> 8) & 1; }
static void calcV  (uint16_t r, uint8_t a, uint16_t m) {
    g_cpu->v = (uint8_t)(((r ^ a) & (r ^ m) & 0x80u) != 0);
}

/* -------------------------------------------------------------------------
 * Addressing modes  (set g_ea; am_acc sets g_acc flag instead)
 * ------------------------------------------------------------------------- */
static void am_imp (void) { }
static void am_acc (void) { g_acc = 1; }
/* An immediate operand IS the instruction stream, so am_imm leaves g_ea
 * pointing into code; getval()/the opcode then reads it as OPERAND. */
static void am_imm (void) { g_ea = g_cpu->pc++; g_imm = 1; }
static void am_zp  (void) { g_ea = rdc(g_cpu->pc++); }
static void am_zpx (void) { g_ea = (rdc(g_cpu->pc++) + g_cpu->x) & 0xffu; }
static void am_zpy (void) { g_ea = (rdc(g_cpu->pc++) + g_cpu->y) & 0xffu; }
static void am_abs (void) { g_ea = rdc16(g_cpu->pc); g_cpu->pc += 2; }
static void am_rel (void) {
    uint8_t off = rdc(g_cpu->pc++);
    g_ea = (uint16_t)(g_cpu->pc + (int8_t)off);
}
static void am_absx(void) {
    uint16_t b = rdc16(g_cpu->pc); g_cpu->pc += 2;
    g_ea = b + g_cpu->x;
    g_paddr = (uint8_t)((b & 0xff00u) != (g_ea & 0xff00u));
}
static void am_absy(void) {
    uint16_t b = rdc16(g_cpu->pc); g_cpu->pc += 2;
    g_ea = b + g_cpu->y;
    g_paddr = (uint8_t)((b & 0xff00u) != (g_ea & 0xff00u));
}
static void am_ind (void) {
    uint16_t ptr = rdc16(g_cpu->pc); g_cpu->pc += 2;
    g_ea = rdp16w(ptr);
}
static void am_indx(void) {
    uint8_t ptr = (rdc(g_cpu->pc++) + g_cpu->x) & 0xffu;
    g_ea = (uint16_t)rdp(ptr) | ((uint16_t)rdp((ptr + 1) & 0xffu) << 8);
}
static void am_indy(void) {
    uint8_t ptr = rdc(g_cpu->pc++);
    uint16_t b  = (uint16_t)rdp(ptr) | ((uint16_t)rdp((ptr + 1) & 0xffu) << 8);
    g_ea = b + g_cpu->y;
    g_paddr = (uint8_t)((b & 0xff00u) != (g_ea & 0xff00u));
}

/* -------------------------------------------------------------------------
 * Operand access (respects accumulator vs memory)
 * ------------------------------------------------------------------------- */
static uint8_t getval(void) {
    if (g_acc) return g_cpu->a;
    return g_imm ? rdc(g_ea) : rd(g_ea);
}
static void    putval(uint8_t v) { if (g_acc) g_cpu->a = v; else wr(g_ea, v); }

/* -------------------------------------------------------------------------
 * Branch helper
 * ------------------------------------------------------------------------- */
static void branch(int cond) {
    if (cond) {
        uint16_t old = g_cpu->pc;
        g_cpu->pc = g_ea;
        g_ticks += ((old ^ g_cpu->pc) & 0xff00u) ? 2 : 1;
    }
}

/* -------------------------------------------------------------------------
 * Official opcodes
 * ------------------------------------------------------------------------- */
static void op_adc(void) {
    g_pop = 1;
    uint16_t v = getval();
    uint16_t r = (uint16_t)g_cpu->a + v + g_cpu->c;
    calcZ((uint8_t)r); calcV(r, g_cpu->a, v);
    if (!g_cpu->d) {
        calcC16(r); calcN((uint8_t)r);
    } else {
        uint16_t al = (g_cpu->a & 0x0fu) + (v & 0x0fu) + g_cpu->c;
        if (al >= 0x0au) al = ((al + 6) & 0x0fu) + 0x10u;
        al += (g_cpu->a & 0xf0u) + (v & 0xf0u);
        calcN((uint8_t)al); calcV(al, g_cpu->a, v);
        if (al >= 0xa0u) al += 0x60u;
        calcC16(al); r = al; g_ticks++;
    }
    g_cpu->a = (uint8_t)r;
}

static void op_sbc(void) {
    g_pop = 1;
    uint8_t  cc = g_cpu->c;
    uint16_t v  = getval() ^ 0xffu;
    uint16_t r  = (uint16_t)g_cpu->a + v + g_cpu->c;
    calcC16(r); calcZN((uint8_t)r); calcV(r, g_cpu->a, v);
    if (g_cpu->d) {
        uint16_t b  = v ^ 0xffu;
        int16_t  al = (int16_t)((g_cpu->a & 0x0fu) - (b & 0x0fu)) + cc - 1;
        if (al & 0x8000) al = ((al - 6) & 0x0fu) - 0x10;
        int16_t res = (int16_t)((g_cpu->a & 0xf0u) - (b & 0xf0u)) + al;
        if (res & 0x8000) res -= 0x60;
        r = (uint16_t)res; g_ticks++;
    }
    g_cpu->a = (uint8_t)r;
}

static void op_and(void) { g_pop = 1; calcZN(g_cpu->a &= getval()); }
static void op_eor(void) { g_pop = 1; calcZN(g_cpu->a ^= getval()); }
static void op_ora(void) { g_pop = 1; calcZN(g_cpu->a |= getval()); }
static void op_lda(void) { g_pop = 1; calcZN(g_cpu->a  = getval()); }
static void op_ldx(void) { g_pop = 1; calcZN(g_cpu->x  = getval()); }
static void op_ldy(void) { g_pop = 1; calcZN(g_cpu->y  = getval()); }
static void op_sta(void) { wr(g_ea, g_cpu->a); }
static void op_stx(void) { wr(g_ea, g_cpu->x); }
static void op_sty(void) { wr(g_ea, g_cpu->y); }

static void op_asl(void) {
    uint16_t r = (uint16_t)getval() << 1;
    calcC16(r); calcZN((uint8_t)r); putval((uint8_t)r);
}
static void op_lsr(void) {
    uint8_t v = getval(); g_cpu->c = v & 1; calcZN(v >>= 1); putval(v);
}
static void op_rol(void) {
    uint16_t r = ((uint16_t)getval() << 1) | g_cpu->c;
    calcC16(r); calcZN((uint8_t)r); putval((uint8_t)r);
}
static void op_ror(void) {
    uint8_t v = getval(), r = (v >> 1) | (g_cpu->c << 7);
    g_cpu->c = v & 1; calcZN(r); putval(r);
}
static void op_inc(void) { uint8_t r = getval() + 1; calcZN(r); putval(r); }
static void op_dec(void) { uint8_t r = getval() - 1; calcZN(r); putval(r); }

static void op_inx(void) { calcZN(++g_cpu->x); }
static void op_iny(void) { calcZN(++g_cpu->y); }
static void op_dex(void) { calcZN(--g_cpu->x); }
static void op_dey(void) { calcZN(--g_cpu->y); }
static void op_tax(void) { calcZN(g_cpu->x = g_cpu->a); }
static void op_tay(void) { calcZN(g_cpu->y = g_cpu->a); }
static void op_txa(void) { calcZN(g_cpu->a = g_cpu->x); }
static void op_tya(void) { calcZN(g_cpu->a = g_cpu->y); }
static void op_tsx(void) { calcZN(g_cpu->x = g_cpu->sp); }
static void op_txs(void) { g_cpu->sp = g_cpu->x; }

static void op_clc(void) { g_cpu->c = 0; }
static void op_sec(void) { g_cpu->c = 1; }
static void op_cld(void) { g_cpu->d = 0; }
static void op_sed(void) { g_cpu->d = 1; }
static void op_cli(void) { g_cpu->i = 0; }
static void op_sei(void) { g_cpu->i = 1; }
static void op_clv(void) { g_cpu->v = 0; }

static void cmp_reg(uint8_t reg, uint8_t val) {
    g_cpu->c = (reg >= val); g_cpu->z = (reg == val);
    calcN((uint8_t)(reg - val));
}
static void op_cmp(void) { g_pop = 1; cmp_reg(g_cpu->a, getval()); }
static void op_cpx(void) {             cmp_reg(g_cpu->x, getval()); }
static void op_cpy(void) {             cmp_reg(g_cpu->y, getval()); }

static void op_bit(void) {
    uint8_t v = getval();
    g_cpu->z = ((g_cpu->a & v) == 0);
    g_cpu->n = (v >> 7) & 1;
    g_cpu->v = (v >> 6) & 1;
}

static void op_bpl(void) { branch(!g_cpu->n); }
static void op_bmi(void) { branch( g_cpu->n); }
static void op_bvc(void) { branch(!g_cpu->v); }
static void op_bvs(void) { branch( g_cpu->v); }
static void op_bcc(void) { branch(!g_cpu->c); }
static void op_bcs(void) { branch( g_cpu->c); }
static void op_bne(void) { branch(!g_cpu->z); }
static void op_beq(void) { branch( g_cpu->z); }

static void op_jmp(void) { g_cpu->pc = g_ea; }
static void op_jsr(void) { push16(g_cpu->pc - 1); g_cpu->pc = g_ea; }
static void op_rts(void) { g_cpu->pc = pull16() + 1; }
static void op_rti(void) { m6502_setP(g_cpu, pull8()); g_cpu->pc = pull16(); }
static void op_brk(void) {
    g_cpu->pc++;                               /* skip padding byte */
    push16(g_cpu->pc);
    push8(m6502_getP(g_cpu) | 0x10u);         /* B flag set in pushed P */
    g_cpu->i = 1;
    g_cpu->pc = rdv16(0xfffeu);
}
static void op_pha(void) { push8(g_cpu->a); }
static void op_pla(void) { calcZN(g_cpu->a = pull8()); }
static void op_php(void) { push8(m6502_getP(g_cpu) | 0x10u); }
static void op_plp(void) { m6502_setP(g_cpu, pull8()); }
static void op_nop(void) {
    /* a few undocumented multi-byte NOPs have page-cross penalty */
    switch (g_op) {
        case 0x1c: case 0x3c: case 0x5c:
        case 0x7c: case 0xdc: case 0xfc: g_pop = 1; break;
        default: break;
    }
}

/* -------------------------------------------------------------------------
 * Undocumented (illegal) NMOS opcodes
 * ------------------------------------------------------------------------- */
static void op_SLO(void) { op_asl(); op_ora(); }
static void op_RLA(void) { op_rol(); op_and(); g_pop = 0; }
static void op_SRE(void) { op_lsr(); op_eor(); g_pop = 0; }
static void op_RRA(void) { op_ror(); op_adc(); g_pop = 0; if (g_cpu->d) g_ticks--; }
static void op_SAX(void) { wr(g_ea, g_cpu->a & g_cpu->x); }
static void op_LAX(void) { g_pop = 1; op_lda(); op_ldx(); }
static void op_DCP(void) { op_dec(); op_cmp(); g_pop = 0; }
static void op_ISC(void) { op_inc(); op_sbc(); g_pop = 0; if (g_cpu->d) g_ticks--; }
static void op_ANC(void) { op_and(); g_cpu->c = (g_cpu->a >> 7) & 1; }
static void op_ALR(void) { op_and(); g_cpu->c = g_cpu->a & 1; g_cpu->a >>= 1; calcZN(g_cpu->a); }
static void op_LAS(void) { g_pop = 1; calcZN(g_cpu->sp = g_cpu->a = g_cpu->x = getval() & g_cpu->sp); }
static void op_JAM(void) { g_cpu->pc--; }   /* CPU freeze: loop on same opcode */

static void op_ARR(void) {
    op_and();
    uint8_t pre = g_cpu->a;
    g_cpu->a = (g_cpu->a >> 1) | (g_cpu->c << 7); calcZN(g_cpu->a);
    if (!g_cpu->d) {
        g_cpu->c = (g_cpu->a >> 6) & 1;
        g_cpu->v = g_cpu->c ^ ((g_cpu->a >> 5) & 1);
    } else {
        g_cpu->v = (uint8_t)(((g_cpu->a ^ pre) & 0x40u) != 0);
        if (((pre & 0x0fu) + (pre & 1)) > 5)
            g_cpu->a = (g_cpu->a & 0xf0u) | ((g_cpu->a + 6) & 0x0fu);
        if ((uint16_t)pre + (pre & 0x10u) >= 0x60u) { g_cpu->a += 0x60u; g_cpu->c = 1; }
        else g_cpu->c = 0;
    }
}
static void op_SBX(void) {
    uint8_t v = getval(); g_cpu->x &= g_cpu->a;
    cmp_reg(g_cpu->x, v); g_cpu->x -= v;
}
static void op_SHA(void) { wr(g_ea, g_cpu->a & g_cpu->x & (uint8_t)((g_ea >> 8) + 1)); }
static void op_SHX(void) {
    uint8_t v = g_cpu->x & (uint8_t)(((g_ea - g_cpu->y) >> 8) + 1);
    if (((g_ea - g_cpu->y) & 0xffu) + g_cpu->y > 0xffu)
        g_ea = (g_ea & 0xffu) | ((uint16_t)v << 8);
    wr(g_ea, v);
}
static void op_SHY(void) {
    uint8_t v = g_cpu->y & (uint8_t)(((g_ea - g_cpu->x) >> 8) + 1);
    if (((g_ea - g_cpu->x) & 0xffu) + g_cpu->x > 0xffu)
        g_ea = (g_ea & 0xffu) | ((uint16_t)v << 8);
    wr(g_ea, v);
}
static void op_TAS(void) { g_cpu->sp = g_cpu->a & g_cpu->x; wr(g_ea, g_cpu->sp & (uint8_t)((g_ea >> 8) + 1)); }
static void op_ANE(void) { calcZN(g_cpu->a = (g_cpu->a | 0xefu) & g_cpu->x & getval()); }
static void op_LXA(void) { calcZN(g_cpu->a = g_cpu->x = (g_cpu->a | 0xeeu) & getval()); }

/* -------------------------------------------------------------------------
 * Dispatch tables
 * ------------------------------------------------------------------------- */
static void (*const g_at[256])(void) = {
/*       0       1       2       3       4       5       6       7       8       9       A       B       C       D       E       F    */
/* 0 */am_imp,am_indx,am_imp,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_acc, am_imm,am_abs, am_abs,am_abs, am_abs,
/* 1 */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
/* 2 */am_abs,am_indx,am_imp,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_acc, am_imm,am_abs, am_abs,am_abs, am_abs,
/* 3 */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
/* 4 */am_imp,am_indx,am_imp,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_acc, am_imm,am_abs, am_abs,am_abs, am_abs,
/* 5 */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
/* 6 */am_imp,am_indx,am_imp,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_acc, am_imm, am_ind,am_abs, am_abs,am_abs,
/* 7 */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
/* 8 */am_imm,am_indx,am_imm,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_imp, am_imm,am_abs, am_abs,am_abs, am_abs,
/* 9 */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpy,am_zpy,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absy,am_absy,
/* A */am_imm,am_indx,am_imm,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_imp, am_imm,am_abs, am_abs,am_abs, am_abs,
/* B */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpy,am_zpy,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absy,am_absy,
/* C */am_imm,am_indx,am_imm,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_imp, am_imm,am_abs, am_abs,am_abs, am_abs,
/* D */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
/* E */am_imm,am_indx,am_imm,am_indx, am_zp, am_zp, am_zp, am_zp,am_imp, am_imm,am_imp, am_imm,am_abs, am_abs,am_abs, am_abs,
/* F */am_rel,am_indy,am_imp,am_indy,am_zpx,am_zpx,am_zpx,am_zpx,am_imp,am_absy,am_imp,am_absy,am_absx,am_absx,am_absx,am_absx,
};

static void (*const g_ot[256])(void) = {
/*       0        1       2        3        4       5       6        7        8       9        A        B        C       D       E        F    */
/* 0 */op_brk, op_ora, op_JAM,  op_SLO,  op_nop, op_ora, op_asl,  op_SLO,  op_php, op_ora,  op_asl,  op_ANC,  op_nop, op_ora, op_asl,  op_SLO,
/* 1 */op_bpl, op_ora, op_JAM,  op_SLO,  op_nop, op_ora, op_asl,  op_SLO,  op_clc, op_ora,  op_nop,  op_SLO,  op_nop, op_ora, op_asl,  op_SLO,
/* 2 */op_jsr, op_and, op_JAM,  op_RLA,  op_bit, op_and, op_rol,  op_RLA,  op_plp, op_and,  op_rol,  op_ANC,  op_bit, op_and, op_rol,  op_RLA,
/* 3 */op_bmi, op_and, op_JAM,  op_RLA,  op_nop, op_and, op_rol,  op_RLA,  op_sec, op_and,  op_nop,  op_RLA,  op_nop, op_and, op_rol,  op_RLA,
/* 4 */op_rti, op_eor, op_JAM,  op_SRE,  op_nop, op_eor, op_lsr,  op_SRE,  op_pha, op_eor,  op_lsr,  op_ALR,  op_jmp, op_eor, op_lsr,  op_SRE,
/* 5 */op_bvc, op_eor, op_JAM,  op_SRE,  op_nop, op_eor, op_lsr,  op_SRE,  op_cli, op_eor,  op_nop,  op_SRE,  op_nop, op_eor, op_lsr,  op_SRE,
/* 6 */op_rts, op_adc, op_JAM,  op_RRA,  op_nop, op_adc, op_ror,  op_RRA,  op_pla, op_adc,  op_ror,  op_ARR,  op_jmp, op_adc, op_ror,  op_RRA,
/* 7 */op_bvs, op_adc, op_JAM,  op_RRA,  op_nop, op_adc, op_ror,  op_RRA,  op_sei, op_adc,  op_nop,  op_RRA,  op_nop, op_adc, op_ror,  op_RRA,
/* 8 */op_nop, op_sta, op_nop,  op_SAX,  op_sty, op_sta, op_stx,  op_SAX,  op_dey, op_nop,  op_txa,  op_ANE,  op_sty, op_sta, op_stx,  op_SAX,
/* 9 */op_bcc, op_sta, op_JAM,  op_SHA,  op_sty, op_sta, op_stx,  op_SAX,  op_tya, op_sta,  op_txs,  op_TAS,  op_SHY,op_sta,  op_SHX,  op_SHA,
/* A */op_ldy, op_lda, op_ldx,  op_LAX,  op_ldy, op_lda, op_ldx,  op_LAX,  op_tay, op_lda,  op_tax,  op_LXA,  op_ldy, op_lda, op_ldx,  op_LAX,
/* B */op_bcs, op_lda, op_JAM,  op_LAX,  op_ldy, op_lda, op_ldx,  op_LAX,  op_clv, op_lda,  op_tsx,  op_LAS,  op_ldy, op_lda, op_ldx,  op_LAX,
/* C */op_cpy, op_cmp, op_nop,  op_DCP,  op_cpy, op_cmp, op_dec,  op_DCP,  op_iny, op_cmp,  op_dex,  op_SBX,  op_cpy, op_cmp, op_dec,  op_DCP,
/* D */op_bne, op_cmp, op_JAM,  op_DCP,  op_nop, op_cmp, op_dec,  op_DCP,  op_cld, op_cmp,  op_nop,  op_DCP,  op_nop, op_cmp, op_dec,  op_DCP,
/* E */op_cpx, op_sbc, op_nop,  op_ISC,  op_cpx, op_sbc, op_inc,  op_ISC,  op_inx, op_sbc,  op_nop,  op_sbc,  op_cpx, op_sbc, op_inc,  op_ISC,
/* F */op_beq, op_sbc, op_JAM,  op_ISC,  op_nop, op_sbc, op_inc,  op_ISC,  op_sed, op_sbc,  op_nop,  op_ISC,  op_nop, op_sbc, op_inc,  op_ISC,
};

/* base cycle counts per opcode */
static const uint8_t g_tt[256] = {
    7,6,2,8,3,3,5,5,3,2,2,2,4,4,6,6,  /* 0x */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* 1x */
    6,6,2,8,3,3,5,5,4,2,2,2,4,4,6,6,  /* 2x */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* 3x */
    6,6,2,8,3,3,5,5,3,2,2,2,3,4,6,6,  /* 4x */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* 5x */
    6,6,2,8,3,3,5,5,4,2,2,2,5,4,6,6,  /* 6x */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* 7x */
    2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4,  /* 8x */
    2,6,2,6,4,4,4,4,2,5,2,5,5,5,5,5,  /* 9x */
    2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4,  /* Ax */
    2,5,2,5,4,4,4,4,2,4,2,4,4,4,4,4,  /* Bx */
    2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6,  /* Cx */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* Dx */
    2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6,  /* Ex */
    2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,  /* Fx */
};

/* -------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */
void m6502_init(M6502 *cpu, m6502_read_fn read, m6502_write_fn write, void *ctx) {
    memset(cpu, 0, sizeof *cpu);
    cpu->read = read; cpu->write = write; cpu->ctx = ctx;
}

int m6502_reset(M6502 *cpu) {
    g_cpu = cpu;
    cpu->sp = 0xfd;
    cpu->a = cpu->x = cpu->y = 0;
    cpu->c = cpu->z = cpu->d = cpu->v = cpu->n = 0; cpu->i = 1;
    cpu->pc = rdv16(0xfffcu);
    cpu->cycles += 7;
    return 7;
}
int m6502_nmi(M6502 *cpu) {
    g_cpu = cpu;
    push16(cpu->pc); push8(m6502_getP(cpu) & ~0x10u);
    cpu->i = 1; cpu->pc = rdv16(0xfffau);
    cpu->cycles += 7; return 7;
}
int m6502_irq(M6502 *cpu) {
    if (cpu->i) return 0;
    g_cpu = cpu;
    push16(cpu->pc); push8(m6502_getP(cpu) & ~0x10u);
    cpu->i = 1; cpu->pc = rdv16(0xfffeu);
    cpu->cycles += 7; return 7;
}
int m6502_step(M6502 *cpu) {
    g_cpu = cpu; g_paddr = g_pop = g_acc = g_imm = 0;
    g_op = rdk(cpu->pc++, M6502_ACC_OPCODE);
    g_ticks = g_tt[g_op];
    g_at[g_op](); g_ot[g_op]();
    if (g_pop && g_paddr) g_ticks++;
    cpu->cycles += g_ticks;
    return (int)g_ticks;
}

/* -------------------------------------------------------------------------
 * Disassembler
 * ------------------------------------------------------------------------- */
static const char * const g_mn[256] = {
    "BRK","ORA","JAM","SLO","NOP","ORA","ASL","SLO","PHP","ORA","ASL","ANC","NOP","ORA","ASL","SLO",
    "BPL","ORA","JAM","SLO","NOP","ORA","ASL","SLO","CLC","ORA","NOP","SLO","NOP","ORA","ASL","SLO",
    "JSR","AND","JAM","RLA","BIT","AND","ROL","RLA","PLP","AND","ROL","ANC","BIT","AND","ROL","RLA",
    "BMI","AND","JAM","RLA","NOP","AND","ROL","RLA","SEC","AND","NOP","RLA","NOP","AND","ROL","RLA",
    "RTI","EOR","JAM","SRE","NOP","EOR","LSR","SRE","PHA","EOR","LSR","ALR","JMP","EOR","LSR","SRE",
    "BVC","EOR","JAM","SRE","NOP","EOR","LSR","SRE","CLI","EOR","NOP","SRE","NOP","EOR","LSR","SRE",
    "RTS","ADC","JAM","RRA","NOP","ADC","ROR","RRA","PLA","ADC","ROR","ARR","JMP","ADC","ROR","RRA",
    "BVS","ADC","JAM","RRA","NOP","ADC","ROR","RRA","SEI","ADC","NOP","RRA","NOP","ADC","ROR","RRA",
    "NOP","STA","NOP","SAX","STY","STA","STX","SAX","DEY","NOP","TXA","ANE","STY","STA","STX","SAX",
    "BCC","STA","JAM","SHA","STY","STA","STX","SAX","TYA","STA","TXS","TAS","SHY","STA","SHX","SHA",
    "LDY","LDA","LDX","LAX","LDY","LDA","LDX","LAX","TAY","LDA","TAX","LXA","LDY","LDA","LDX","LAX",
    "BCS","LDA","JAM","LAX","LDY","LDA","LDX","LAX","CLV","LDA","TSX","LAS","LDY","LDA","LDX","LAX",
    "CPY","CMP","NOP","DCP","CPY","CMP","DEC","DCP","INY","CMP","DEX","SBX","CPY","CMP","DEC","DCP",
    "BNE","CMP","JAM","DCP","NOP","CMP","DEC","DCP","CLD","CMP","NOP","DCP","NOP","CMP","DEC","DCP",
    "CPX","SBC","NOP","ISC","CPX","SBC","INC","ISC","INX","SBC","NOP","SBC","CPX","SBC","INC","ISC",
    "BEQ","SBC","JAM","ISC","NOP","SBC","INC","ISC","SED","SBC","NOP","ISC","NOP","SBC","INC","ISC"
};

/* mode codes: 0=imp 1=acc 2=imm 3=zp 4=zpx 5=zpy 6=abs 7=absx 8=absy 9=ind 10=indx 11=indy 12=rel */
static const uint8_t g_dm[256] = {
/*     0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F  */
/* 0*/ 0, 10,  0, 10,  3,  3,  3,  3,  0,  2,  1,  2,  6,  6,  6,  6,
/* 1*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
/* 2*/ 6, 10,  0, 10,  3,  3,  3,  3,  0,  2,  1,  2,  6,  6,  6,  6,
/* 3*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
/* 4*/ 0, 10,  0, 10,  3,  3,  3,  3,  0,  2,  1,  2,  6,  6,  6,  6,
/* 5*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
/* 6*/ 0, 10,  0, 10,  3,  3,  3,  3,  0,  2,  1,  2,  9,  6,  6,  6,
/* 7*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
/* 8*/ 2, 10,  2, 10,  3,  3,  3,  3,  0,  2,  0,  2,  6,  6,  6,  6,
/* 9*/12, 11,  0, 11,  4,  4,  5,  5,  0,  8,  0,  8,  7,  7,  8,  8,
/* A*/ 2, 10,  2, 10,  3,  3,  3,  3,  0,  2,  0,  2,  6,  6,  6,  6,
/* B*/12, 11,  0, 11,  4,  4,  5,  5,  0,  8,  0,  8,  7,  7,  8,  8,
/* C*/ 2, 10,  2, 10,  3,  3,  3,  3,  0,  2,  0,  2,  6,  6,  6,  6,
/* D*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
/* E*/ 2, 10,  2, 10,  3,  3,  3,  3,  0,  2,  0,  2,  6,  6,  6,  6,
/* F*/12, 11,  0, 11,  4,  4,  4,  4,  0,  8,  0,  8,  7,  7,  7,  7,
};

static const int g_dl[13] = { 1,1,2,2,2,2,3,3,3,3,2,2,2 };

int m6502_disasm(m6502_read_fn read, void *ctx,
                 uint16_t addr, char *buf, size_t sz)
{
    int i;
    uint8_t  op   = read(ctx, addr);
    int      mode = g_dm[op];
    int      len  = g_dl[mode];
    uint8_t  b1   = read(ctx, (uint16_t)(addr + 1));
    uint8_t  b2   = read(ctx, (uint16_t)(addr + 2));
    uint16_t w    = (uint16_t)b1 | ((uint16_t)b2 << 8);
    char oper[20] = "";

    switch (mode) {
        case  0: break;
        case  1: snprintf(oper, sizeof oper, "A");            break;
        case  2: snprintf(oper, sizeof oper, "#$%02X",   b1); break;
        case  3: snprintf(oper, sizeof oper, "$%02X",    b1); break;
        case  4: snprintf(oper, sizeof oper, "$%02X,X",  b1); break;
        case  5: snprintf(oper, sizeof oper, "$%02X,Y",  b1); break;
        case  6: snprintf(oper, sizeof oper, "$%04X",    w);  break;
        case  7: snprintf(oper, sizeof oper, "$%04X,X",  w);  break;
        case  8: snprintf(oper, sizeof oper, "$%04X,Y",  w);  break;
        case  9: snprintf(oper, sizeof oper, "($%04X)",  w);  break;
        case 10: snprintf(oper, sizeof oper, "($%02X,X)", b1); break;
        case 11: snprintf(oper, sizeof oper, "($%02X),Y", b1); break;
        case 12: {
            uint16_t t = (uint16_t)(addr + 2 + (int8_t)b1);
            snprintf(oper, sizeof oper, "$%04X", t); break;
        }
    }
    char byt[12] = "";
    for (i = 0; i < len; i++) {
        char tmp[4];
        snprintf(tmp, sizeof tmp, "%02X ", read(ctx, (uint16_t)(addr + i)));
        strcat(byt, tmp);
    }
    snprintf(buf, sz, "$%04X: %-9s %-4s %s", addr, byt, g_mn[op], oper);
    return len;
}
