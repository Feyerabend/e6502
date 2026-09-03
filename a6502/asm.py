#!/usr/bin/env python3
"""
a6502.py  --  MOS 6502 two-pass assembler
Pure Python 3, standard library only.

Syntax
------
    label:              ; define label at current address
    name  = expr        ; constant (EQU)
    .org  addr          ; set origin
    .byte b, ...        ; emit byte(s)
    .word w, ...        ; emit 16-bit word(s), little-endian
    .asc  "text"        ; emit ASCII bytes  (.text / .ascii also accepted)
    .fill n [, val]     ; emit n copies of val (default 0)
    mnemonic [operand]  ; 6502 instruction

Operand syntax (numbers: $hex  %binary  decimal)
    (nothing)           implied
    A                   accumulator
    #expr               immediate
    expr                ZP or absolute (auto-selected), or branch target
    expr,X              ZP,X or abs,X
    expr,Y              ZP,Y or abs,Y
    (expr,X)            (indirect,X)
    (expr),Y            (indirect),Y
    (expr)              indirect [JMP only]

Expression operators (ascending precedence: leftmost binds least)
    + -                 add, subtract
    * / %               multiply, int-divide, modulo
    < expr              low byte  (& $FF)
    > expr              high byte (>> 8)
    - expr              negate
    *                   current PC (nullary atom)
    $hh  %bb  ddd       literals
    name                symbol
    ( )                 grouping

Usage
-----
    python3 asm.py source.asm [output.bin] [-v]
"""

import sys, re, os


# Opcode tables (256 entries each)

_MN = (
    'brk','ora','jam','slo','nop','ora','asl','slo','php','ora','asl','anc','nop','ora','asl','slo',
    'bpl','ora','jam','slo','nop','ora','asl','slo','clc','ora','nop','slo','nop','ora','asl','slo',
    'jsr','and','jam','rla','bit','and','rol','rla','plp','and','rol','anc','bit','and','rol','rla',
    'bmi','and','jam','rla','nop','and','rol','rla','sec','and','nop','rla','nop','and','rol','rla',
    'rti','eor','jam','sre','nop','eor','lsr','sre','pha','eor','lsr','alr','jmp','eor','lsr','sre',
    'bvc','eor','jam','sre','nop','eor','lsr','sre','cli','eor','nop','sre','nop','eor','lsr','sre',
    'rts','adc','jam','rra','nop','adc','ror','rra','pla','adc','ror','arr','jmp','adc','ror','rra',
    'bvs','adc','jam','rra','nop','adc','ror','rra','sei','adc','nop','rra','nop','adc','ror','rra',
    'nop','sta','nop','sax','sty','sta','stx','sax','dey','nop','txa','ane','sty','sta','stx','sax',
    'bcc','sta','jam','sha','sty','sta','stx','sax','tya','sta','txs','tas','shy','sta','shx','sha',
    'ldy','lda','ldx','lax','ldy','lda','ldx','lax','tay','lda','tax','lxa','ldy','lda','ldx','lax',
    'bcs','lda','jam','lax','ldy','lda','ldx','lax','clv','lda','tsx','las','ldy','lda','ldx','lax',
    'cpy','cmp','nop','dcp','cpy','cmp','dec','dcp','iny','cmp','dex','sbx','cpy','cmp','dec','dcp',
    'bne','cmp','jam','dcp','nop','cmp','dec','dcp','cld','cmp','nop','dcp','nop','cmp','dec','dcp',
    'cpx','sbc','nop','isc','cpx','sbc','inc','isc','inx','sbc','nop','sbc','cpx','sbc','inc','isc',
    'beq','sbc','jam','isc','nop','sbc','inc','isc','sed','sbc','nop','isc','nop','sbc','inc','isc',
)
_AM = (
    'imp','indx','imp','indx','zp','zp','zp','zp','imp','imm','acc','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
    'abso','indx','imp','indx','zp','zp','zp','zp','imp','imm','acc','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
    'imp','indx','imp','indx','zp','zp','zp','zp','imp','imm','acc','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
    'imp','indx','imp','indx','zp','zp','zp','zp','imp','imm','acc','imm','ind','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
    'imm','indx','imm','indx','zp','zp','zp','zp','imp','imm','imp','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpy','zpy','imp','absy','imp','absy','absx','absx','absy','absy',
    'imm','indx','imm','indx','zp','zp','zp','zp','imp','imm','imp','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpy','zpy','imp','absy','imp','absy','absx','absx','absy','absy',
    'imm','indx','imm','indx','zp','zp','zp','zp','imp','imm','imp','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
    'imm','indx','imm','indx','zp','zp','zp','zp','imp','imm','imp','imm','abso','abso','abso','abso',
    'rel','indy','imp','indy','zpx','zpx','zpx','zpx','imp','absy','imp','absy','absx','absx','absx','absx',
)

