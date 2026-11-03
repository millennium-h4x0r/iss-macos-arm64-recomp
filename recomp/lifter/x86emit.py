"""x86-64 instruction -> C statement translation (non-control-flow part).

Registers are C locals named like the x86 64-bit registers (rax..r15); vector registers are
pairs of simde__m128i locals vlN (bits 0..127) and vhN (bits 128..255). Flags are locals
cf pf af zf sf of df. Each instruction becomes one C block; dead flag computations are removed
by the C compiler.
"""
import capstone as cs
from capstone import x86 as X

GPR64 = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
         'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15']
REGS = {}
for i, n in enumerate(GPR64):
    REGS[n] = (i, 8, False)
for i, n in enumerate(['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi'] + [f'r{k}d' for k in range(8, 16)]):
    REGS[n] = (i, 4, False)
for i, n in enumerate(['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di'] + [f'r{k}w' for k in range(8, 16)]):
    REGS[n] = (i, 2, False)
for i, n in enumerate(['al', 'cl', 'dl', 'bl', 'spl', 'bpl', 'sil', 'dil'] + [f'r{k}b' for k in range(8, 16)]):
    REGS[n] = (i, 1, False)
for i, n in enumerate(['ah', 'ch', 'dh', 'bh']):
    REGS[n] = (i, 1, True)

U = {1: 'uint8_t', 2: 'uint16_t', 4: 'uint32_t', 8: 'uint64_t', 16: '__uint128_t'}
S = {1: 'int8_t', 2: 'int16_t', 4: 'int32_t', 8: 'int64_t', 16: '__int128_t'}
MASK = {1: '0xffULL', 2: '0xffffULL', 4: '0xffffffffULL', 8: '0xffffffffffffffffULL'}
BITS = {1: 8, 2: 16, 4: 32, 8: 64}

CC = {
    'o': 'of', 'no': '!of', 'b': 'cf', 'ae': '!cf', 'e': 'zf', 'ne': '!zf',
    'be': '(cf|zf)', 'a': '(!cf&&!zf)', 's': 'sf', 'ns': '!sf', 'p': 'pf', 'np': '!pf',
    'l': '(sf!=of)', 'ge': '(sf==of)', 'le': '(zf||(sf!=of))', 'g': '(!zf&&(sf==of))',
}


class Unsupported(Exception):
    pass


