"""Differential tests of the lifter's instruction semantics.

Picks one instance of every distinct instruction form the game uses (no rip-relative, no rsp,
no control flow), then writes:
  work/semtest/x86_tests.s   each instruction between a full register/flag load and store (x86-64,
                             run under Rosetta as the reference)
  work/semtest/arm_tests.c   the lifted C of the same instructions (native ARM64)
  work/semtest/cases.txt     test list
usage: python -I gen.py <boot-linked.bin> <game dir> <out dir> [max tests]
"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'lifter'))
import capstone as cs  # noqa: E402
from capstone import x86 as X  # noqa: E402
from image import Image  # noqa: E402
from lift import Lifter, TERMINATORS, is_jcc  # noqa: E402
from x86emit import Emitter, Unsupported, GPR64  # noqa: E402

boot, game, out = sys.argv[1:4]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 100000
img = Image(boot, game)
L = Lifter(img)
os.makedirs(out, exist_ok=True)

SKIP = {'call', 'ret', 'jmp', 'push', 'pop', 'leave', 'enter', 'pushfq', 'popfq', 'syscall', 'int', 'int3',
        'ud2', 'hlt', 'cpuid', 'rdtsc', 'rdtscp', 'xgetbv', 'cli', 'sti', 'in', 'out', 'insd', 'iretd',
        'sysret', 'retf', 'fxsave', 'fxrstor', 'vldmxcsr', 'vstmxcsr', 'ldmxcsr', 'stmxcsr', 'pause',
        'lfence', 'mfence', 'sfence', 'nop', 'int1', 'vzeroupper', 'vzeroall', 'wait', 'fnstenv', 'fldenv',
        'div', 'idiv'}  # div/idiv: random inputs mostly fault (#DE)


def form(insn):
    parts = [insn.mnemonic]
    for o in insn.operands:
        if o.type == X.X86_OP_REG:
            n = insn.reg_name(o.reg)
            parts.append('ymm' if n.startswith('ymm') else 'xmm' if n.startswith('xmm') else f'r{o.size}'
                         if n not in ('cl',) else 'cl')
        elif o.type == X.X86_OP_IMM:
            parts.append(f'i{o.size}')
        else:
            parts.append(f'm{o.size}' + ('i' if o.mem.index else ''))
    return ' '.join(parts)


def ok(insn):
    m = insn.mnemonic
    if m in SKIP or m.startswith('j') or m.startswith('loop') or m.startswith('rep') or m.startswith('f'):
        return False
    if insn.group(X.X86_GRP_JUMP) or m in TERMINATORS or is_jcc(insn):
        return False
    if 0xd8 <= insn.opcode[0] <= 0xdf and not insn.opcode[1]:
        return False  # x87: separate tests
    for o in insn.operands:
        if o.type == X.X86_OP_REG and insn.reg_name(o.reg) in ('rsp', 'esp', 'sp', 'spl', 'rip'):
            return False
        if o.type == X.X86_OP_MEM:
            if o.mem.base in (X.X86_REG_RIP, X.X86_REG_RSP) or o.mem.index == X.X86_REG_RSP or \
                    o.mem.segment not in (0,) or not o.mem.base:
                return False
            if abs(o.mem.disp) > 0x400:
                return False
    regs_read, regs_write = insn.regs_access()
    for r in list(regs_read) + list(regs_write):
        if insn.reg_name(r) in ('rsp', 'esp', 'rip', 'fs', 'gs'):
            return False
    if m.startswith('lods') or m.startswith('stos') or m.startswith('movs') and len(insn.operands) == 2 and \
            all(o.type == X.X86_OP_MEM for o in insn.operands):
        return False
    return True


funcs = L.discover()
seen = {}
for s in sorted(funcs):
    for a, i in funcs[s]['insns'].items():
        if not i or not ok(i):
            continue
        k = form(i)
        if k not in seen:
            seen[k] = i
cases = list(seen.items())[:limit]
print(f'{len(cases)} instruction forms')

FLAG_NAMES = ['cf', 'pf', 'af', 'zf', 'sf', 'of']
FLAG_BITS = {'cf': 0, 'pf': 2, 'af': 4, 'zf': 6, 'sf': 7, 'of': 11}


def defined_flags(insn):
    """RFLAGS bits the instruction defines (modified and not undefined)."""
    ef = insn.eflags
    mask = 0
    for name, bit in FLAG_BITS.items():
        u = name.upper()
        mod = getattr(X, f'X86_EFLAGS_MODIFY_{u}', 0) | getattr(X, f'X86_EFLAGS_RESET_{u}', 0) | \
            getattr(X, f'X86_EFLAGS_SET_{u}', 0)
        und = getattr(X, f'X86_EFLAGS_UNDEFINED_{u}', 0)
        if ef & mod and not ef & und:
            mask |= 1 << bit
    return mask


# ---- ARM64 side: lifted C
c_lines = ['#include "x86.h"', '#pragma clang diagnostic ignored "-Wunused-variable"',
           '#pragma clang diagnostic ignored "-Wunused-but-set-variable"', '']
asm = ['.intel_syntax noprefix', '.data', '.p2align 6', '.globl _st', '_st: .space 1024',
       'save: .space 128', '.text']
# state layout (shared with the runners): r[16] at 0, flags at 128, ymm[16] (lo,hi) at 192
names = []
md = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
md.detail = True
emitted = 0
for idx, (k, i) in enumerate(cases):
    e = Emitter(md)
    try:
        body = e.emit(i)
    except (Unsupported, KeyError, AttributeError, IndexError, TypeError) as ex:
        print('skip', k, ex)
        continue
    n = f't{idx}'
    names.append((n, k, i, defined_flags(i)))
    c_lines.append(f'void {n}(Ctx *c) {{')
    c_lines.append(' '.join(f'uint64_t {GPR64[r]} = c->r[{r}];' for r in range(16)))
    c_lines.append(' '.join(f'simde__m128i vl{r} = c->x[{r}].lo, vh{r} = c->x[{r}].hi;' for r in range(16)))
    c_lines.append('uint8_t ' + ', '.join(f'{f} = (c->flags >> {FLAG_BITS[f]}) & 1' for f in FLAG_NAMES) +
                   ', df = 0;')
    text = '{ ' + ' '.join(body) + ' }'
    text = text.replace('/*ZEROUPPER*/', '').replace('/*ZEROALL*/', '')
    c_lines.append(text)
    c_lines.append(' '.join(f'c->r[{r}] = {GPR64[r]};' for r in range(16)))
    c_lines.append(' '.join(f'c->x[{r}].lo = vl{r}; c->x[{r}].hi = vh{r};' for r in range(16)))
    c_lines.append('c->flags = ' + ' | '.join(f'((uint64_t){f} << {FLAG_BITS[f]})' for f in FLAG_NAMES) + ';')
    c_lines.append('}')
    # x86 side
    asm.append(f'.globl _{n}')
    asm.append(f'_{n}:')
    asm += ['mov [rip+save], rbx', 'mov [rip+save+8], rbp', 'mov [rip+save+16], r12', 'mov [rip+save+24], r13',
            'mov [rip+save+32], r14', 'mov [rip+save+40], r15']
    for r in range(16):
        asm.append(f'vmovdqu ymm{r}, [rip+_st+{192 + 32 * r}]')
    asm.append('push qword ptr [rip+_st+128]')
    asm.append('popfq')
    for r, g in enumerate(GPR64):
        if g != 'rsp':
            asm.append(f'mov {g}, [rip+_st+{8 * r}]')
    asm.append('.byte ' + ','.join(str(b) for b in i.bytes))
    for r, g in enumerate(GPR64):
        if g != 'rsp':
            asm.append(f'mov [rip+_st+{8 * r}], {g}')
    asm.append('pushfq')
    asm.append('pop qword ptr [rip+_st+128]')
    for r in range(16):
        asm.append(f'vmovdqu [rip+_st+{192 + 32 * r}], ymm{r}')
    asm += ['mov rbx, [rip+save]', 'mov rbp, [rip+save+8]', 'mov r12, [rip+save+16]', 'mov r13, [rip+save+24]',
            'mov r14, [rip+save+32]', 'mov r15, [rip+save+40]', 'vzeroupper', 'ret']
    emitted += 1

# table of tests for both runners
tab_c = ['typedef void (*TestFn)(Ctx *);'] + [f'void {n}(Ctx *c);' for n, *_ in names]
tab_c.append('const TestFn arm_tests[] = {' + ','.join(n for n, *_ in names) + '};')
c_lines += tab_c
asm.append('.data')
asm.append('.globl _x86_tests')
asm.append('_x86_tests: .quad ' + ','.join(f'_{n}' for n, *_ in names))
open(os.path.join(out, 'arm_tests.c'), 'w').write('\n'.join(c_lines) + '\n')
open(os.path.join(out, 'x86_tests.s'), 'w').write('\n'.join(asm) + '\n')
with open(os.path.join(out, 'cases.txt'), 'w') as f:
    for n, k, i, mask in names:
        mem = [o for o in i.operands if o.type == X.X86_OP_MEM]
        em = Emitter(md)
        bases = sorted({em.gidx(o.mem.base) for o in mem})
        idx = sorted({em.gidx(o.mem.index) for o in mem if o.mem.index} - set(bases))
        # base registers point into the test buffer; index registers get small values (negative = index)
        regs = [str(b) for b in bases] + [str(-1 - x) for x in idx]
        f.write(f'{n}\t{mask}\t{",".join(regs)}\t{i.address:x}\t{i.mnemonic} {i.op_str}\n')
print(f'{emitted} tests written')