OPCODES = {}
for _i in range(256):
    OPCODES.setdefault(_MN[_i], {})[_AM[_i]] = _i

BRANCHES = frozenset({'bcc','bcs','beq','bmi','bne','bpl','bvc','bvs'})
ACC_OPS  = frozenset({'asl','lsr','rol','ror'})
ALL_MN   = frozenset(OPCODES)


# Errors

class AsmError(Exception):
    pass

class _Undef(Exception):
    """Raised inside _eval when a symbol is undefined and allow_undef=True."""


# Expression evaluator  (recursive descent, no extra imports)

def _eval(text, syms, pc, lnum, allow_undef=False):
    """Parse and evaluate an integer expression string.

    Returns int.
    If allow_undef=True and any symbol is undefined, raises _Undef.
    """
    src = text.strip()
    i   = [0]   # mutable cursor

    def skip():
        while i[0] < len(src) and src[i[0]] == ' ':
            i[0] += 1

    def peek():
        skip()
        return src[i[0]] if i[0] < len(src) else ''

    def eat(ch=None):
        skip()
        if i[0] >= len(src):
            raise AsmError(f"Line {lnum}: Unexpected end of '{text}'")
        c = src[i[0]]; i[0] += 1
        if ch and c != ch:
            raise AsmError(f"Line {lnum}: Expected '{ch}', got '{c}' in '{text}'")
        return c

    def primary():
        c = peek()

        if c == '(':
            eat('('); v = additive()
            if peek() != ')':
                raise AsmError(f"Line {lnum}: Missing ')' in '{text}'")
            eat(')'); return v

        if c == '*':           # current PC (only in atom position)
            eat(); return pc

        if c == '<':           # low-byte prefix
            eat(); return primary() & 0xFF

        if c == '>':           # high-byte prefix
            eat(); return (primary() >> 8) & 0xFF

        if c == '-':           # unary negate
            eat(); return -primary()

        if c == '+':           # unary plus (no-op)
            eat(); return primary()

        if c == "'":           # character literal  'x'
            eat()
            if i[0] >= len(src):
                raise AsmError(f"Line {lnum}: Unterminated character literal in '{text}'")
            ch = src[i[0]]; i[0] += 1
            if i[0] < len(src) and src[i[0]] == "'":
                i[0] += 1   # consume closing quote (optional but tidy)
            return ord(ch)

        if c == '$':           # hex literal
            eat()
            s = i[0]
            while i[0] < len(src) and src[i[0]] in '0123456789abcdefABCDEF':
                i[0] += 1
            if i[0] == s:
                raise AsmError(f"Line {lnum}: Expected hex digits after '$'")
            return int(src[s:i[0]], 16)

        if c == '%':           # binary literal
            eat()
            s = i[0]
            while i[0] < len(src) and src[i[0]] in '01':
                i[0] += 1
            if i[0] == s:
                raise AsmError(f"Line {lnum}: Expected binary digits after '%'")
            return int(src[s:i[0]], 2)

        if c == '0' and i[0]+1 < len(src) and src[i[0]+1].lower() == 'x':
            i[0] += 2          # 0x hex
            s = i[0]
            while i[0] < len(src) and src[i[0]] in '0123456789abcdefABCDEF':
                i[0] += 1
            return int(src[s:i[0]], 16)

        if c.isdigit():        # decimal
            s = i[0]
            while i[0] < len(src) and src[i[0]].isdigit():
                i[0] += 1
            return int(src[s:i[0]])

        if c.isalpha() or c == '_':   # symbol
            s = i[0]
            while i[0] < len(src) and (src[i[0]].isalnum() or src[i[0]] == '_'):
                i[0] += 1
            name = src[s:i[0]]
            if name in syms:
                return syms[name]
            if allow_undef:
                raise _Undef(name)
            raise AsmError(f"Line {lnum}: Undefined symbol '{name}'")

        raise AsmError(f"Line {lnum}: Unexpected '{c}' in '{text}'")

    def multiplicative():
        left = primary()
        while True:
            c = peek()
            if c == '*':
                eat(); left *= primary()
            elif c == '/':
                eat(); r = primary()
                if r == 0:
                    raise AsmError(f"Line {lnum}: Division by zero")
                left //= r
            elif c == '%':
                eat(); left %= primary()
            else:
                break
        return left

    def additive():
        left = multiplicative()
        while True:
            c = peek()
            if c == '+': eat(); left += multiplicative()
            elif c == '-': eat(); left -= multiplicative()
            else: break
        return left

    result = additive()
    skip()
    if i[0] < len(src):
        raise AsmError(
            f"Line {lnum}: Junk after expression: '{src[i[0]:]}' in '{text}'")
    return result


