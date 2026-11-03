"""x87 translation by opcode/ModRM (independent of the disassembler's mnemonic spelling)."""
from capstone import x86 as X
from x86emit import Unsupported

ARITH = {0: '+', 1: '*', 4: '-', 5: '-r', 6: '/', 7: '/r'}


def _op(op, a, b):
    """a op b for the st0-destination forms (op from D8 /r)."""
    if op == '+': return f'({a}) + ({b})'
    if op == '*': return f'({a}) * ({b})'
    if op == '-': return f'({a}) - ({b})'
    if op == '-r': return f'({b}) - ({a})'
    if op == '/': return f'({a}) / ({b})'
    if op == '/r': return f'({b}) / ({a})'
    raise Unsupported(op)


def emit_x87(e, insn):
    op0 = insn.opcode[0]
    modrm = insn.modrm
    mod, reg, rm = modrm >> 6, (modrm >> 3) & 7, modrm & 7
    mem = None
    for o in insn.operands:
        if o.type == X.X86_OP_MEM:
            mem = e.addr(insn, o)
    if mod != 3 and mem is None:
        raise Unsupported('x87 mem operand')

    def fmem(bits):
        return (f'({{ uint32_t t_ = ld32({mem}); float f_; memcpy(&f_, &t_, 4); (double)f_; }})' if bits == 32 else
                f'({{ uint64_t t_ = ld64({mem}); double f_; memcpy(&f_, &t_, 8); f_; }})')

    def fstore(bits, v):
        if bits == 32:
            return f'{{ float f_ = (float)({v}); uint32_t t_; memcpy(&t_, &f_, 4); st32({mem}, t_); }}'
        return f'{{ double f_ = ({v}); uint64_t t_; memcpy(&t_, &f_, 8); st64({mem}, t_); }}'

    def imem(bits):
        return f'(double)(int{bits}_t)ld{bits}({mem})'

    def istore(bits, v, trunc):
        val = f'fist(({v}), {bits})' if trunc else f'fist(fround(c, {v}), {bits})'
        return f'st{bits}({mem}, (uint{bits}_t){val});'

    if mod != 3:
        if op0 in (0xd8, 0xdc, 0xda, 0xde):
            src = fmem(32) if op0 == 0xd8 else fmem(64) if op0 == 0xdc else imem(32) if op0 == 0xda else imem(16)
            if reg in ARITH:
                return [f'ST(0) = {_op(ARITH[reg], "ST(0)", src)};']
            if reg == 2:
                return [f'fcom_sw(c, ST(0), {src});']
            if reg == 3:
                return [f'fcom_sw(c, ST(0), {src}); fpop(c);']
        if op0 == 0xd9:
            if reg == 0: return [f'fpush(c, {fmem(32)});']
            if reg == 2: return [fstore(32, 'ST(0)')]
            if reg == 3: return [fstore(32, 'ST(0)'), 'fpop(c);']
            if reg == 4: return [f'fldenv_op(c, {mem});']
            if reg == 5: return [f'c->fcw = ld16({mem});']
            if reg == 6: return [f'fnstenv_op(c, {mem});']
            if reg == 7: return [f'st16({mem}, c->fcw);']
        if op0 == 0xdb:
            if reg == 0: return [f'fpush(c, {imem(32)});']
            if reg == 1: return [istore(32, 'ST(0)', True), 'fpop(c);']
            if reg == 2: return [istore(32, 'ST(0)', False)]
            if reg == 3: return [istore(32, 'ST(0)', False), 'fpop(c);']
            if reg == 5: return [f'fpush(c, f80_load({mem}));']
            if reg == 7: return [f'f80_store({mem}, ST(0)); fpop(c);']
        if op0 == 0xdd:
            if reg == 0: return [f'fpush(c, {fmem(64)});']
            if reg == 1: return [istore(64, 'ST(0)', True), 'fpop(c);']
            if reg == 2: return [fstore(64, 'ST(0)')]
            if reg == 3: return [fstore(64, 'ST(0)'), 'fpop(c);']
            if reg == 7: return [f'st16({mem}, fsw_get(c));']
        if op0 == 0xdf:
            if reg == 0: return [f'fpush(c, {imem(16)});']
            if reg == 1: return [istore(16, 'ST(0)', True), 'fpop(c);']
            if reg == 2: return [istore(16, 'ST(0)', False)]
            if reg == 3: return [istore(16, 'ST(0)', False), 'fpop(c);']
            if reg == 5: return [f'fpush(c, {imem(64)});']
            if reg == 7: return [istore(64, 'ST(0)', False), 'fpop(c);']
        raise Unsupported(f'x87 mem {op0:x}/{reg}')

    i = rm
    sti = f'ST({i})'
    if op0 == 0xd8:
        if reg in ARITH:
            return [f'ST(0) = {_op(ARITH[reg], "ST(0)", sti)};']
        if reg == 2: return [f'fcom_sw(c, ST(0), {sti});']
        if reg == 3: return [f'fcom_sw(c, ST(0), {sti}); fpop(c);']
    if op0 in (0xdc, 0xde):
        pop = ' fpop(c);' if op0 == 0xde else ''
        if op0 == 0xde and reg == 3 and rm == 1:
            return ['fcom_sw(c, ST(0), ST(1)); fpop(c); fpop(c);']
        expr = {0: f'{sti} + ST(0)', 1: f'{sti} * ST(0)', 4: f'ST(0) - {sti}', 5: f'{sti} - ST(0)',
                6: f'ST(0) / {sti}', 7: f'{sti} / ST(0)'}.get(reg)
        if expr:
            return [f'{sti} = {expr};{pop}']
        if reg in (2, 3) and op0 == 0xdc:
            return [f'fcom_sw(c, ST(0), {sti});' + (' fpop(c);' if reg == 3 else '')]
    if op0 == 0xd9:
        if reg == 0: return [f'{{ double v_ = {sti}; fpush(c, v_); }}']
        if reg == 1: return [f'{{ double t_ = ST(0); ST(0) = {sti}; {sti} = t_; }}']
        if reg == 3: return [f'{sti} = ST(0); fpop(c);']
        if modrm == 0xd0: return []
        table = {
            0xe0: 'ST(0) = -ST(0);', 0xe1: 'ST(0) = fabs(ST(0));', 0xe4: 'fcom_sw(c, ST(0), 0.0);', 0xe5: 'fxam(c);',
            0xe8: 'fpush(c, 1.0);', 0xe9: 'fpush(c, M_LN10 / M_LN2);', 0xea: 'fpush(c, M_LOG2E);', 0xeb: 'fpush(c, M_PI);',
            0xec: 'fpush(c, M_LN2 / M_LN10);', 0xed: 'fpush(c, M_LN2);', 0xee: 'fpush(c, 0.0);',
            0xf0: 'ST(0) = exp2(ST(0)) - 1.0;', 0xf1: 'ST(1) = ST(1) * log2(ST(0)); fpop(c);',
            0xf2: 'ST(0) = tan(ST(0)); fpush(c, 1.0); c->fsw &= ~0x400;', 0xf3: 'ST(1) = atan2(ST(1), ST(0)); fpop(c);',
            0xf4: 'fxtract_op(c);', 0xf5: 'fprem_op(c, 1);', 0xf6: 'c->ftop = (c->ftop - 1) & 7;',
            0xf7: 'c->ftop = (c->ftop + 1) & 7;', 0xf8: 'fprem_op(c, 0);', 0xf9: 'ST(1) = ST(1) * log2(ST(0) + 1.0); fpop(c);',
            0xfa: 'ST(0) = sqrt(ST(0));', 0xfb: '{ double v_ = ST(0); ST(0) = sin(v_); fpush(c, cos(v_)); c->fsw &= ~0x400; }',
            0xfc: 'ST(0) = fround(c, ST(0));', 0xfd: 'ST(0) = ldexp(ST(0), (int)trunc(ST(1)));',
            0xfe: 'ST(0) = sin(ST(0)); c->fsw &= ~0x400;', 0xff: 'ST(0) = cos(ST(0)); c->fsw &= ~0x400;',
        }
        if modrm in table:
            return [table[modrm]]
    if op0 == 0xda:
        if modrm == 0xe9:
            return ['fcom_sw(c, ST(0), ST(1)); fpop(c); fpop(c);']
        cond = {0: 'cf', 1: 'zf', 2: '(cf||zf)', 3: 'pf'}.get(reg)
        if cond:
            return [f'if ({cond}) ST(0) = {sti};']
    if op0 == 0xdb:
        cond = {0: '!cf', 1: '!zf', 2: '(!cf&&!zf)', 3: '!pf'}.get(reg)
        if cond:
            return [f'if ({cond}) ST(0) = {sti};']
        if modrm == 0xe2: return ['c->fsw &= 0x3800;']
        if modrm == 0xe3: return ['c->fcw = 0x37f; c->fsw = 0; c->ftop = 0;']
        if reg in (5, 6):
            return [f'{{ double a_ = ST(0), b_ = {sti}; UCOMI(a_, b_); }}']
    if op0 == 0xdd:
        if reg == 0: return []
        if reg == 2: return [f'{sti} = ST(0);']
        if reg == 3: return [f'{sti} = ST(0); fpop(c);']
        if reg == 4: return [f'fcom_sw(c, ST(0), {sti});']
        if reg == 5: return [f'fcom_sw(c, ST(0), {sti}); fpop(c);']
    if op0 == 0xdf:
        if modrm == 0xe0:
            e.gprs.add(0)
            return ['rax = (rax & ~0xffffULL) | fsw_get(c);']
        if reg in (5, 6):
            return [f'{{ double a_ = ST(0), b_ = {sti}; UCOMI(a_, b_); fpop(c); }}']
    raise Unsupported(f'x87 {op0:x} {modrm:x}')