class Emitter:
    runtime_imm = {}  # instruction address -> image offset of an imm32 read at run time

    """Per-function state: which registers are touched (for the spill/reload sets)."""

    def __init__(self, md, img_base_macro='IMG'):
        self.md = md
        self.gprs = set()
        self.vregs = set()
        self.uses_df = False
        self.tmp = 0

    # ---------------------------------------------------------------- operands
    def rname(self, reg):
        return self.md.reg_name(reg)

    def is_vreg(self, reg):
        n = self.rname(reg)
        return n.startswith('xmm') or n.startswith('ymm')

    def vidx(self, reg):
        n = self.rname(reg)
        return int(n[3:]), n.startswith('ymm')

    def gread(self, reg, width=None):
        n = self.rname(reg)
        if n not in REGS:
            raise Unsupported(f'register {n}')
        i, w, high = REGS[n]
        self.gprs.add(i)
        g = GPR64[i]
        if high:
            return f'((uint8_t)({g}>>8))'
        if w == 8:
            return g
        return f'(({U[w]}){g})'

    def gwrite(self, reg, val):
        n = self.rname(reg)
        if n not in REGS:
            raise Unsupported(f'register {n}')
        i, w, high = REGS[n]
        self.gprs.add(i)
        g = GPR64[i]
        if high:
            return f'{g} = ({g} & ~0xff00ULL) | ((uint64_t)(uint8_t)({val}) << 8);'
        if w == 8:
            return f'{g} = (uint64_t)({val});'
        if w == 4:
            return f'{g} = (uint32_t)({val});'
        return f'{g} = ({g} & ~{MASK[w]}) | ({U[w]})({val});'

    def gidx(self, reg):
        return REGS[self.rname(reg)][0]

    def addr(self, insn, op):
        m = op.mem
        parts = []
        if m.base == X.X86_REG_RIP:
            parts.append(f'(IMG+0x{(insn.address + insn.size + m.disp) & 0xffffffffffffffff:x}ULL)')
        else:
            if m.base:
                parts.append(self.gread(m.base) if REGS[self.rname(m.base)][1] == 8
                             else f'(uint64_t){self.gread(m.base)}')
            if m.index:
                ix = self.gread(m.index)
                if REGS[self.rname(m.index)][1] != 8:
                    ix = f'(uint64_t){ix}'
                parts.append(f'{ix}*{m.scale}' if m.scale != 1 else ix)
            if m.disp:
                parts.append(f'0x{m.disp & 0xffffffffffffffff:x}ULL')
        if m.segment in (X.X86_REG_FS, X.X86_REG_GS):
            parts.append('c->fs')
        elif m.segment not in (0, X.X86_REG_DS, X.X86_REG_SS, X.X86_REG_ES, X.X86_REG_CS):
            raise Unsupported('segment')
        e = '+'.join(parts) if parts else '0ULL'
        if insn.addr_size == 4:
            e = f'(uint64_t)(uint32_t)({e})'
        return f'({e})'

    @staticmethod
    def ordered(a):
        """Guest GPR accesses other than rsp-relative ones (thread-private stack) are ordered:
        acquire loads / release stores (x86.h lda*/stl*) for x86's TSO between threads."""
        return not (a == '(rsp)' or a.startswith('(rsp+'))

    def ld(self, a, size, ordered=None):
        o = self.ordered(a) if ordered is None else ordered
        return f'{"lda" if o else "ld"}{size * 8}({a})'

    def st(self, a, size, v, ordered=None):
        o = self.ordered(a) if ordered is None else ordered
        return f'{"stl" if o else "st"}{size * 8}({a}, {v});'

    def read(self, insn, op, size=None):
        size = size or op.size
        if op.type == X.X86_OP_REG:
            return self.gread(op.reg)
        if op.type == X.X86_OP_IMM:
            at = self.runtime_imm.get(insn.address)
            if at is not None and size == 4:
                # Patched at run time (lift.py apply_native_sites): the guest image holds it.
                return f'((uint32_t)ld32(IMG+0x{at:x}ULL))'
            return f'(({U[size]})0x{op.imm & int(MASK[size][:-3], 16):x}ULL)'
        if op.type == X.X86_OP_MEM:
            return self.ld(self.addr(insn, op), size)
        raise Unsupported('operand')

    # dst helpers: returns (prelude lines, read expr, writer(fn val -> line))
    def dst(self, insn, op):
        if op.type == X.X86_OP_REG:
            return [], self.gread(op.reg), (lambda v, r=op.reg: self.gwrite(r, v))
        if op.type == X.X86_OP_MEM:
            a = self.addr(insn, op)
            size = op.size
            o = self.ordered(a)
            return ([f'uint64_t ea = {a};'], self.ld('ea', size, o),
                    (lambda v, s=size: self.st('ea', s, f'({U[s]})({v})', o)))
        raise Unsupported('dst operand')

    # ---------------------------------------------------------------- flags
    @staticmethod
    def fl_logic(r, w):
        return [f'cf = 0; of = 0; zf = ({r}) == 0; sf = (({r}) >> {BITS[w] - 1}) & 1; pf = parity8({r}); af = 0;']

    @staticmethod
    def fl_szp(r, w):
        return [f'zf = ({r}) == 0; sf = (({r}) >> {BITS[w] - 1}) & 1; pf = parity8({r});']

    def fl_add(self, a, b, r, w, cin=None):
        hb = BITS[w] - 1
        cfe = f'({r}) < ({a})' if cin is None else f'(({r}) < ({a})) || ({cin} && ({r}) == ({a}))'
        return [f'cf = {cfe}; of = (((({a}) ^ ({r})) & (({b}) ^ ({r}))) >> {hb}) & 1; af = ((({a}) ^ ({b}) ^ ({r})) >> 4) & 1;'] + self.fl_szp(r, w)

    def fl_sub(self, a, b, r, w, cin=None):
        hb = BITS[w] - 1
        cfe = f'({a}) < ({b})' if cin is None else f'(({a}) < ({b})) || ({cin} && ({a}) == ({b}))'
        return [f'cf = {cfe}; of = (((({a}) ^ ({b})) & (({a}) ^ ({r}))) >> {hb}) & 1; af = ((({a}) ^ ({b}) ^ ({r})) >> 4) & 1;'] + self.fl_szp(r, w)

    # ---------------------------------------------------------------- vectors
    def vlo(self, i):
        self.vregs.add(i)
        return f'vl{i}'

    def vhi(self, i):
        self.vregs.add(i)
        return f'vh{i}'

    def vsrc(self, insn, op, wide, size=None):
        """(lo, hi) expressions of a vector source operand (register or memory)."""
        if op.type == X.X86_OP_REG:
            if self.is_vreg(op.reg):
                i, _ = self.vidx(op.reg)
                return self.vlo(i), (self.vhi(i) if wide else 'VZERO')
            return f'v_from64({self.gread(op.reg)})', 'VZERO'
        if op.type == X.X86_OP_MEM:
            a = self.addr(insn, op)
            size = size or op.size
            if size == 16:
                return f'ld128({a})', 'VZERO'
            if size == 32:
                return f'ld128({a})', f'ld128({a}+16)'
            if size == 8:
                return f'v_from64(ld64({a}))', 'VZERO'
            if size == 4:
                return f'v_from32(ld32({a}))', 'VZERO'
            if size == 2:
                return f'v_from32(ld16({a}))', 'VZERO'
            if size == 1:
                return f'v_from32(ld8({a}))', 'VZERO'
        raise Unsupported('vector operand')

    def vset(self, insn, op, lo, hi, vex, wide):
        """Writes a vector destination. VEX: upper half = hi (zero for 128-bit); legacy SSE keeps it."""
        if op.type == X.X86_OP_REG and self.is_vreg(op.reg):
            i, _ = self.vidx(op.reg)
            out = [f'{self.vlo(i)} = {lo};']
            if wide:
                out.append(f'{self.vhi(i)} = {hi};')
            elif vex:
                out.append(f'{self.vhi(i)} = VZERO;')
            return out
        if op.type == X.X86_OP_MEM:
            a = self.addr(insn, op)
            if op.size == 32:
                return [f'st128({a}, {lo});', f'st128({a}+16, {hi});']
            if op.size == 16:
                return [f'st128({a}, {lo});']
            if op.size == 8:
                return [f'st64({a}, v_lo64({lo}));']
            if op.size == 4:
                return [f'st32({a}, v_lo32({lo}));']
        raise Unsupported('vector dst')

    # ---------------------------------------------------------------- main
    def emit(self, insn):
        """Returns C lines for a non-control-flow instruction (raises Unsupported)."""
        m = insn.mnemonic
        ops = insn.operands
        if 0xd8 <= insn.opcode[0] <= 0xdf and not insn.opcode[1] and m.startswith('f'):
            from x87emit import emit_x87
            return emit_x87(self, insn)
        if m in ('wait', 'fwait'):
            return []
        if m.startswith('lock '):
            return self.emit_lock(insn, m[5:])
        if m.startswith('rep ') or m.startswith('repne ') or m.startswith('repe '):
            return self.emit_rep(insn, m)
        if m.startswith('v') and m not in ('verr', 'verw'):
            return self.emit_simd(insn, m[1:], vex=True)
        h = getattr(self, 'i_' + m, None)
        if h:
            return h(insn, ops)
        if m.startswith('cmov'):
            cc = CC[m[4:]]
            src = self.read(insn, ops[1])
            # 32-bit cmov zero-extends even when the condition is false
            return [f'if ({cc}) {{ {self.gwrite(ops[0].reg, src)} }}'
                    + ('' if ops[0].size != 4 else f' else {{ {self.gwrite(ops[0].reg, self.gread(ops[0].reg))} }}')]
        if m.startswith('set') and m[3:] in CC:
            pre, _, wr = self.dst(insn, ops[0])
            return pre + [wr(f'({CC[m[3:]]}) ? 1 : 0')]
        return self.emit_simd(insn, m, vex=False)

    # ---- data movement
    def i_mov(self, insn, ops):
        if ops[0].type == X.X86_OP_REG and self.is_vreg(ops[0].reg) or ops[1].type == X.X86_OP_REG and self.is_vreg(ops[1].reg):
            raise Unsupported('mov vreg')
        if ops[0].type == X.X86_OP_REG and self.rname(ops[0].reg) not in REGS:
            raise Unsupported('mov sreg')
        src = self.read(insn, ops[1], ops[0].size)
        pre, _, wr = self.dst(insn, ops[0])
        return pre + [wr(src)]
    i_movabs = i_mov

    def i_movzx(self, insn, ops):
        src = self.read(insn, ops[1])
        return [self.gwrite(ops[0].reg, f'(uint64_t){src}')]

    def i_movsx(self, insn, ops):
        src = self.read(insn, ops[1])
        return [self.gwrite(ops[0].reg, f'(int64_t)({S[ops[1].size]}){src}')]
    i_movsxd = i_movsx

    def i_movbe(self, insn, ops):
        w = ops[0].size
        src = self.read(insn, ops[1])
        pre, _, wr = self.dst(insn, ops[0])
        return pre + [wr(f'bswap{BITS[w]}({src})')]

    def i_bswap(self, insn, ops):
        w = ops[0].size
        return [self.gwrite(ops[0].reg, f'bswap{BITS[w]}({self.gread(ops[0].reg)})')]

    def i_lea(self, insn, ops):
        return [self.gwrite(ops[0].reg, self.addr(insn, ops[1]))]

    def i_xchg(self, insn, ops):
        if ops[0].type == X.X86_OP_MEM or ops[1].type == X.X86_OP_MEM:
            memop, regop = (ops[0], ops[1]) if ops[0].type == X.X86_OP_MEM else (ops[1], ops[0])
            w = memop.size
            a = self.addr(insn, memop)
            return [f'{U[w]} old = __atomic_exchange_n(({U[w]} *){a}, ({U[w]}){self.gread(regop.reg)}, __ATOMIC_SEQ_CST);',
                    self.gwrite(regop.reg, 'old')]
        a, b = self.gread(ops[0].reg), self.gread(ops[1].reg)
        if self.gidx(ops[0].reg) == self.gidx(ops[1].reg) and ops[0].size == 8:
            return []
        return [f'uint64_t t0 = {a}, t1 = {b};', self.gwrite(ops[0].reg, 't1'), self.gwrite(ops[1].reg, 't0')]

    def i_push(self, insn, ops):
        v = self.read(insn, ops[0], 8)
        if ops[0].type == X.X86_OP_IMM:
            v = f'(uint64_t)(int64_t)0x{ops[0].imm & 0xffffffffffffffff:x}ULL'
        if ops[0].size == 2:
            raise Unsupported('push16')
        self.gprs.add(4)
        return [f'uint64_t v = {v}; rsp -= 8; st64(rsp, v);']

    def i_pop(self, insn, ops):
        self.gprs.add(4)
        if ops[0].type == X.X86_OP_REG:
            if self.gidx(ops[0].reg) == 4:
                return ['rsp = ld64(rsp);']
            return [f'uint64_t v = ld64(rsp); rsp += 8;', self.gwrite(ops[0].reg, 'v')]
        a = self.addr(insn, ops[0])
        return [f'uint64_t v = ld64(rsp); rsp += 8; st64({a}, v);']

    def flags_pack(self):
        return '((uint64_t)cf | 2 | ((uint64_t)pf << 2) | ((uint64_t)af << 4) | ((uint64_t)zf << 6) | ((uint64_t)sf << 7) | 0x200 | ((uint64_t)df << 10) | ((uint64_t)of << 11))'

    def flags_unpack(self, v):
        self.uses_df = True
        return (f'cf = ({v}) & 1; pf = (({v}) >> 2) & 1; af = (({v}) >> 4) & 1; zf = (({v}) >> 6) & 1; '
                f'sf = (({v}) >> 7) & 1; df = (({v}) >> 10) & 1; of = (({v}) >> 11) & 1;')

    def i_pushfq(self, insn, ops):
        self.gprs.add(4); self.uses_df = True
        return [f'rsp -= 8; st64(rsp, {self.flags_pack()});']

    def i_popfq(self, insn, ops):
        self.gprs.add(4)
        return ['uint64_t v = ld64(rsp); rsp += 8;', self.flags_unpack('v')]

    def i_lahf(self, insn, ops):
        self.gprs.add(0)
        return [f'rax = (rax & ~0xff00ULL) | (((uint64_t)({self.flags_pack()}) & 0xff) << 8);']

    def i_sahf(self, insn, ops):
        self.gprs.add(0)
        return ['{ uint64_t v = (rax >> 8) & 0xff; cf = v & 1; pf = (v >> 2) & 1; af = (v >> 4) & 1; zf = (v >> 6) & 1; sf = (v >> 7) & 1; }']

    def i_leave(self, insn, ops):
        self.gprs.update({4, 5})
        return ['rsp = rbp; rbp = ld64(rsp); rsp += 8;']

    def i_cdqe(self, insn, ops): self.gprs.add(0); return ['rax = (uint64_t)(int64_t)(int32_t)rax;']
    def i_cwde(self, insn, ops): self.gprs.add(0); return ['rax = (uint32_t)(int32_t)(int16_t)rax;']
    def i_cbw(self, insn, ops): self.gprs.add(0); return ['rax = (rax & ~0xffffULL) | (uint16_t)(int16_t)(int8_t)rax;']
    def i_cdq(self, insn, ops): self.gprs.update({0, 2}); return ['rdx = (uint32_t)(((int32_t)rax) >> 31);']
    def i_cqo(self, insn, ops): self.gprs.update({0, 2}); return ['rdx = (uint64_t)(((int64_t)rax) >> 63);']
    def i_cwd(self, insn, ops): self.gprs.update({0, 2}); return ['rdx = (rdx & ~0xffffULL) | (uint16_t)(((int16_t)rax) >> 15);']

    def i_nop(self, insn, ops): return []
    i_pause = i_nop
    i_prefetcht0 = i_prefetcht1 = i_prefetcht2 = i_prefetchnta = i_prefetchw = i_nop
    i_lfence = i_sfence = i_nop
    i_endbr64 = i_nop

    def i_mfence(self, insn, ops): return ['__atomic_thread_fence(__ATOMIC_SEQ_CST);']
    def i_cld(self, insn, ops): self.uses_df = True; return ['df = 0;']
    def i_std(self, insn, ops): self.uses_df = True; return ['df = 1;']
    def i_clc(self, insn, ops): return ['cf = 0;']
    def i_stc(self, insn, ops): return ['cf = 1;']
    def i_cmc(self, insn, ops): return ['cf = !cf;']

    def i_rdtsc(self, insn, ops):
        self.gprs.update({0, 2})
        return ['uint64_t t = recomp_rdtsc(); rax = (uint32_t)t; rdx = t >> 32;']

    def i_cpuid(self, insn, ops):
        self.gprs.update({0, 1, 2, 3})
        return ['recomp_cpuid(&rax, &rbx, &rcx, &rdx);']

    # ---- ALU
    def alu(self, insn, ops, op, kind, cin=None):
        w = ops[0].size
        pre, a, wr = self.dst(insn, ops[0])
        b = self.read(insn, ops[1], w)
        t = U[w]
        lines = pre + (['uint8_t cin = cf;'] if cin else []) + [f'{t} a = {a}, b = {b};']
        if kind == 'add':
            lines.append(f'{t} r = ({t})(a + b{" + cin" if cin else ""});')
            lines += self.fl_add('a', 'b', 'r', w, 'cin' if cin else None)
        elif kind == 'sub':
            lines.append(f'{t} r = ({t})(a - b{" - cin" if cin else ""});')
            lines += self.fl_sub('a', 'b', 'r', w, 'cin' if cin else None)
        else:
            lines.append(f'{t} r = ({t})(a {op} b);')
            lines += self.fl_logic('r', w)
        if op is not None:
            lines.append(wr('r'))
        return lines

    def i_add(self, insn, ops): return self.alu(insn, ops, '+', 'add')
    def i_adc(self, insn, ops): return self.alu(insn, ops, '+', 'add', cin=True)
    def i_sub(self, insn, ops):
        if ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            w = ops[0].size
            return [self.gwrite(ops[0].reg, '0'), 'cf = 0; of = 0; zf = 1; sf = 0; pf = 1; af = 0;']
        return self.alu(insn, ops, '-', 'sub')
    def i_sbb(self, insn, ops): return self.alu(insn, ops, '-', 'sub', cin=True)
    def i_cmp(self, insn, ops): return self.alu(insn, ops, None, 'sub')
    def i_and(self, insn, ops): return self.alu(insn, ops, '&', 'logic')
    def i_or(self, insn, ops): return self.alu(insn, ops, '|', 'logic')
    def i_xor(self, insn, ops):
        if ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            return [self.gwrite(ops[0].reg, '0'), 'cf = 0; of = 0; zf = 1; sf = 0; pf = 1; af = 0;']
        return self.alu(insn, ops, '^', 'logic')

    def i_test(self, insn, ops):
        w = ops[0].size
        a = self.read(insn, ops[0]); b = self.read(insn, ops[1], w)
        return [f'{U[w]} r = ({U[w]})({a} & {b});'] + self.fl_logic('r', w)

    def i_inc(self, insn, ops):
        w = ops[0].size; t = U[w]
        pre, a, wr = self.dst(insn, ops[0])
        return pre + [f'{t} a = {a}; {t} r = ({t})(a + 1);',
                      f'of = r == ({t})(({t})1 << {BITS[w] - 1}); af = (r & 0xf) == 0;'] + self.fl_szp('r', w) + [wr('r')]

    def i_dec(self, insn, ops):
        w = ops[0].size; t = U[w]
        pre, a, wr = self.dst(insn, ops[0])
        return pre + [f'{t} a = {a}; {t} r = ({t})(a - 1);',
                      f'of = a == ({t})(({t})1 << {BITS[w] - 1}); af = (a & 0xf) == 0;'] + self.fl_szp('r', w) + [wr('r')]

    def i_neg(self, insn, ops):
        w = ops[0].size; t = U[w]
        pre, a, wr = self.dst(insn, ops[0])
        return pre + [f'{t} a = {a}; {t} r = ({t})(0 - a);',
                      f'cf = a != 0; of = a == ({t})(({t})1 << {BITS[w] - 1}); af = (a & 0xf) != 0;'] + self.fl_szp('r', w) + [wr('r')]

    def i_not(self, insn, ops):
        w = ops[0].size
        pre, a, wr = self.dst(insn, ops[0])
        return pre + [wr(f'~{a}')]

    def shift(self, insn, ops, kind):
        w = ops[0].size; t = U[w]; bits = BITS[w]
        pre, a, wr = self.dst(insn, ops[0])
        cnt = '1' if len(ops) == 1 else self.read(insn, ops[1], 1)
        mask = 63 if w == 8 else 31
        lines = pre + [f'{t} a = {a}; unsigned n = ({cnt}) & {mask};', 'if (n) {']
        if kind == 'shl':
            lines += [f'{t} r = ({t})((uint64_t)a << n);',
                      f'cf = n <= {bits} ? ((uint64_t)a >> ({bits} - n)) & 1 : 0;',
                      f'of = ((r >> {bits - 1}) & 1) ^ cf; af = 0;']
        elif kind == 'shr':
            lines += [f'{t} r = n < {bits} ? ({t})(a >> n) : 0;',
                      f'cf = ((uint64_t)a >> (n - 1)) & 1;',
                      f'of = (a >> {bits - 1}) & 1; af = 0;']
        elif kind == 'sar':
            lines += [f'{t} r = ({t})(({S[w]})a >> (n < {bits} ? n : {bits - 1}));',
                      f'cf = (({S[w]})a >> (n - 1 < {bits} ? n - 1 : {bits - 1})) & 1;',
                      'of = 0; af = 0;']
        elif kind in ('rol', 'ror'):
            lines[-1] = 'if (n) {'
            if kind == 'rol':
                lines += [f'unsigned k = n % {bits}; {t} r = k ? ({t})((a << k) | (a >> ({bits} - k))) : a;',
                          'cf = r & 1;', f'of = ((r >> {bits - 1}) & 1) ^ cf;']
            else:
                lines += [f'unsigned k = n % {bits}; {t} r = k ? ({t})((a >> k) | (a << ({bits} - k))) : a;',
                          f'cf = (r >> {bits - 1}) & 1;', f'of = cf ^ ((r >> {bits - 2}) & 1);']
            lines += [wr('r'), '}']
            return lines
        lines += self.fl_szp('r', w) + [wr('r'), '}']
        return lines

    def i_shl(self, insn, ops): return self.shift(insn, ops, 'shl')
    i_sal = i_shl
    def i_shr(self, insn, ops): return self.shift(insn, ops, 'shr')
    def i_sar(self, insn, ops): return self.shift(insn, ops, 'sar')
    def i_rol(self, insn, ops): return self.shift(insn, ops, 'rol')
    def i_ror(self, insn, ops): return self.shift(insn, ops, 'ror')

    def i_rcl(self, insn, ops):
        w = ops[0].size; t = U[w]; bits = BITS[w]
        pre, a, wr = self.dst(insn, ops[0])
        cnt = '1' if len(ops) == 1 else self.read(insn, ops[1], 1)
        mask = 63 if w == 8 else 31
        mod = bits + 1
        return pre + [f'{t} r = {a}; unsigned n = (({cnt}) & {mask}) % {mod};',
                      f'for (unsigned i = 0; i < n; ++i) {{ uint8_t top = (r >> {bits - 1}) & 1; r = ({t})((r << 1) | cf); cf = top; }}',
                      f'if (n == 1) of = ((r >> {bits - 1}) & 1) ^ cf;', wr('r')]

    def i_rcr(self, insn, ops):
        w = ops[0].size; t = U[w]; bits = BITS[w]
        pre, a, wr = self.dst(insn, ops[0])
        cnt = '1' if len(ops) == 1 else self.read(insn, ops[1], 1)
        mask = 63 if w == 8 else 31
        return pre + [f'{t} r = {a}; unsigned n = (({cnt}) & {mask}) % {bits + 1};',
                      f'if (n == 1) of = ((r >> {bits - 1}) & 1) ^ cf;',
                      f'for (unsigned i = 0; i < n; ++i) {{ uint8_t low = r & 1; r = ({t})((r >> 1) | (({t})cf << {bits - 1})); cf = low; }}',
                      wr('r')]

    def shd(self, insn, ops, left):
        w = ops[0].size; t = U[w]; bits = BITS[w]
        pre, a, wr = self.dst(insn, ops[0])
        b = self.read(insn, ops[1])
        cnt = self.read(insn, ops[2], 1)
        mask = 63 if w == 8 else 31
        if left:
            body = [f'{t} r = ({t})((a << n) | ((uint64_t)b >> ({bits} - n)));',
                    f'cf = ((uint64_t)a >> ({bits} - n)) & 1; of = ((r ^ a) >> {bits - 1}) & 1;']
        else:
            body = [f'{t} r = ({t})((a >> n) | ((uint64_t)b << ({bits} - n)));',
                    f'cf = ((uint64_t)a >> (n - 1)) & 1; of = ((r ^ a) >> {bits - 1}) & 1;']
        if w != 8:
            # 16/32-bit: compute in 64 bits to avoid UB on shift by width
            body[0] = body[0].replace('(uint64_t)b', '(uint64_t)(' + U[w] + ')b')
        return pre + [f'{t} a = {a}, b = {b}; unsigned n = ({cnt}) & {mask};', 'if (n) {'] + body + self.fl_szp('r', w) + [wr('r'), '}']

    def i_shld(self, insn, ops): return self.shd(insn, ops, True)
    def i_shrd(self, insn, ops): return self.shd(insn, ops, False)

    def i_bt(self, insn, ops):
        w = ops[0].size
        if ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_REG:
            a = self.addr(insn, ops[0])
            b = self.gread(ops[1].reg)
            return [f'int64_t off = ({S[ops[1].size]}){b}; cf = (ld8({a} + (off >> 3)) >> (off & 7)) & 1;']
        a = self.read(insn, ops[0]); b = self.read(insn, ops[1], w)
        return [f'cf = ((uint64_t){a} >> ((uint64_t){b} & {BITS[w] - 1})) & 1;']

    def btx(self, insn, ops, op):
        w = ops[0].size; t = U[w]
        if ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_REG:
            raise Unsupported('bt* mem,reg')
        pre, a, wr = self.dst(insn, ops[0])
        b = self.read(insn, ops[1], w)
        newv = {'s': 'a | m', 'r': 'a & ~m', 'c': 'a ^ m'}[op]
        return pre + [f'{t} a = {a}; unsigned k = (unsigned)({b}) & {BITS[w] - 1}; {t} m = ({t})(({t})1 << k);',
                      'cf = (a & m) != 0;', wr(newv)]

    def i_bts(self, insn, ops): return self.btx(insn, ops, 's')
    def i_btr(self, insn, ops): return self.btx(insn, ops, 'r')
    def i_btc(self, insn, ops): return self.btx(insn, ops, 'c')

    def i_bsf(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[1])
        return [f'{U[w]} s = {s}; zf = s == 0; if (s) {{ {self.gwrite(ops[0].reg, "__builtin_ctzll(s)")} }}']

    def i_bsr(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[1])
        return [f'{U[w]} s = {s}; zf = s == 0; if (s) {{ {self.gwrite(ops[0].reg, "63 - __builtin_clzll((uint64_t)s)")} }}']

    def i_tzcnt(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[1])
        return [f'{U[w]} s = {s}; uint64_t r = s ? (uint64_t)__builtin_ctzll(s) : {BITS[w]}; cf = s == 0; zf = r == 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_lzcnt(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[1])
        return [f'{U[w]} s = {s}; uint64_t r = s ? (uint64_t)(__builtin_clzll((uint64_t)s) - {64 - BITS[w]}) : {BITS[w]}; cf = s == 0; zf = r == 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_popcnt(self, insn, ops):
        s = self.read(insn, ops[1])
        return [f'uint64_t r = __builtin_popcountll({s}); cf = 0; of = 0; sf = 0; af = 0; pf = 0; zf = r == 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_andn(self, insn, ops):
        w = ops[0].size; t = U[w]
        a = self.read(insn, ops[1]); b = self.read(insn, ops[2])
        return [f'{t} r = ({t})(~{a} & {b}); cf = 0; of = 0; zf = r == 0; sf = (r >> {BITS[w] - 1}) & 1;',
                self.gwrite(ops[0].reg, 'r')]

    def i_bextr(self, insn, ops):
        w = ops[0].size; t = U[w]
        s = self.read(insn, ops[1]); ctl = self.read(insn, ops[2])
        return [f'{t} s = {s}; unsigned st = ({ctl}) & 0xff, ln = (({ctl}) >> 8) & 0xff;',
                f'uint64_t r = st >= {BITS[w]} ? 0 : ((uint64_t)s >> st); if (ln < 64) r &= (1ULL << ln) - 1;',
                f'r = ({t})r; zf = r == 0; cf = 0; of = 0;', self.gwrite(ops[0].reg, 'r')]

    def i_blsi(self, insn, ops):
        w = ops[0].size; t = U[w]
        s = self.read(insn, ops[1])
        return [f'{t} s = {s}; {t} r = ({t})(s & (0 - s)); zf = r == 0; sf = (r >> {BITS[w] - 1}) & 1; cf = s != 0; of = 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_blsr(self, insn, ops):
        w = ops[0].size; t = U[w]
        s = self.read(insn, ops[1])
        return [f'{t} s = {s}; {t} r = ({t})(s & (s - 1)); zf = r == 0; sf = (r >> {BITS[w] - 1}) & 1; cf = s == 0; of = 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_blsmsk(self, insn, ops):
        w = ops[0].size; t = U[w]
        s = self.read(insn, ops[1])
        return [f'{t} s = {s}; {t} r = ({t})(s ^ (s - 1)); zf = 0; sf = (r >> {BITS[w] - 1}) & 1; cf = s == 0; of = 0;',
                self.gwrite(ops[0].reg, 'r')]

    def i_imul(self, insn, ops):
        if len(ops) == 1:
            w = ops[0].size
            s = self.read(insn, ops[0])
            self.gprs.update({0, 2})
            if w == 1:
                return [f'int16_t r = (int16_t)(int8_t)rax * (int16_t)(int8_t){s};',
                        'rax = (rax & ~0xffffULL) | (uint16_t)r; cf = of = r != (int8_t)r;']
            if w == 2:
                return [f'int32_t r = (int32_t)(int16_t)rax * (int16_t){s};',
                        'rax = (rax & ~0xffffULL) | (uint16_t)r; rdx = (rdx & ~0xffffULL) | (uint16_t)(r >> 16); cf = of = r != (int16_t)r;']
            if w == 4:
                return [f'int64_t r = (int64_t)(int32_t)rax * (int32_t){s};',
                        'rax = (uint32_t)r; rdx = (uint32_t)(r >> 32); cf = of = r != (int32_t)r;']
            return [f'__int128_t r = (__int128_t)(int64_t)rax * (int64_t){s};',
                    'rax = (uint64_t)r; rdx = (uint64_t)(r >> 64); cf = of = r != (int64_t)r;']
        w = ops[0].size
        if len(ops) == 2:
            a, b = self.gread(ops[0].reg), self.read(insn, ops[1], w)
        else:
            a, b = self.read(insn, ops[1], w), self.read(insn, ops[2], w)
        big = S[w * 2] if w < 8 else '__int128_t'
        return [f'{big} r = ({big})({S[w]}){a} * ({big})({S[w]}){b};',
                f'cf = of = r != ({S[w]})r; zf = ({U[w]})r == 0; sf = (({U[w]})r >> {BITS[w] - 1}) & 1; pf = parity8(r);',
                self.gwrite(ops[0].reg, f'({U[w]})r')]

    def i_mul(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[0])
        self.gprs.update({0, 2})
        if w == 1:
            return [f'uint16_t r = (uint16_t)(uint8_t)rax * (uint8_t){s};', 'rax = (rax & ~0xffffULL) | r; cf = of = (r >> 8) != 0;']
        if w == 2:
            return [f'uint32_t r = (uint32_t)(uint16_t)rax * (uint16_t){s};',
                    'rax = (rax & ~0xffffULL) | (uint16_t)r; rdx = (rdx & ~0xffffULL) | (uint16_t)(r >> 16); cf = of = (r >> 16) != 0;']
        if w == 4:
            return [f'uint64_t r = (uint64_t)(uint32_t)rax * (uint32_t){s};', 'rax = (uint32_t)r; rdx = r >> 32; cf = of = rdx != 0;']
        return [f'__uint128_t r = (__uint128_t)rax * (uint64_t){s};', 'rax = (uint64_t)r; rdx = (uint64_t)(r >> 64); cf = of = rdx != 0;']

    def i_div(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[0])
        self.gprs.update({0, 2})
        at = f'0x{insn.address:x}ULL'
        if w == 1:
            return [f'uint8_t d = {s}; if (!d) recomp_trap({at}, "#DE"); uint16_t n = (uint16_t)rax;',
                    'uint16_t q = n / d; if (q > 0xff) recomp_trap(' + at + ', "#DE");',
                    'rax = (rax & ~0xffffULL) | (uint16_t)((uint16_t)(n % d) << 8 | (uint8_t)q);']
        if w == 2:
            return [f'uint16_t d = {s}; if (!d) recomp_trap({at}, "#DE"); uint32_t n = ((uint32_t)(uint16_t)rdx << 16) | (uint16_t)rax;',
                    'uint32_t q = n / d; if (q > 0xffff) recomp_trap(' + at + ', "#DE");',
                    'rax = (rax & ~0xffffULL) | (uint16_t)q; rdx = (rdx & ~0xffffULL) | (uint16_t)(n % d);']
        if w == 4:
            return [f'uint32_t d = {s}; if (!d) recomp_trap({at}, "#DE"); uint64_t n = ((uint64_t)(uint32_t)rdx << 32) | (uint32_t)rax;',
                    'uint64_t q = n / d; if (q > 0xffffffffULL) recomp_trap(' + at + ', "#DE");',
                    'rax = (uint32_t)q; rdx = (uint32_t)(n % d);']
        return [f'uint64_t d = {s}; if (!d) recomp_trap({at}, "#DE");',
                'if (rdx == 0) { uint64_t n = rax; rax = n / d; rdx = n % d; } else {',
                '__uint128_t n = ((__uint128_t)rdx << 64) | rax; __uint128_t q = n / d; if (q >> 64) recomp_trap(' + at + ', "#DE");',
                'rax = (uint64_t)q; rdx = (uint64_t)(n % d); }']

    def i_idiv(self, insn, ops):
        w = ops[0].size
        s = self.read(insn, ops[0])
        self.gprs.update({0, 2})
        at = f'0x{insn.address:x}ULL'
        if w == 4:
            return [f'int32_t d = (int32_t){s}; if (!d) recomp_trap({at}, "#DE"); int64_t n = (int64_t)(((uint64_t)(uint32_t)rdx << 32) | (uint32_t)rax);',
                    'if (n == INT64_MIN && d == -1) recomp_trap(' + at + ', "#DE"); int64_t q = n / d; if (q != (int32_t)q) recomp_trap(' + at + ', "#DE");',
                    'rax = (uint32_t)q; rdx = (uint32_t)(n % d);']
        if w == 8:
            return [f'int64_t d = (int64_t){s}; if (!d) recomp_trap({at}, "#DE");',
                    'if ((int64_t)rdx == ((int64_t)rax >> 63)) { int64_t n = (int64_t)rax; if (n == INT64_MIN && d == -1) recomp_trap(' + at + ', "#DE"); rax = (uint64_t)(n / d); rdx = (uint64_t)(n % d); } else {',
                    '__int128_t n = (__int128_t)(((__uint128_t)rdx << 64) | rax); __int128_t q = n / d; if (q != (int64_t)q) recomp_trap(' + at + ', "#DE");',
                    'rax = (uint64_t)q; rdx = (uint64_t)(n % d); }']
        if w == 2:
            return [f'int16_t d = (int16_t){s}; if (!d) recomp_trap({at}, "#DE"); int32_t n = (int32_t)(((uint32_t)(uint16_t)rdx << 16) | (uint16_t)rax);',
                    'int32_t q = n / d; if (q != (int16_t)q) recomp_trap(' + at + ', "#DE");',
                    'rax = (rax & ~0xffffULL) | (uint16_t)q; rdx = (rdx & ~0xffffULL) | (uint16_t)(n % d);']
        return [f'int8_t d = (int8_t){s}; if (!d) recomp_trap({at}, "#DE"); int16_t n = (int16_t)rax;',
                'int16_t q = n / d; if (q != (int8_t)q) recomp_trap(' + at + ', "#DE");',
                'rax = (rax & ~0xffffULL) | (uint16_t)((uint16_t)(uint8_t)(n % d) << 8 | (uint8_t)q);']

    def i_xadd(self, insn, ops, atomic=False):
        w = ops[0].size; t = U[w]
        if ops[0].type == X.X86_OP_MEM:
            a = self.addr(insn, ops[0])
            b = self.gread(ops[1].reg)
            if atomic:
                lines = [f'{t} b = {b}; {t} a = __atomic_fetch_add(({t} *){a}, b, __ATOMIC_SEQ_CST); {t} r = ({t})(a + b);']
            else:
                lines = [f'uint64_t ea = {a}; {t} b = {b}; {t} a = ld{BITS[w]}(ea); {t} r = ({t})(a + b); st{BITS[w]}(ea, r);']
            return lines + self.fl_add('a', 'b', 'r', w) + [self.gwrite(ops[1].reg, 'a')]
        a, b = self.gread(ops[0].reg), self.gread(ops[1].reg)
        return [f'{t} a = {a}, b = {b}; {t} r = ({t})(a + b);'] + self.fl_add('a', 'b', 'r', w) + \
            [self.gwrite(ops[1].reg, 'a'), self.gwrite(ops[0].reg, 'r')]

    def i_cmpxchg(self, insn, ops, atomic=False):
        w = ops[0].size; t = U[w]
        self.gprs.add(0)
        acc = f'(({t})rax)'
        src = self.gread(ops[1].reg)
        if ops[0].type == X.X86_OP_MEM:
            a = self.addr(insn, ops[0])
            if atomic:
                lines = [f'{t} expected = {acc}, src = {src};',
                         f'int ok = __atomic_compare_exchange_n(({t} *){a}, &expected, src, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);',
                         f'{t} old = expected;']
            else:
                lines = [f'uint64_t ea = {a}; {t} expected = {acc}, src = {src}; {t} old = ld{BITS[w]}(ea); int ok = old == expected;',
                         f'if (ok) st{BITS[w]}(ea, src); else st{BITS[w]}(ea, old);']
        else:
            d = self.gread(ops[0].reg)
            lines = [f'{t} expected = {acc}, src = {src}; {t} old = {d}; int ok = old == expected;',
                     f'if (ok) {{ {self.gwrite(ops[0].reg, "src")} }}']
        r = f'({t})(expected_orig - old)'
        lines.insert(0, f'{t} expected_orig = {acc};')
        lines += [f'{t} r = {r};'] + self.fl_sub('expected_orig', 'old', 'r', w)
        lines.append(f'if (!ok) {{ {self.gwrite(self._acc_reg(w), "old")} }}')
        return lines

    def _acc_reg(self, w):
        return {1: X.X86_REG_AL, 2: X.X86_REG_AX, 4: X.X86_REG_EAX, 8: X.X86_REG_RAX}[w]

    def i_cmpxchg16b(self, insn, ops, atomic=False):
        a = self.addr(insn, ops[0])
        self.gprs.update({0, 1, 2, 3})
        return [f'__uint128_t expected = ((__uint128_t)rdx << 64) | rax, src = ((__uint128_t)rcx << 64) | rbx;',
                f'zf = __atomic_compare_exchange_n((__uint128_t *){a}, &expected, src, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);',
                'if (!zf) { rax = (uint64_t)expected; rdx = (uint64_t)(expected >> 64); }']

    def emit_lock(self, insn, m):
        ops = insn.operands
        if m == 'cmpxchg':
            return self.i_cmpxchg(insn, ops, atomic=True)
        if m == 'cmpxchg16b':
            return self.i_cmpxchg16b(insn, ops, atomic=True)
        if m == 'xadd':
            return self.i_xadd(insn, ops, atomic=True)
        if m == 'xchg':
            return self.i_xchg(insn, ops)
        if ops[0].type != X.X86_OP_MEM:
            raise Unsupported('lock non-mem')
        w = ops[0].size; t = U[w]
        a = self.addr(insn, ops[0])
        if m in ('inc', 'dec'):
            fn = '__atomic_fetch_add' if m == 'inc' else '__atomic_fetch_sub'
            lines = [f'{t} a = {fn}(({t} *){a}, 1, __ATOMIC_SEQ_CST); {t} r = ({t})(a {"+" if m == "inc" else "-"} 1);']
            if m == 'inc':
                lines.append(f'of = r == ({t})(({t})1 << {BITS[w] - 1}); af = (r & 0xf) == 0;')
            else:
                lines.append(f'of = a == ({t})(({t})1 << {BITS[w] - 1}); af = (a & 0xf) == 0;')
            return lines + self.fl_szp('r', w)
        b = self.read(insn, ops[1], w)
        if m in ('add', 'sub'):
            fn = '__atomic_fetch_add' if m == 'add' else '__atomic_fetch_sub'
            lines = [f'{t} b = {b}; {t} a = {fn}(({t} *){a}, b, __ATOMIC_SEQ_CST); {t} r = ({t})(a {"+" if m == "add" else "-"} b);']
            return lines + (self.fl_add('a', 'b', 'r', w) if m == 'add' else self.fl_sub('a', 'b', 'r', w))
        if m in ('and', 'or', 'xor'):
            fn = {'and': '__atomic_fetch_and', 'or': '__atomic_fetch_or', 'xor': '__atomic_fetch_xor'}[m]
            op = {'and': '&', 'or': '|', 'xor': '^'}[m]
            return [f'{t} b = {b}; {t} a = {fn}(({t} *){a}, b, __ATOMIC_SEQ_CST); {t} r = ({t})(a {op} b);'] + self.fl_logic('r', w)
        if m in ('bts', 'btr', 'btc'):
            fn = {'bts': '__atomic_fetch_or', 'btr': '__atomic_fetch_and', 'btc': '__atomic_fetch_xor'}[m]
            mexpr = '~msk' if m == 'btr' else 'msk'
            return [f'{t} msk = ({t})(({t})1 << (({b}) & {BITS[w] - 1})); {t} a = {fn}(({t} *){a}, {mexpr}, __ATOMIC_SEQ_CST); cf = (a & msk) != 0;']
        if m in ('adc', 'sbb', 'neg', 'not'):
            raise Unsupported('lock ' + m)
        raise Unsupported('lock ' + m)

    def emit_rep(self, insn, m):
        parts = m.split()
        prefix, op = parts[0], parts[1]
        self.gprs.update({1, 6, 7})
        self.uses_df = True
        sizes = {'movsb': 1, 'movsw': 2, 'movsd': 4, 'movsq': 8, 'stosb': 1, 'stosw': 2, 'stosd': 4, 'stosq': 8}
        str_sizes = {'b': 1, 'w': 2, 'd': 4, 'q': 8}
        if op[:4] in ('cmps', 'scas') and prefix in ('repe', 'repne', 'rep'):
            n = str_sizes[op[4]]
            t = U[n]
            self.gprs.add(0)
            cmp = (f'{t} a = ld{n * 8}(rsi), b = ld{n * 8}(rdi);' if op.startswith('cmps')
                   else f'{t} a = ({t})rax, b = ld{n * 8}(rdi);')
            step = (f'if (df) {{ rsi -= {n}; rdi -= {n}; }} else {{ rsi += {n}; rdi += {n}; }}' if op.startswith('cmps')
                    else f'if (df) rdi -= {n}; else rdi += {n};')
            stop = 'if (!zf) break;' if prefix in ('repe', 'rep') else 'if (zf) break;'
            return ['while (rcx) {', cmp, f'{t} r = ({t})(a - b);'] + self.fl_sub('a', 'b', 'r', n) + [step, 'rcx--;', stop, '}']
        if prefix == 'rep' and op in sizes:
            n = sizes[op]
            if op.startswith('movs'):
                return [f'rep_movs(&rdi, &rsi, &rcx, {n}, df);']
            self.gprs.add(0)
            return [f'rep_stos(&rdi, &rcx, rax, {n}, df);']
        raise Unsupported(m)

    def i_movsb(self, insn, ops): return self._movs(1)
    def i_movsw(self, insn, ops): return self._movs(2)
    def i_movsq(self, insn, ops): return self._movs(8)
    def _movs(self, n):
        self.gprs.update({6, 7}); self.uses_df = True
        return [f'__builtin_memmove((void *)rdi, (const void *)rsi, {n}); if (df) {{ rdi -= {n}; rsi -= {n}; }} else {{ rdi += {n}; rsi += {n}; }}']

    def _lods(self, n):
        self.gprs.update({0, 6}); self.uses_df = True
        w = {1: X.X86_REG_AL, 2: X.X86_REG_AX, 4: X.X86_REG_EAX, 8: X.X86_REG_RAX}[n]
        return [self.gwrite(w, f'ld{n * 8}(rsi)'), f'if (df) rsi -= {n}; else rsi += {n};']
    def i_lodsb(self, insn, ops): return self._lods(1)
    def i_lodsw(self, insn, ops): return self._lods(2)
    def i_lodsd(self, insn, ops): return self._lods(4)
    def i_lodsq(self, insn, ops): return self._lods(8)
    def _scas(self, n, cmps):
        self.gprs.update({0, 6, 7}); self.uses_df = True
        t = U[n]
        cmp = f'{t} a = ld{n * 8}(rsi), b = ld{n * 8}(rdi);' if cmps else f'{t} a = ({t})rax, b = ld{n * 8}(rdi);'
        step = (f'if (df) {{ rsi -= {n}; rdi -= {n}; }} else {{ rsi += {n}; rdi += {n}; }}' if cmps
                else f'if (df) rdi -= {n}; else rdi += {n};')
        return [cmp, f'{t} r = ({t})(a - b);'] + self.fl_sub('a', 'b', 'r', n) + [step]
    def i_scasb(self, insn, ops): return self._scas(1, False)
    def i_scasd(self, insn, ops): return self._scas(4, False)
    def i_scasq(self, insn, ops): return self._scas(8, False)
    def i_cmpsb(self, insn, ops): return self._scas(1, True)
    def i_cmpsq(self, insn, ops): return self._scas(8, True)
    def i_movsd(self, insn, ops):
        if len(ops) == 2 and ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_MEM:
            return self._movs(4)
        return self.emit_simd(insn, 'movsd', vex=False)
    def i_cmpsd(self, insn, ops):
        if len(ops) == 2 and ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_MEM:
            return self._scas(4, True)
        return self.emit_simd(insn, 'cmpsd', vex=False)
    def i_stosw(self, insn, ops): return self._stos(2)

    def i_stosb(self, insn, ops): return self._stos(1)
    def i_stosd(self, insn, ops): return self._stos(4)
    def i_stosq(self, insn, ops): return self._stos(8)
    def _stos(self, n):
        self.gprs.update({0, 7}); self.uses_df = True
        return [f'{{ uint64_t v = rax; __builtin_memcpy((void *)rdi, &v, {n}); }} if (df) rdi -= {n}; else rdi += {n};']

    # ---------------------------------------------------------------- SIMD
    def emit_simd(self, insn, m, vex):
        from simd import emit_simd
        return emit_simd(self, insn, m, vex)