def _try_eval(text, syms, pc, lnum):
    """Like _eval but returns None if any symbol is not yet defined."""
    try:
        return _eval(text, syms, pc, lnum, allow_undef=True)
    except _Undef:
        return None


# Line parser

_LABEL_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*')
_EQU_RE   = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$')
_DIR_RE   = re.compile(r'^\.(org|byte|word|asc|text|ascii|fill)\b\s*', re.I)
_MN_RE    = re.compile(r'^([A-Za-z]{2,4})(?:\s+(.+))?$')

_INDX_RE  = re.compile(r'^\((.+),\s*[xX]\)$')
_INDY_RE  = re.compile(r'^\((.+)\),\s*[yY]$')
_IND_RE   = re.compile(r'^\((.+)\)$')
_COMMX_RE = re.compile(r'^(.+),\s*[xX]$')
_COMMY_RE = re.compile(r'^(.+),\s*[yY]$')


def _strip_comment(src):
    """Remove ';' comment, respecting double-quoted strings."""
    in_q = False
    out  = []
    for c in src:
        if c == '"': in_q = not in_q
        if c == ';' and not in_q: break
        out.append(c)
    return ''.join(out).rstrip()


def parse_line(src, lnum):
    """Parse one source line.  Returns dict with any of:
       label, equ, dir, args, mnem, op
    Returns {} for blank/comment-only lines."""
    src = _strip_comment(src).strip()
    if not src:
        return {}

    result = {}
    rest   = src

    # constant:  name = expr
    m = _EQU_RE.match(rest)
    if m:
        result['label'] = m.group(1)
        result['equ']   = m.group(2).strip()
        return result

    # optional label:
    m = _LABEL_RE.match(rest)
    if m:
        result['label'] = m.group(1)
        rest = rest[m.end():].strip()
        if not rest:
            return result

    # directive:  .name args
    m = _DIR_RE.match(rest)
    if m:
        raw  = m.group(1).lower()
        name = {'text': 'asc', 'ascii': 'asc'}.get(raw, raw)
        result['dir'] = name
        arg_text = rest[m.end():].strip()

        if name == 'asc':
            if not (arg_text.startswith('"') and arg_text.endswith('"')
                    and len(arg_text) >= 2):
                raise AsmError(f"Line {lnum}: .asc expects a double-quoted string")
            result['args'] = [arg_text[1:-1]]
        elif name == 'fill':
            result['args'] = [p.strip() for p in arg_text.split(',', 1)]
        else:
            result['args'] = [p.strip() for p in arg_text.split(',')]
        return result

    # instruction:  mnemonic [operand]
    m = _MN_RE.match(rest)
    if m:
        mn = m.group(1).lower()
        if mn in ALL_MN:
            result['mnem'] = mn
            result['op']   = (m.group(2) or '').strip()
            return result

    raise AsmError(f"Line {lnum}: Cannot parse '{src}'")


def classify_operand(op):
    """Return (hint, expr_text).

    hint is one of:
        'imp'   implied
        'acc'   accumulator A
        'imm'   #expr
        'indx'  (expr,X)
        'indy'  (expr),Y
        'ind'   (expr)   -- JMP indirect
        'x'     expr,X   -- zpx or absx
        'y'     expr,Y   -- zpy or absy
        'plain' expr     -- zp, abso, or branch rel
    """
    t = op.strip()
    if not t:            return 'imp',   ''
    if t.upper() == 'A': return 'acc',   ''
    if t.startswith('#'): return 'imm',  t[1:].strip()

    m = _INDX_RE.match(t)
    if m: return 'indx', m.group(1).strip()
    m = _INDY_RE.match(t)
    if m: return 'indy', m.group(1).strip()
    m = _IND_RE.match(t)
    if m: return 'ind',  m.group(1).strip()
    m = _COMMX_RE.match(t)
    if m: return 'x',    m.group(1).strip()
    m = _COMMY_RE.match(t)
    if m: return 'y',    m.group(1).strip()

    return 'plain', t


