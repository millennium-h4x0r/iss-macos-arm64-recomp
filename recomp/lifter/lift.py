"""Static recompiler driver: discovers guest functions and writes C sources.

usage: python -I lift.py <boot-linked.bin> <game dir> <out dir> [--only 0xaddr,...] [--chunk N]
"""
import argparse
import bisect
import collections
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capstone as cs  # noqa: E402
from capstone import x86 as X  # noqa: E402
from image import Image  # noqa: E402
from x86emit import Emitter, Unsupported, CC, GPR64  # noqa: E402

TERMINATORS = ('ret', 'jmp', 'ud2', 'hlt', 'int3', 'retf', 'iretq')
LOOPS = ('loop', 'loope', 'loopne', 'jrcxz', 'jecxz')


def is_jcc(insn):
    return insn.mnemonic in LOOPS or (insn.group(X.X86_GRP_JUMP) and insn.mnemonic != 'jmp')


class Lifter:
    def __init__(self, img):
        self.img = img
        self.md = cs.Cs(cs.CS_ARCH_X86, cs.CS_MODE_64)
        self.md.detail = True
        self.fdes = img.fdes()
        self.fde_starts = sorted(self.fdes)
        self.cache = {}
        self.unsupported = collections.Counter()
        self.unsupported_where = {}
        # code regions per module: [first FDE start, last FDE end)
        self.regions = []
        mods = [(0, img.modules[0]['base'] if img.modules else img.size)] + \
               [(m['base'], m['base'] + m['size']) for m in img.modules]
        for lo, hi in mods:
            starts = [s for s in self.fde_starts if lo <= s < hi]
            if starts:
                self.regions.append((starts[0], max(s + self.fdes[s] for s in starts)))

    def decode(self, a):
        insn = self.cache.get(a)
        if insn is None:
            if not self.img.executable(a):
                return None
            try:
                insn = next(self.md.disasm(bytes(self.img.image[a:a + 16]), a, 1))
            except StopIteration:
                insn = False
            self.cache[a] = insn
        return insn or None

    def in_code_region(self, a):
        return any(lo <= a < hi for lo, hi in self.regions)

    def fde_containing(self, a):
        i = bisect.bisect_right(self.fde_starts, a) - 1
        if i >= 0 and a < self.fde_starts[i] + self.fdes[self.fde_starts[i]]:
            return self.fde_starts[i]
        return None

    def plausible_entry(self, a):
        """Address-taken code pointer: an FDE start or code outside every FDE."""
        if not self.img.executable(a):
            return False
        if a in self.fdes:
            return True
        return self.in_code_region(a) and self.fde_containing(a) is None and self.decode(a) is not None

    def bounds(self, start):
        if start in self.fdes:
            return start, start + self.fdes[start]
        f = self.fde_containing(start)
        if f is not None:  # entry inside another function (mid-function tail target)
            return start, f + self.fdes[f]
        i = bisect.bisect_right(self.fde_starts, start)
        end = self.fde_starts[i] if i < len(self.fde_starts) else start + 0x10000
        return start, end

    # ------------------------------------------------------------ analysis
    def analyze(self, start):
        lo, hi = self.bounds(start)
        insns = {}
        todo = [start]
        labels = {start}
        calls, tails, addr_taken = set(), set(), set()
        tables = {}
        indirect = {}
        while True:
          while todo:
            pc = todo.pop()
            window = []
            while lo <= pc < hi and pc not in insns:
                insn = self.decode(pc)
                if insn is None:
                    insns[pc] = None
                    break
                insns[pc] = insn
                window.append(insn)
                m = insn.mnemonic
                ops = insn.operands
                # address-taken code: lea reg, [rip+X] / mov reg, imm into code
                if m == 'lea' and ops[1].mem.base == X.X86_REG_RIP:
                    t = insn.address + insn.size + ops[1].mem.disp
                    if self.img.executable(t):
                        addr_taken.add(t)
                nxt = pc + insn.size
                if m in ('ret', 'retf', 'ud2', 'hlt', 'int3', 'iretq'):
                    break
                if m == 'jmp':
                    op = ops[0]
                    if op.type == X.X86_OP_IMM:
                        t = op.imm
                        if lo <= t < hi:
                            todo.append(t); labels.add(t)
                        else:
                            tails.add(t)
                    elif op.type == X.X86_OP_REG:
                        indirect[pc] = window[-128:]
                        tg = self.jump_table(window, insn, lo, hi, insns)
                        if tg:
                            tables[pc] = tg
                            for t in tg:
                                todo.append(t); labels.add(t)
                    break
                if is_jcc(insn):
                    op = ops[0]
                    if op.type == X.X86_OP_IMM:
                        if lo <= op.imm < hi:
                            todo.append(op.imm); labels.add(op.imm)
                        else:
                            tails.add(op.imm)
                elif m == 'call':
                    op = ops[0]
                    if op.type == X.X86_OP_IMM:
                        calls.add(op.imm)
                pc = nxt
          # tables whose base was set up on another path: retry with every decoded instruction
          grew = False
          for site, win in indirect.items():
              tg = self.jump_table(win, insns[site], lo, hi, insns, everything=True)
              if not tg:
                  # the window is the trace that first decoded the jump, which can start just
                  # before it (a label reached from elsewhere); use the code preceding it by address
                  prev = [insns[b] for b in sorted(insns) if b < site and insns[b]][-128:]
                  tg = self.jump_table(prev, insns[site], lo, hi, insns, everything=True)
              if tg:
                  new = [t for t in tg if t not in labels]
                  tables[site] = sorted(set(tables.get(site, [])) | set(tg))
                  for t in new:
                      todo.append(t); labels.add(t); grew = True
          if not grew:
              break
        return dict(start=start, lo=lo, hi=hi, insns=insns, labels=labels, calls=calls, tails=tails,
                    tables=tables, addr_taken=addr_taken)

    def jump_table(self, window, insn, lo, hi, insns, everything=False):
        """Relative switch tables: movsxd rX, [rB + rI*4] ; add ; jmp reg. The table base is a
        rip-relative lea, possibly copied between registers; every data-pointing lea of the
        function is tried and the valid targets are merged (a wrong extra case never matches)."""
        if not any(w.mnemonic in ('movsxd', 'mov') and len(w.operands) == 2 and w.operands[1].type == X.X86_OP_MEM
                   and w.operands[1].mem.scale == 4 and w.operands[1].mem.index for w in window[-96:]):
            return None
        bound = None
        for w in reversed(window[-128:]):
            o = w.operands
            if w.mnemonic == 'cmp' and len(o) == 2 and o[1].type == X.X86_OP_IMM:
                bound = (o[1].imm & 0xffffffff) + 1
                break
        src = insns.values() if everything else window
        cands = set()
        for i in src:
            if i and i.mnemonic == 'lea' and i.operands[1].mem.base == X.X86_REG_RIP:
                t = i.address + i.size + i.operands[1].mem.disp
                if 0 <= t < len(self.img.image) - 4:
                    cands.add(t)
        out = set()
        for table in cands:
            got = []
            n = bound if bound and bound < 4096 else 1024
            for k in range(n):
                if table + 4 * k + 4 > len(self.img.image):
                    break
                t = table + self.img.s32(table + 4 * k)
                if not (lo <= t < hi) or self.decode(t) is None:
                    break
                got.append(t)
            # `cmp idx, N; ja` allows N+1 entries, `cmp idx, N; jae` N
            if got and (not bound or len(got) >= bound - 1):
                out.update(got)
        return sorted(out) or None

    # ------------------------------------------------------------ discovery
    def discover(self, extra=()):
        img = self.img
        seeds = set(self.fde_starts)
        seeds.add(img.entry)
        for m in img.modules:
            seeds.add(m['init'])
        for index, address, kind in img.bindings:
            if kind == 1:
                seeds.add(address)
        for target, kind, value, addend in img.relocs:
            if kind == 0 and self.plausible_entry(value):
                seeds.add(value)
        seeds.update(extra)
        funcs = {}
        work = list(seeds)
        while work:
            s = work.pop()
            if s in funcs or not img.executable(s):
                continue
            f = self.analyze(s)
            funcs[s] = f
            for t in f['calls'] | f['tails']:
                if t not in funcs and img.executable(t):
                    work.append(t)
            for t in f['addr_taken']:
                if t not in funcs and self.plausible_entry(t):
                    work.append(t)
        return funcs

    # ------------------------------------------------------------ emission
    def emit_function(self, f, known):
        e = Emitter(self.md)
        body = []
        insns = f['insns']
        order = sorted(a for a, i in insns.items() if i)
        labels = set(f['labels'])
        start = f['start']
        # labels for fallthrough gaps
        for idx, a in enumerate(order):
            i = insns[a]
            ft = a + i.size
            if i.mnemonic not in TERMINATORS and (idx + 1 >= len(order) or order[idx + 1] != ft) and insns.get(ft):
                labels.add(ft)

        def fname(t):
            return f'F_{t:x}'

        def tail(t):
            t &= 0xffffffffffffffff
            if t in known:
                return f'{{ SPILL(); MUSTTAIL return {fname(t)}(c); }}'
            return f'{{ SPILL(); MUSTTAIL return recomp_lookup(IMG+0x{t:x}ULL)(c); }}'

        for idx, a in enumerate(order):
            i = insns[a]
            if a in labels:
                body.append(f'L_{a:x}:;')
            m = i.mnemonic
            ops = i.operands
            nxt = a + i.size
            falls = True
            try:
                if m == 'ret':
                    e.gprs.add(4)
                    n = 8 + (ops[0].imm if ops else 0)
                    body.append(f'rsp += {n}; SPILL(); return;')
                    falls = False
                elif m == 'jmp':
                    op = ops[0]
                    falls = False
                    if op.type == X.X86_OP_IMM:
                        t = op.imm
                        body.append(f'goto L_{t:x};' if t in insns and insns[t] else tail(t))
                    else:
                        tv = e.read(i, op, 8)
                        if a in f['tables']:
                            cases = ' '.join(f'case IMG+0x{t:x}ULL: goto L_{t:x};' for t in sorted(set(f['tables'][a])) if insns.get(t))
                            body.append(f'{{ uint64_t t = {tv}; switch (t) {{ {cases} default: SPILL(); MUSTTAIL return recomp_lookup(t)(c); }} }}')
                        else:
                            body.append(f'{{ uint64_t t = {tv}; SPILL(); MUSTTAIL return recomp_lookup(t)(c); }}')
                elif is_jcc(i):
                    t = ops[0].imm
                    if m in ('loop', 'loope', 'loopne'):
                        e.gprs.add(1)
                        cond = {'loop': '--rcx != 0', 'loope': '--rcx != 0 && zf', 'loopne': '--rcx != 0 && !zf'}[m]
                    elif m in ('jrcxz', 'jecxz'):
                        e.gprs.add(1)
                        cond = 'rcx == 0' if m == 'jrcxz' else '(uint32_t)rcx == 0'
                    else:
                        cond = CC[m[1:]]
                    target = f'goto L_{t:x};' if t in insns and insns[t] else tail(t)
                    body.append(f'if ({cond}) {target}')
                elif m == 'call':
                    op = ops[0]
                    e.gprs.add(4)
                    ret = f'IMG+0x{nxt:x}ULL'
                    if op.type == X.X86_OP_IMM:
                        t = op.imm & 0xffffffffffffffff
                        callee = fname(t) if t in known else f'recomp_lookup(IMG+0x{t:x}ULL)'
                        body.append(f'rsp -= 8; st64(rsp, {ret}); SPILL(); {callee}(c); RELOAD();')
                    else:
                        tv = e.read(i, op, 8)
                        body.append(f'{{ uint64_t t = {tv}; rsp -= 8; st64(rsp, {ret}); SPILL(); recomp_lookup(t)(c); RELOAD(); }}')
                elif m in ('ud2', 'hlt', 'int3', 'retf', 'iretq'):
                    body.append(f'SPILL(); recomp_trap(0x{a:x}ULL, "{m}");')
                    falls = False
                elif m == 'int':
                    body.append(f'SPILL(); recomp_int(c, 0x{a:x}ULL, {ops[0].imm}); RELOAD();')
                else:
                    lines = e.emit(i)
                    body.append('{ ' + ' '.join(lines) + ' }')
            except (Unsupported, KeyError, AttributeError, IndexError, TypeError) as ex:
                key = f'{m} {i.op_str}' if isinstance(ex, Unsupported) and str(ex).startswith('register') else m
                self.unsupported[m] += 1
                self.unsupported_where.setdefault(m, (a, f'{m} {i.op_str}', repr(ex)))
                text = f'{m} {i.op_str}'.replace('\\', '').replace('"', "'")
                body.append(f'SPILL(); recomp_unimpl(0x{a:x}ULL, "{text}");')
                falls = False
            if falls:
                if idx + 1 < len(order) and order[idx + 1] == nxt:
                    continue
                if insns.get(nxt):
                    body.append(f'goto L_{nxt:x};')
                elif nxt >= f['hi'] or nxt not in insns:
                    # ran past the decoded code (noreturn call, or the function's end)
                    if nxt in known and nxt != start:
                        body.append(tail(nxt))
                    else:
                        body.append(f'SPILL(); recomp_trap(0x{nxt:x}ULL, "fell off decoded code");')
        # prologue / spill sets
        g = sorted(e.gprs)
        v = sorted(e.vregs)
        decl = []
        if g:
            decl.append('uint64_t ' + ', '.join(f'{GPR64[k]} = c->r[{k}]' for k in g) + ';')
        for k in v:
            decl.append(f'simde__m128i vl{k} = c->x[{k}].lo, vh{k} = c->x[{k}].hi;')
        spill = ' '.join([f'c->r[{k}] = {GPR64[k]};' for k in g] + [f'c->x[{k}].lo = vl{k}; c->x[{k}].hi = vh{k};' for k in v])
        reload = ' '.join([f'{GPR64[k]} = c->r[{k}];' for k in g] + [f'vl{k} = c->x[{k}].lo; vh{k} = c->x[{k}].hi;' for k in v])
        zu = ' '.join(f'vh{k} = VZERO;' if k in e.vregs else f'c->x[{k}].hi = VZERO;' for k in range(16))
        za = ' '.join(f'vl{k} = VZERO; vh{k} = VZERO;' if k in e.vregs else f'c->x[{k}].lo = VZERO; c->x[{k}].hi = VZERO;' for k in range(16))
        text = '\n'.join(body).replace('/*ZEROUPPER*/', zu).replace('/*ZEROALL*/', za)
        out = [f'void F_{start:x}(Ctx *c) {{',
               f'#define SPILL() do {{ {spill} }} while (0)',
               f'#define RELOAD() do {{ {reload} }} while (0)',
               *decl,
               'uint8_t cf = 0, pf = 0, af = 0, zf = 0, sf = 0, of = 0, df = 0;',
               '(void)cf; (void)pf; (void)af; (void)zf; (void)sf; (void)of; (void)df;',
               text,
               '#undef SPILL', '#undef RELOAD', '}', '']
        return '\n'.join(out), len(order)