# Two-pass assembler

class Assembler:
    def __init__(self, verbose=False):
        self.verbose = verbose

    def assemble(self, source):
        """Assemble source string.  Returns (bytes, origin_address)."""
        # pre-parse all lines so errors include the source text
        parsed = []
        for lnum, raw in enumerate(source.splitlines(), 1):
            try:
                parsed.append((lnum, raw, parse_line(raw, lnum)))
            except AsmError as e:
                self._die(e, raw)

        syms   = {}
        memory = {}
        origin = [None]

        def emit(addr, byte):
            if origin[0] is None:
                origin[0] = addr
            memory[addr] = byte & 0xFF

        def need(mn, mode, lnum, raw):
            tbl = OPCODES.get(mn, {})
            if mode not in tbl:
                raise AsmError(
                    f"Line {lnum}: No opcode for '{mn}' mode '{mode}'")
            return tbl[mode]

        # ---- pass 1: collect labels / estimate sizes ----
        pc = 0
        for lnum, raw, d in parsed:
            if not d:
                continue
            try:
                if 'equ' in d:
                    val = _eval(d['equ'], syms, pc, lnum)
                    syms[d['label']] = val
                    if self.verbose:
                        print(f"  equ  {d['label']} = ${val:04X}")
                    continue

                if 'label' in d:
                    syms[d['label']] = pc
                    if self.verbose:
                        print(f"  lbl  {d['label']} = ${pc:04X}")

                if 'dir' in d:
                    dn = d['dir']
                    if dn == 'org':
                        pc = _eval(d['args'][0], syms, pc, lnum)
                        if origin[0] is None:
                            origin[0] = pc
                    elif dn == 'byte':
                        pc += len(d['args'])
                    elif dn == 'word':
                        pc += len(d['args']) * 2
                    elif dn == 'asc':
                        pc += len(d['args'][0])
                    elif dn == 'fill':
                        pc += _eval(d['args'][0], syms, pc, lnum)
                    continue

                if 'mnem' in d:
                    hint, et = classify_operand(d.get('op', ''))
                    pc += self._size(d['mnem'], hint, et, syms, pc, lnum)

            except AsmError as e:
                self._die(e, raw)

        # ---- pass 2: emit code ----
        pc = 0
        for lnum, raw, d in parsed:
            if not d:
                continue
            try:
                if 'equ' in d:
                    continue

                if 'dir' in d:
                    dn = d['dir']
                    if dn == 'org':
                        pc = _eval(d['args'][0], syms, pc, lnum)
                    elif dn == 'byte':
                        for a in d['args']:
                            emit(pc, _eval(a, syms, pc, lnum)); pc += 1
                    elif dn == 'word':
                        for a in d['args']:
                            v = _eval(a, syms, pc, lnum)
                            emit(pc, v & 0xFF);        pc += 1
                            emit(pc, (v >> 8) & 0xFF); pc += 1
                    elif dn == 'asc':
                        for ch in d['args'][0]:
                            emit(pc, ord(ch)); pc += 1
                    elif dn == 'fill':
                        n   = _eval(d['args'][0], syms, pc, lnum)
                        val = (_eval(d['args'][1], syms, pc, lnum)
                               if len(d['args']) > 1 else 0)
                        for _ in range(n):
                            emit(pc, val); pc += 1
                    continue

                if 'mnem' not in d:
                    continue

                mn        = d['mnem']
                hint, et  = classify_operand(d.get('op', ''))

                if hint == 'imp':
                    mode = ('acc'
                            if (mn in ACC_OPS and 'acc' in OPCODES.get(mn, {}))
                            else 'imp')
                    emit(pc, need(mn, mode, lnum, raw)); pc += 1

                elif hint == 'acc':
                    emit(pc, need(mn, 'acc', lnum, raw)); pc += 1

                elif hint == 'imm':
                    v = _eval(et, syms, pc, lnum)
                    emit(pc, need(mn, 'imm', lnum, raw)); pc += 1
                    emit(pc, v & 0xFF);                   pc += 1

                elif hint == 'indx':
                    v = _eval(et, syms, pc, lnum)
                    emit(pc, need(mn, 'indx', lnum, raw)); pc += 1
                    emit(pc, v & 0xFF);                    pc += 1

                elif hint == 'indy':
                    v = _eval(et, syms, pc, lnum)
                    emit(pc, need(mn, 'indy', lnum, raw)); pc += 1
                    emit(pc, v & 0xFF);                    pc += 1

                elif hint == 'ind':
                    v = _eval(et, syms, pc, lnum)
                    emit(pc, need(mn, 'ind', lnum, raw)); pc += 1
                    emit(pc, v & 0xFF);                   pc += 1
                    emit(pc, (v >> 8) & 0xFF);            pc += 1

                elif hint in ('x', 'y'):
                    v  = _eval(et, syms, pc, lnum)
                    zp = (0 <= v <= 0xFF)
                    if hint == 'x':
                        mode = ('zpx' if (zp and 'zpx' in OPCODES.get(mn, {}))
                                else 'absx')
                    else:
                        mode = ('zpy' if (zp and 'zpy' in OPCODES.get(mn, {}))
                                else 'absy')
                    emit(pc, need(mn, mode, lnum, raw)); pc += 1
                    emit(pc, v & 0xFF);                  pc += 1
                    if mode in ('absx', 'absy'):
                        emit(pc, (v >> 8) & 0xFF);       pc += 1

                elif hint == 'plain':
                    if mn in BRANCHES:
                        v   = _eval(et, syms, pc, lnum)
                        off = v - (pc + 2)
                        if not -128 <= off <= 127:
                            raise AsmError(
                                f"Line {lnum}: Branch out of range "
                                f"(offset={off}, target=${v:04X})")
                        emit(pc, need(mn, 'rel', lnum, raw)); pc += 1
                        emit(pc, off & 0xFF);                 pc += 1
                    else:
                        v    = _eval(et, syms, pc, lnum)
                        zp   = (0 <= v <= 0xFF)
                        mode = ('zp' if (zp and 'zp' in OPCODES.get(mn, {}))
                                else 'abso')
                        emit(pc, need(mn, mode, lnum, raw)); pc += 1
                        emit(pc, v & 0xFF);                  pc += 1
                        if mode == 'abso':
                            emit(pc, (v >> 8) & 0xFF);       pc += 1

            except AsmError as e:
                self._die(e, raw)

        if not memory:
            return b'', 0
        lo = min(memory); hi = max(memory)
        buf = bytearray(hi - lo + 1)
        for addr, byte in memory.items():
            buf[addr - lo] = byte
        org = origin[0] if origin[0] is not None else lo
        return bytes(buf), org

    def _size(self, mn, hint, et, syms, pc, lnum):
        """Estimate instruction byte length for pass 1."""
        if hint in ('imp', 'acc'):      return 1
        if hint in ('imm', 'indx', 'indy'): return 2
        if hint == 'ind':               return 3
        if mn in BRANCHES:              return 2
        # x / y / plain: try to resolve; must check mode exists for ZP
        val = _try_eval(et, syms, pc, lnum)
        zp  = (val is not None and 0 <= val <= 0xFF)
        if hint == 'x':
            if zp and 'zpx' in OPCODES.get(mn, {}): return 2
            return 3
        elif hint == 'y':
            if zp and 'zpy' in OPCODES.get(mn, {}): return 2
            return 3
        else:  # plain
            if zp and 'zp'  in OPCODES.get(mn, {}): return 2
            return 3

    def _die(self, exc, raw):
        print(f"\nAssembly error: {exc}", file=sys.stderr)
        if raw.strip():
            print(f"  Source: {raw.rstrip()}", file=sys.stderr)
        sys.exit(1)



# Public API

def assemble(source, verbose=False):
    """Assemble source string; return bytes starting at first .org."""
    data, _ = Assembler(verbose=verbose).assemble(source)
    return data



# CLI

if __name__ == '__main__':
    args    = sys.argv[1:]
    verbose = '-v' in args
    args    = [a for a in args if a != '-v']

    if not args:
        print("Usage: python3 asm.py <source.asm> [output.bin] [-v]")
        sys.exit(1)

    src_path = args[0]
    out_path = (args[1] if len(args) > 1
                else os.path.splitext(src_path)[0] + '.bin')

    try:
        source = open(src_path).read()
    except OSError as e:
        print(f"Error: {e}", file=sys.stderr); sys.exit(1)

    a = Assembler(verbose=verbose)
    data, org = a.assemble(source)

    with open(out_path, 'wb') as f:
        f.write(data)

    print(f"Assembled {len(data)} bytes  origin=${org:04X}  -> {out_path}")