NATIVE_SITES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'iss_native_sites.json')


def apply_native_sites(img):
    """Native render resolution (port/src/iss_native_resolution.h; tools/native_sites.c): patch
    the resolution-independent sites into the image before lifting, and have the resolution
    immediates read from guest memory at run time (x86emit runtime_imm), where rt/main.c
    writes the player's choice. Skipped when the executable does not match byte for byte."""
    import json
    if not os.path.exists(NATIVE_SITES):
        return
    sites = json.load(open(NATIVE_SITES))
    data = img.image if isinstance(img.image, bytearray) else bytearray(img.image)
    for s in sites['fixed'] + sites['dynamic']:
        if data[s['offset']:s['offset'] + len(s['before']) // 2] != bytes.fromhex(s['before']):
            print('native resolution: executable differs, sites not applied', flush=True)
            return
    for s in sites['fixed']:
        after = bytes.fromhex(s['after'])
        data[s['offset']:s['offset'] + len(after)] = after
    img.image = data
    Emitter.runtime_imm = {s['offset']: s['offset'] + s['length'] - 4 for s in sites['dynamic']}
    print(f"native resolution: {len(sites['fixed'])} fixed sites patched, "
          f"{len(sites['dynamic'])} immediates read at run time", flush=True)



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('boot'); ap.add_argument('game'); ap.add_argument('out')
    ap.add_argument('--chunk', type=int, default=30000, help='instructions per C file')
    ap.add_argument('--seeds', help='file with extra function addresses (hex, one per line)')
    a = ap.parse_args()
    t0 = time.time()
    img = Image(a.boot, a.game)
    apply_native_sites(img)
    L = Lifter(img)
    extra = []
    if a.seeds and os.path.exists(a.seeds):
        extra = [int(x.split()[0], 16) for x in open(a.seeds) if x.strip() and not x.startswith('#')]
    funcs = L.discover(extra)
    print(f'{len(funcs)} functions discovered in {time.time() - t0:.1f}s', flush=True)
    os.makedirs(a.out, exist_ok=True)
    known = set(funcs)
    chunk, chunk_insns, files = [], 0, []
    total = 0

    def flush():
        nonlocal chunk, chunk_insns
        if not chunk:
            return
        name = f'f{len(files):04d}.c'
        with open(os.path.join(a.out, name + '.tmp'), 'w') as fp:
            fp.write('#include "x86.h"\n#include "decls.h"\n#pragma clang diagnostic ignored "-Wunused-label"\n')
            fp.write('#pragma clang diagnostic ignored "-Wunused-variable"\n#pragma clang diagnostic ignored "-Wunused-but-set-variable"\n')
            fp.write(''.join(chunk))
        os.replace(os.path.join(a.out, name + '.tmp'), os.path.join(a.out, name))
        files.append(name)
        chunk, chunk_insns = [], 0

    for s in sorted(funcs):
        code, n = L.emit_function(funcs[s], known)
        chunk.append(code)
        chunk_insns += n
        total += n
        if chunk_insns >= a.chunk:
            flush()
    flush()
    with open(os.path.join(a.out, 'decls.h'), 'w') as fp:
        fp.write('#pragma once\n' + ''.join(f'void F_{s:x}(Ctx *c);\n' for s in sorted(funcs)))
    with open(os.path.join(a.out, 'table.c'), 'w') as fp:
        fp.write('#include "x86.h"\n#include "decls.h"\n#include "recomp_table.h"\n')
        fp.write('const RecompEntry recomp_table[] = {\n')
        fp.write(''.join(f'{{0x{s:x}ULL, F_{s:x}}},\n' for s in sorted(funcs)))
        fp.write('};\nconst unsigned long recomp_table_count = sizeof(recomp_table) / sizeof(*recomp_table);\n')
    for old in os.listdir(a.out):
        if old.startswith('f') and old.endswith('.c') and old not in files:
            os.remove(os.path.join(a.out, old))
    with open(os.path.join(a.out, 'files.txt'), 'w') as fp:
        fp.write('\n'.join(files) + '\n')
    report = dict(functions=len(funcs), instructions=total, files=len(files),
                  unsupported=dict(L.unsupported.most_common()),
                  unsupported_examples={k: [hex(v[0]), v[1], v[2]] for k, v in L.unsupported_where.items()})
    json.dump(report, open(os.path.join(a.out, 'report.json'), 'w'), indent=1)
    print(f'{total} instructions in {len(files)} files, {time.time() - t0:.1f}s')
    print('unsupported:', L.unsupported.most_common(40))


if __name__ == '__main__':
    main()
