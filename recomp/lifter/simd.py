"""SSE/AVX(1)/F16C/SSE4a translation onto SIMDe 128-bit intrinsics.

A ymm register is two 128-bit halves; lane-wise 256-bit operations run per half.
VEX-encoded 128-bit writes zero bits 128..255; legacy SSE writes keep them.
"""
from capstone import x86 as X
from x86emit import Unsupported, U

# binary lane-wise ops: base mnemonic -> (template, kind). {a},{b} are simde__m128i expressions.
def _ps(fn): return (f'SI_PS({fn}(PS({{a}}), PS({{b}})))', 'v')
def _pd(fn): return (f'SI_PD({fn}(PD({{a}}), PD({{b}})))', 'v')
def _si(fn): return (f'{fn}({{a}}, {{b}})', 'v')

BIN = {}
for op in ['add', 'sub', 'mul', 'div', 'min', 'max', 'and', 'andn', 'or', 'xor', 'hadd', 'hsub', 'addsub']:
    fn = 'andnot' if op == 'andn' else op
    BIN[op + 'ps'] = _ps(f'simde_mm_{fn}_ps')
    BIN[op + 'pd'] = _pd(f'simde_mm_{fn}_pd')
for op in ['add', 'sub', 'mul', 'div', 'min', 'max']:
    BIN[op + 'ss'] = (f'SI_PS(simde_mm_{op}_ss(PS({{a}}), PS({{b}})))', 's')
    BIN[op + 'sd'] = (f'SI_PD(simde_mm_{op}_sd(PD({{a}}), PD({{b}})))', 's')
BIN['unpcklps'] = _ps('simde_mm_unpacklo_ps'); BIN['unpckhps'] = _ps('simde_mm_unpackhi_ps')
BIN['unpcklpd'] = _pd('simde_mm_unpacklo_pd'); BIN['unpckhpd'] = _pd('simde_mm_unpackhi_pd')
BIN['movhlps'] = _ps('simde_mm_movehl_ps'); BIN['movlhps'] = _ps('simde_mm_movelh_ps')
for name, fn in [('paddb', 'add_epi8'), ('paddw', 'add_epi16'), ('paddd', 'add_epi32'), ('paddq', 'add_epi64'),
                 ('psubb', 'sub_epi8'), ('psubw', 'sub_epi16'), ('psubd', 'sub_epi32'), ('psubq', 'sub_epi64'),
                 ('paddusb', 'adds_epu8'), ('paddusw', 'adds_epu16'), ('paddsb', 'adds_epi8'), ('paddsw', 'adds_epi16'),
                 ('psubusb', 'subs_epu8'), ('psubusw', 'subs_epu16'), ('psubsb', 'subs_epi8'), ('psubsw', 'subs_epi16'),
                 ('pmulld', 'mullo_epi32'), ('pmullw', 'mullo_epi16'), ('pmulhw', 'mulhi_epi16'), ('pmulhuw', 'mulhi_epu16'),
                 ('pmuludq', 'mul_epu32'), ('pmuldq', 'mul_epi32'), ('pmaddwd', 'madd_epi16'), ('pmaddubsw', 'maddubs_epi16'),
                 ('pand', 'and_si128'), ('pandn', 'andnot_si128'), ('por', 'or_si128'), ('pxor', 'xor_si128'),
                 ('pcmpeqb', 'cmpeq_epi8'), ('pcmpeqw', 'cmpeq_epi16'), ('pcmpeqd', 'cmpeq_epi32'), ('pcmpeqq', 'cmpeq_epi64'),
                 ('pcmpgtb', 'cmpgt_epi8'), ('pcmpgtw', 'cmpgt_epi16'), ('pcmpgtd', 'cmpgt_epi32'), ('pcmpgtq', 'cmpgt_epi64'),
                 ('pmaxsb', 'max_epi8'), ('pmaxsw', 'max_epi16'), ('pmaxsd', 'max_epi32'), ('pmaxub', 'max_epu8'),
                 ('pmaxuw', 'max_epu16'), ('pmaxud', 'max_epu32'), ('pminsb', 'min_epi8'), ('pminsw', 'min_epi16'),
                 ('pminsd', 'min_epi32'), ('pminub', 'min_epu8'), ('pminuw', 'min_epu16'), ('pminud', 'min_epu32'),
                 ('packssdw', 'packs_epi32'), ('packsswb', 'packs_epi16'), ('packusdw', 'packus_epi32'), ('packuswb', 'packus_epi16'),
                 ('punpcklbw', 'unpacklo_epi8'), ('punpcklwd', 'unpacklo_epi16'), ('punpckldq', 'unpacklo_epi32'),
                 ('punpcklqdq', 'unpacklo_epi64'), ('punpckhbw', 'unpackhi_epi8'), ('punpckhwd', 'unpackhi_epi16'),
                 ('punpckhdq', 'unpackhi_epi32'), ('punpckhqdq', 'unpackhi_epi64'), ('pshufb', 'shuffle_epi8'),
                 ('pavgb', 'avg_epu8'), ('pavgw', 'avg_epu16'), ('psadbw', 'sad_epu8'), ('phaddd', 'hadd_epi32'),
                 ('phaddw', 'hadd_epi16'), ('phsubd', 'hsub_epi32'), ('phsubw', 'hsub_epi16'),
                 ('psignb', 'sign_epi8'), ('psignw', 'sign_epi16'), ('psignd', 'sign_epi32'),
                 ('psllw', 'sll_epi16'), ('pslld', 'sll_epi32'), ('psllq', 'sll_epi64'),
                 ('psrlw', 'srl_epi16'), ('psrld', 'srl_epi32'), ('psrlq', 'srl_epi64'),
                 ('psraw', 'sra_epi16'), ('psrad', 'sra_epi32')]:
    BIN[name] = _si('simde_mm_' + fn)
SHIFT_IMM = {'psllw': 'slli_epi16', 'pslld': 'slli_epi32', 'psllq': 'slli_epi64', 'psrlw': 'srli_epi16',
             'psrld': 'srli_epi32', 'psrlq': 'srli_epi64', 'psraw': 'srai_epi16', 'psrad': 'srai_epi32',
             'pslldq': 'slli_si128', 'psrldq': 'srli_si128'}

CMP_PRED = {'eq': 0, 'lt': 1, 'le': 2, 'unord': 3, 'neq': 4, 'nlt': 5, 'nle': 6, 'ord': 7,
            'eq_uq': 8, 'nge': 9, 'ngt': 10, 'false': 11, 'neq_oq': 12, 'ge': 13, 'gt': 14, 'true': 15}

# unary (dst, src) lane-wise ops
UN = {
    'sqrtps': 'SI_PS(simde_mm_sqrt_ps(PS({a})))', 'sqrtpd': 'SI_PD(simde_mm_sqrt_pd(PD({a})))',
    'rcpps': 'SI_PS(simde_mm_rcp_ps(PS({a})))', 'rsqrtps': 'SI_PS(simde_mm_rsqrt_ps(PS({a})))',
    'cvtdq2ps': 'SI_PS(simde_mm_cvtepi32_ps({a}))', 'cvtps2dq': 'simde_mm_cvtps_epi32(PS({a}))',
    'cvttps2dq': 'simde_mm_cvttps_epi32(PS({a}))',
    'movaps': '{a}', 'movups': '{a}', 'movapd': '{a}', 'movupd': '{a}', 'movdqa': '{a}', 'movdqu': '{a}',
    'lddqu': '{a}', 'movntdqa': '{a}', 'movntps': '{a}', 'movntdq': '{a}', 'movntpd': '{a}',
    'movshdup': 'SI_PS(simde_mm_movehdup_ps(PS({a})))', 'movsldup': 'SI_PS(simde_mm_moveldup_ps(PS({a})))',
    'pabsb': 'simde_mm_abs_epi8({a})', 'pabsw': 'simde_mm_abs_epi16({a})', 'pabsd': 'simde_mm_abs_epi32({a})',
}
PMOVX = {'pmovzxbw': 'cvtepu8_epi16', 'pmovzxbd': 'cvtepu8_epi32', 'pmovzxbq': 'cvtepu8_epi64',
         'pmovzxwd': 'cvtepu16_epi32', 'pmovzxwq': 'cvtepu16_epi64', 'pmovzxdq': 'cvtepu32_epi64',
         'pmovsxbw': 'cvtepi8_epi16', 'pmovsxbd': 'cvtepi8_epi32', 'pmovsxbq': 'cvtepi8_epi64',
         'pmovsxwd': 'cvtepi16_epi32', 'pmovsxwq': 'cvtepi16_epi64', 'pmovsxdq': 'cvtepi32_epi64'}


def is_v(e, op):
    return op.type == X.X86_OP_REG and e.is_vreg(op.reg)


def wide_of(e, ops):
    for o in ops:
        if o.type == X.X86_OP_REG and e.is_vreg(o.reg) and e.vidx(o.reg)[1]:
            return True
    return False


def imm_of(ops):
    for o in ops:
        if o.type == X.X86_OP_IMM:
            return o.imm & 0xff
    return None


def emit_simd(e, insn, m, vex):
    ops = list(insn.operands)
    wide = wide_of(e, ops)
    imm = imm_of(ops)
    vops = [o for o in ops if o.type != X.X86_OP_IMM]

    def three():
        """(dst, src1, src2) for lane-wise binary ops in both encodings."""
        if vex and len(vops) >= 3:
            return vops[0], vops[1], vops[2]
        return vops[0], vops[0], vops[1]

    def bin_lanes(tmpl, extra=None):
        d, s1, s2 = three()
        a_lo, a_hi = e.vsrc(insn, s1, wide)
        b_lo, b_hi = e.vsrc(insn, s2, wide)
        lo = tmpl(a_lo, b_lo, 0)
        hi = tmpl(a_hi, b_hi, 1) if wide else None
        return ['{'] + [f'simde__m128i rl = {lo};'] + ([f'simde__m128i rh = {hi};'] if wide else []) + \
            e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']

    def un_lanes(tmpl):
        d, s = vops[0], vops[1]
        a_lo, a_hi = e.vsrc(insn, s, wide)
        lo = tmpl(a_lo, 0)
        hi = tmpl(a_hi, 1) if wide else None
        return ['{', f'simde__m128i rl = {lo};'] + ([f'simde__m128i rh = {hi};'] if wide else []) + \
            e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']

    def scalar_bin(tmpl, memsize):
        """VEX scalar: dst = src1 with low element op(src1, src2); legacy: dst op= src."""
        d, s1, s2 = three()
        a_lo, _ = e.vsrc(insn, s1, False)
        b_lo, _ = e.vsrc(insn, s2, False, memsize)
        return ['{', f'simde__m128i rl = {tmpl.format(a=a_lo, b=b_lo)};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']

    # ------------------------------------------------------------- dispatch
    if m in BIN:
        tmpl, kind = BIN[m]
        if kind == 's':
            return scalar_bin(tmpl, 4 if m.endswith('ss') else 8)
        if m in ('psllw', 'pslld', 'psllq', 'psrlw', 'psrld', 'psrlq', 'psraw', 'psrad') and imm is not None:
            fn = SHIFT_IMM[m]
            return _vex_shift_imm(e, insn, vops, fn, imm, wide, vex)
        if m in ('psllw', 'pslld', 'psllq', 'psrlw', 'psrld', 'psrlq', 'psraw', 'psrad'):
            # count operand is always the low 64 bits of a 128-bit source, shared by both halves
            d, s1, s2 = three()
            a_lo, a_hi = e.vsrc(insn, s1, wide)
            b_lo, _ = e.vsrc(insn, s2, False)
            fn = BIN[m][0]
            lo = fn.format(a=a_lo, b='cnt')
            hi = fn.format(a=a_hi, b='cnt')
            return ['{', f'simde__m128i cnt = {b_lo};', f'simde__m128i rl = {lo};'] + \
                ([f'simde__m128i rh = {hi};'] if wide else []) + e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']
        return bin_lanes(lambda a, b, h: tmpl.format(a=a, b=b))
    if m in ('pslldq', 'psrldq'):
        fn = SHIFT_IMM[m]
        return _vex_shift_imm(e, insn, vops, fn, imm, wide, vex)
    if m in UN:
        if m.startswith('movnt') or m in ('movaps', 'movups', 'movapd', 'movupd', 'movdqa', 'movdqu') and vops[0].type == X.X86_OP_MEM:
            d, s = vops[0], vops[1]
            lo, hi = e.vsrc(insn, s, wide)
            return ['{', f'simde__m128i rl = {lo};'] + ([f'simde__m128i rh = {hi};'] if wide else []) + \
                e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']
        return un_lanes(lambda a, h: UN[m].format(a=a))
    if m in PMOVX:
        d, s = vops[0], vops[1]
        size = {'bw': 8, 'bd': 4, 'bq': 2, 'wd': 8, 'wq': 4, 'dq': 8}[m[-2:]]
        lo, _ = e.vsrc(insn, s, False, size)
        return ['{', f'simde__m128i rl = simde_mm_{PMOVX[m]}({lo});'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']

    # compares with predicate in the mnemonic (cmpleps) or immediate (cmpps x, y, imm)
    if m.startswith('cmp') and m[-2:] in ('ps', 'pd', 'ss', 'sd') and m not in ('cmpsd',) or m in ('cmpps', 'cmppd', 'cmpss') or (m == 'cmpsd' and len(ops) >= 3):
        suf = m[-2:]
        pred_name = m[3:-2]
        pred = CMP_PRED[pred_name] if pred_name else imm
        if pred is None:
            raise Unsupported('cmp predicate')
        names = {0: 'cmpeq', 1: 'cmplt', 2: 'cmple', 3: 'cmpunord', 4: 'cmpneq', 5: 'cmpnlt', 6: 'cmpnle', 7: 'cmpord',
                 13: 'cmpge', 14: 'cmpgt', 9: 'cmpnge', 10: 'cmpngt'}
        if pred in (8, 12):  # unordered-or-equal / ordered-not-equal: rarely used
            raise Unsupported(f'cmp pred {pred}')
        if pred == 11 or pred == 15:
            val = 'VZERO' if pred == 11 else 'simde_mm_set1_epi32(-1)'
            return bin_lanes(lambda a, b, h: val)
        fn = names[pred]
        if suf in ('ps', 'pd'):
            cast, back = ('PS', 'SI_PS') if suf == 'ps' else ('PD', 'SI_PD')
            return bin_lanes(lambda a, b, h: f'{back}(simde_mm_{fn}_{suf}({cast}({a}), {cast}({b})))')
        cast, back = ('PS', 'SI_PS') if suf == 'ss' else ('PD', 'SI_PD')
        return scalar_bin(f'{back}(simde_mm_{fn}_{suf}({cast}({{a}}), {cast}({{b}})))', 4 if suf == 'ss' else 8)

    if m in ('sqrtss', 'sqrtsd', 'rcpss', 'rsqrtss'):
        suf = m[-2:]
        cast, back = ('PS', 'SI_PS') if suf == 'ss' else ('PD', 'SI_PD')
        fn = {'sqrtss': 'sqrt_ss', 'sqrtsd': 'sqrt_sd', 'rcpss': 'rcp_ss', 'rsqrtss': 'rsqrt_ss'}[m]
        if fn == 'sqrt_sd':
            return scalar_bin('SI_PD(simde_mm_sqrt_sd(PD({a}), PD({b})))', 8)
        # _ss forms take one argument: low = f(b), rest from a
        return scalar_bin(f'SI_PS(simde_mm_move_ss(PS({{a}}), simde_mm_{fn}(PS({{b}}))))', 4)

    if m in ('roundss', 'roundsd'):
        suf = m[-2:]
        cast, back = ('PS', 'SI_PS') if suf == 'ss' else ('PD', 'SI_PD')
        return scalar_bin(f'{back}(simde_mm_round_{suf}({cast}({{a}}), {cast}({{b}}), {imm & 0xf}))', 4 if suf == 'ss' else 8)
    if m in ('roundps', 'roundpd'):
        cast, back = ('PS', 'SI_PS') if m == 'roundps' else ('PD', 'SI_PD')
        return un_lanes(lambda a, h: f'{back}(simde_mm_round_{m[-2:]}({cast}({a}), {imm & 0xf}))')

    if m in ('shufps', 'shufpd'):
        cast, back = ('PS', 'SI_PS') if m == 'shufps' else ('PD', 'SI_PD')
        if m == 'shufps':
            return bin_lanes(lambda a, b, h: f'{back}(simde_mm_shuffle_ps({cast}({a}), {cast}({b}), {imm}))')
        return bin_lanes(lambda a, b, h: f'{back}(simde_mm_shuffle_pd({cast}({a}), {cast}({b}), {(imm >> (2 * h)) & 3}))')
    if m in ('blendps', 'blendpd'):
        if m == 'blendps':
            return bin_lanes(lambda a, b, h: f'SI_PS(simde_mm_blend_ps(PS({a}), PS({b}), {(imm >> (4 * h)) & 0xf}))')
        return bin_lanes(lambda a, b, h: f'SI_PD(simde_mm_blend_pd(PD({a}), PD({b}), {(imm >> (2 * h)) & 3}))')
    if m == 'pblendw':
        return bin_lanes(lambda a, b, h: f'simde_mm_blend_epi16({a}, {b}, {imm})')
    if m == 'palignr':
        return bin_lanes(lambda a, b, h: f'simde_mm_alignr_epi8({a}, {b}, {imm})')
    if m == 'dpps':
        return bin_lanes(lambda a, b, h: f'SI_PS(simde_mm_dp_ps(PS({a}), PS({b}), {imm}))')
    if m == 'dppd':
        return bin_lanes(lambda a, b, h: f'SI_PD(simde_mm_dp_pd(PD({a}), PD({b}), {imm}))')
    if m == 'insertps':
        d, s1, s2 = three()
        a_lo, _ = e.vsrc(insn, s1, False)
        if s2.type == X.X86_OP_MEM:
            # memory form: a 32-bit value, count_s ignored
            b = f'v_from32(ld32({e.addr(insn, s2)}))'
            iv = imm & 0x3f
        else:
            b = e.vsrc(insn, s2, False)[0]
            iv = imm
        return ['{', f'simde__m128i rl = SI_PS(simde_mm_insert_ps(PS({a_lo}), PS({b}), {iv}));'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
    if m in ('blendvps', 'blendvpd', 'pblendvb'):
        if vex:
            d, s1, s2, mk = vops[0], vops[1], vops[2], vops[3]
        else:
            d, s1, s2 = vops[0], vops[0], vops[1]
            mk = None
        a_lo, a_hi = e.vsrc(insn, s1, wide)
        b_lo, b_hi = e.vsrc(insn, s2, wide)
        if mk is not None:
            k_lo, k_hi = e.vsrc(insn, mk, wide)
        else:
            k_lo, k_hi = e.vlo(0), e.vhi(0)
        def bl(a, b, k):
            if m == 'blendvps':
                return f'SI_PS(simde_mm_blendv_ps(PS({a}), PS({b}), PS({k})))'
            if m == 'blendvpd':
                return f'SI_PD(simde_mm_blendv_pd(PD({a}), PD({b}), PD({k})))'
            return f'simde_mm_blendv_epi8({a}, {b}, {k})'
        return ['{', f'simde__m128i rl = {bl(a_lo, b_lo, k_lo)};'] + ([f'simde__m128i rh = {bl(a_hi, b_hi, k_hi)};'] if wide else []) + \
            e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']

    if m in ('pshufd', 'pshufhw', 'pshuflw'):
        fn = {'pshufd': 'shuffle_epi32', 'pshufhw': 'shufflehi_epi16', 'pshuflw': 'shufflelo_epi16'}[m]
        return un_lanes(lambda a, h: f'simde_mm_{fn}({a}, {imm})')
    if m in ('permilps', 'permilpd'):
        if imm is not None:
            if m == 'permilps':
                return un_lanes(lambda a, h: f'SI_PS(simde_mm_permute_ps(PS({a}), {imm}))')
            return un_lanes(lambda a, h: f'SI_PD(simde_mm_permute_pd(PD({a}), {(imm >> (2 * h)) & 3}))')
        if m == 'permilps':
            return bin_lanes(lambda a, b, h: f'SI_PS(simde_mm_permutevar_ps(PS({a}), {b}))')
        return bin_lanes(lambda a, b, h: f'SI_PD(simde_mm_permutevar_pd(PD({a}), {b}))')

    if m in ('movss', 'movsd') and (len(ops) == 2 or not vex):
        d, s = vops[0], vops[1]
        n = 4 if m == 'movss' else 8
        if s.type == X.X86_OP_MEM:
            a = e.addr(insn, s)
            val = f'v_from32(ld32({a}))' if n == 4 else f'v_from64(ld64({a}))'
            return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
        if d.type == X.X86_OP_MEM:
            lo, _ = e.vsrc(insn, s, False)
            return e.vset(insn, d, lo, None, vex, False)
        # legacy reg-reg: merge low element
        dl, _ = e.vsrc(insn, d, False)
        sl, _ = e.vsrc(insn, s, False)
        merge = f'SI_PS(simde_mm_move_ss(PS({dl}), PS({sl})))' if n == 4 else f'SI_PD(simde_mm_move_sd(PD({dl}), PD({sl})))'
        return ['{', f'simde__m128i rl = {merge};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
    if m in ('movss', 'movsd'):
        d, s1, s2 = vops
        n = 4 if m == 'movss' else 8
        merge = 'SI_PS(simde_mm_move_ss(PS({a}), PS({b})))' if n == 4 else 'SI_PD(simde_mm_move_sd(PD({a}), PD({b})))'
        return scalar_bin(merge, n)

    if m in ('movd', 'movq'):
        d, s = vops[0], vops[1]
        n = 4 if m == 'movd' else 8
        if is_v(e, d):
            if is_v(e, s):  # movq xmm, xmm: low 64 bits, upper zeroed
                lo, _ = e.vsrc(insn, s, False)
                return ['{', f'simde__m128i rl = simde_mm_move_epi64({lo});'] + e.vset(insn, d, 'rl', None, True, False) + ['}']
            if s.type == X.X86_OP_MEM:
                a = e.addr(insn, s)
                val = f'v_from32(ld32({a}))' if n == 4 else f'v_from64(ld64({a}))'
            else:
                g = e.gread(s.reg)
                val = f'v_from32((uint32_t){g})' if n == 4 else f'v_from64({g})'
            # movd/movq into xmm always zero the rest of the 128 bits (and VEX the upper half)
            return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
        lo, _ = e.vsrc(insn, s, False)
        if d.type == X.X86_OP_MEM:
            a = e.addr(insn, d)
            return [f'st32({a}, v_lo32({lo}));' if n == 4 else f'st64({a}, v_lo64({lo}));']
        return [e.gwrite(d.reg, f'v_lo32({lo})' if n == 4 else f'v_lo64({lo})')]

    if m in ('movhps', 'movlps', 'movhpd', 'movlpd'):
        high = m[3] == 'h'
        if vops[0].type == X.X86_OP_MEM:
            lo, _ = e.vsrc(insn, vops[1], False)
            a = e.addr(insn, vops[0])
            v = f'(uint64_t)simde_mm_extract_epi64({lo}, 1)' if high else f'v_lo64({lo})'
            return [f'st64({a}, {v});']
        if vex:
            d, s1, s2 = vops
        else:
            d, s1, s2 = vops[0], vops[0], vops[1]
        a_lo, _ = e.vsrc(insn, s1, False)
        mv = f'ld64({e.addr(insn, s2)})'
        if high:
            val = f'simde_mm_set_epi64x((int64_t){mv}, (int64_t)v_lo64({a_lo}))'
        else:
            val = f'simde_mm_set_epi64x(simde_mm_extract_epi64({a_lo}, 1), (int64_t){mv})'
        return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']

    if m == 'movddup':
        d, s = vops
        if s.type == X.X86_OP_MEM and not wide:
            val = f'simde_mm_set1_epi64x((int64_t)ld64({e.addr(insn, s)}))'
            return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
        return un_lanes(lambda a, h: f'SI_PD(simde_mm_movedup_pd(PD({a})))')

    if m in ('movmskps', 'movmskpd', 'pmovmskb'):
        s = vops[1]
        lo, hi = e.vsrc(insn, s, wide)
        fn = {'movmskps': 'simde_mm_movemask_ps(PS({}))', 'movmskpd': 'simde_mm_movemask_pd(PD({}))',
              'pmovmskb': 'simde_mm_movemask_epi8({})'}[m]
        sh = {'movmskps': 4, 'movmskpd': 2, 'pmovmskb': 16}[m]
        val = f'(uint32_t){fn.format(lo)}'
        if wide:
            val = f'({val} | ((uint32_t){fn.format(hi)} << {sh}))'
        return [e.gwrite(vops[0].reg, val)]

    if m in ('pextrb', 'pextrw', 'pextrd', 'pextrq', 'extractps'):
        lo, _ = e.vsrc(insn, vops[1], False)
        fn, n, msk = {'pextrb': ('simde_mm_extract_epi8', 1, 15), 'pextrw': ('simde_mm_extract_epi16', 2, 7),
                      'pextrd': ('simde_mm_extract_epi32', 4, 3), 'pextrq': ('simde_mm_extract_epi64', 8, 1),
                      'extractps': ('simde_mm_extract_epi32', 4, 3)}[m]
        val = f'({U[n]}){fn}({lo}, {imm & msk})'
        d = vops[0]
        if d.type == X.X86_OP_MEM:
            return [f'st{n * 8}({e.addr(insn, d)}, {val});']
        return [e.gwrite(d.reg, f'(uint64_t){val}')]
    if m in ('pinsrb', 'pinsrw', 'pinsrd', 'pinsrq'):
        if vex:
            d, s1, s2 = vops
        else:
            d, s1, s2 = vops[0], vops[0], vops[1]
        a_lo, _ = e.vsrc(insn, s1, False)
        n = {'pinsrb': 1, 'pinsrw': 2, 'pinsrd': 4, 'pinsrq': 8}[m]
        src = e.ld(e.addr(insn, s2), n) if s2.type == X.X86_OP_MEM else e.gread(s2.reg)
        fn, msk = {1: ('simde_mm_insert_epi8', 15), 2: ('simde_mm_insert_epi16', 7), 4: ('simde_mm_insert_epi32', 3),
                   8: ('simde_mm_insert_epi64', 1)}[n]
        cast = 'int64_t' if n == 8 else 'int32_t'
        return ['{', f'simde__m128i rl = {fn}({a_lo}, ({cast})({U[n]}){src}, {imm & msk});'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']

    # conversions
    if m in ('cvtsi2ss', 'cvtsi2sd'):
        if vex:
            d, s1, s2 = vops
        else:
            d, s1, s2 = vops[0], vops[0], vops[1]
        a_lo, _ = e.vsrc(insn, s1, False)
        n = s2.size
        src = e.ld(e.addr(insn, s2), n) if s2.type == X.X86_OP_MEM else e.gread(s2.reg)
        val = f'({"int64_t" if n == 8 else "int32_t"})({src})'
        if m == 'cvtsi2ss':
            res = f'SI_PS(simde_mm_move_ss(PS({a_lo}), simde_mm_set_ss((float){val})))'
        else:
            res = f'SI_PD(simde_mm_move_sd(PD({a_lo}), simde_mm_set_sd((double){val})))'
        return ['{', f'simde__m128i rl = {res};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
    if m in ('cvttss2si', 'cvttsd2si', 'cvtss2si', 'cvtsd2si'):
        d, s = vops
        n = d.size
        f32 = m[-4:-2] == 'ss' or m[-5:-3] == 'ss'
        f32 = 'ss' in m
        if s.type == X.X86_OP_MEM:
            a = e.addr(insn, s)
            fv = f'({{ uint32_t t = ld32({a}); float f; memcpy(&f, &t, 4); f; }})' if f32 else \
                f'({{ uint64_t t = ld64({a}); double f; memcpy(&f, &t, 8); f; }})'
        else:
            lo, _ = e.vsrc(insn, s, False)
            fv = f'vf32({lo})' if f32 else f'vf64({lo})'
        trunc = 'cvtt' if m.startswith('cvtt') else 'cvt'
        fn = f'{trunc}_{"f32" if f32 else "f64"}_{"i64" if n == 8 else "i32"}'
        return [e.gwrite(d.reg, f'({U[n]}){fn}({fv})')]
    if m in ('cvtss2sd', 'cvtsd2ss'):
        if vex:
            d, s1, s2 = vops
        else:
            d, s1, s2 = vops[0], vops[0], vops[1]
        a_lo, _ = e.vsrc(insn, s1, False)
        b_lo, _ = e.vsrc(insn, s2, False, 4 if m == 'cvtss2sd' else 8)
        res = f'SI_PD(simde_mm_cvtss_sd(PD({a_lo}), PS({b_lo})))' if m == 'cvtss2sd' else \
            f'SI_PS(simde_mm_cvtsd_ss(PS({a_lo}), PD({b_lo})))'
        return ['{', f'simde__m128i rl = {res};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
    if m in ('cvtps2pd', 'cvtdq2pd'):
        d, s = vops
        fn = 'simde_mm_cvtps_pd(PS({}))' if m == 'cvtps2pd' else 'simde_mm_cvtepi32_pd({})'
        dwide = is_v(e, d) and e.vidx(d.reg)[1]
        lo, _ = e.vsrc(insn, s, False, 16 if dwide else 8)
        lines = ['{', f'simde__m128i src = {lo};', f'simde__m128i rl = SI_PD({fn.format("src")});']
        if dwide:
            lines.append(f'simde__m128i rh = SI_PD({fn.format("simde_mm_unpackhi_epi64(src, src)")});')
        return lines + e.vset(insn, d, 'rl', 'rh' if dwide else None, vex, dwide) + ['}']
    if m in ('cvtpd2ps', 'cvttpd2dq', 'cvtpd2dq'):
        d, s = vops
        swide = (is_v(e, s) and e.vidx(s.reg)[1]) or (s.type == X.X86_OP_MEM and s.size == 32)
        lo, hi = e.vsrc(insn, s, swide)
        fn = {'cvtpd2ps': 'SI_PS(simde_mm_cvtpd_ps(PD({})))', 'cvttpd2dq': 'simde_mm_cvttpd_epi32(PD({}))',
              'cvtpd2dq': 'simde_mm_cvtpd_epi32(PD({}))'}[m]
        val = fn.format(lo)
        if swide:
            val = f'simde_mm_unpacklo_epi64({fn.format(lo)}, {fn.format(hi)})'
        return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, vex, False) + ['}']
    if m == 'cvtph2ps':
        d, s = vops
        dwide = e.vidx(d.reg)[1]
        lo, _ = e.vsrc(insn, s, False, 16 if dwide else 8)
        lines = ['{', f'simde__m128i src = {lo};', 'simde__m128i rl = SI_PS(simde_mm_cvtph_ps(src));']
        if dwide:
            lines.append('simde__m128i rh = SI_PS(simde_mm_cvtph_ps(simde_mm_unpackhi_epi64(src, src)));')
        return lines + e.vset(insn, d, 'rl', 'rh' if dwide else None, True, dwide) + ['}']
    if m == 'cvtps2ph':
        d, s = vops
        swide = e.vidx(s.reg)[1]
        lo, hi = e.vsrc(insn, s, swide)
        val = f'simde_mm_cvtps_ph(PS({lo}), {imm})'
        if swide:
            val = f'simde_mm_unpacklo_epi64(simde_mm_cvtps_ph(PS({lo}), {imm}), simde_mm_cvtps_ph(PS({hi}), {imm}))'
        if d.type == X.X86_OP_MEM:
            a = e.addr(insn, d)
            return [f'st128({a}, {val});'] if swide else [f'st64({a}, v_lo64({val}));']
        return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, True, False) + ['}']

    if m in ('ucomiss', 'comiss', 'ucomisd', 'comisd'):
        a_lo, _ = e.vsrc(insn, vops[0], False)
        b_lo, _ = e.vsrc(insn, vops[1], False, 4 if m.endswith('ss') else 8)
        f = 'vf32' if m.endswith('ss') else 'vf64'
        t = 'float' if m.endswith('ss') else 'double'
        return [f'{t} fa = {f}({a_lo}), fb = {f}({b_lo}); UCOMI(fa, fb);']
    if m in ('ptest', 'testps', 'testpd'):
        a_lo, a_hi = e.vsrc(insn, vops[0], wide)
        b_lo, b_hi = e.vsrc(insn, vops[1], wide)
        if m == 'ptest':
            z = lambda x, y: f'v_allzero(simde_mm_and_si128({x}, {y}))'
            c_ = lambda x, y: f'v_allzero(simde_mm_andnot_si128({x}, {y}))'
        else:
            msk = 'simde_mm_set1_epi32((int)0x80000000)' if m == 'testps' else 'simde_mm_set1_epi64x((int64_t)0x8000000000000000ULL)'
            z = lambda x, y: f'v_allzero(simde_mm_and_si128(simde_mm_and_si128({x}, {y}), {msk}))'
            c_ = lambda x, y: f'v_allzero(simde_mm_and_si128(simde_mm_andnot_si128({x}, {y}), {msk}))'
        zz = z(a_lo, b_lo) + (f' && {z(a_hi, b_hi)}' if wide else '')
        cc = c_(a_lo, b_lo) + (f' && {c_(a_hi, b_hi)}' if wide else '')
        return [f'zf = {zz}; cf = {cc}; of = 0; sf = 0; af = 0; pf = 0;']

    if m in ('broadcastss', 'broadcastsd', 'broadcastf128'):
        d, s = vops
        a = e.addr(insn, s) if s.type == X.X86_OP_MEM else None
        if a is None:
            raise Unsupported('broadcast reg (AVX2)')
        val = {'broadcastss': f'simde_mm_set1_epi32((int32_t)ld32({a}))',
               'broadcastsd': f'simde_mm_set1_epi64x((int64_t)ld64({a}))',
               'broadcastf128': f'ld128({a})'}[m]
        return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', 'rl' if wide else None, True, wide) + ['}']
    if m == 'insertf128':
        d, s1, s2 = vops
        a_lo, a_hi = e.vsrc(insn, s1, True)
        b_lo, _ = e.vsrc(insn, s2, False, 16)
        lo, hi = (a_lo, 'b') if imm & 1 else ('b', a_hi)
        return ['{', f'simde__m128i b = {b_lo};', f'simde__m128i rl = {lo}, rh = {hi};'] + e.vset(insn, d, 'rl', 'rh', True, True) + ['}']
    if m == 'extractf128':
        d, s = vops
        lo, hi = e.vsrc(insn, s, True)
        val = hi if imm & 1 else lo
        return ['{', f'simde__m128i rl = {val};'] + e.vset(insn, d, 'rl', None, True, False) + ['}']
    if m == 'perm2f128':
        d, s1, s2 = vops
        a_lo, a_hi = e.vsrc(insn, s1, True)
        b_lo, b_hi = e.vsrc(insn, s2, True)
        sel = [a_lo, a_hi, b_lo, b_hi]
        lo = 'VZERO' if imm & 0x08 else sel[imm & 3]
        hi = 'VZERO' if imm & 0x80 else sel[(imm >> 4) & 3]
        return ['{', f'simde__m128i rl = {lo}, rh = {hi};'] + e.vset(insn, d, 'rl', 'rh', True, True) + ['}']
    if m in ('pcmpistri', 'pcmpistrm', 'pcmpestri', 'pcmpestrm'):
        a_lo, _ = e.vsrc(insn, vops[0], False)
        b_lo, _ = e.vsrc(insn, vops[1], False, 16)
        if m[5] == 'e':
            e.gprs.update({0, 2})
            call = f'pcmpstr({a_lo}, {b_lo}, (int)(int32_t)rax, (int)(int32_t)rdx, {imm}, 0)'
        else:
            call = f'pcmpstr({a_lo}, {b_lo}, 0, 0, {imm}, 1)'
        lines = ['{', f'PcmpResult pr = {call};', 'cf = pr.cf; zf = pr.zf; sf = pr.sf; of = pr.of; af = 0; pf = 0;']
        if m.endswith('i'):
            e.gprs.add(1)
            lines.append(f'rcx = pcmp_index(pr, {imm});')
        else:
            lines += [f'{e.vlo(0)} = pcmp_mask(pr, {imm});'] + ([f'{e.vhi(0)} = VZERO;'] if vex else [])
        return lines + ['}']
    if m == 'zeroupper':
        return ['/*ZEROUPPER*/']
    if m == 'zeroall':
        return ['/*ZEROALL*/']
    if m == 'ldmxcsr':
        return [f'recomp_ldmxcsr(c, ld32({e.addr(insn, vops[0])}));']
    if m == 'stmxcsr':
        return [f'st32({e.addr(insn, vops[0])}, c->mxcsr);']
    if m == 'extrq' and imm is None:
        d, s = vops
        lo, _ = e.vsrc(insn, d, False)
        sl, _ = e.vsrc(insn, s, False)
        return ['{', f'uint64_t ctl = v_lo64({sl}); simde__m128i rl = extrq_imm({lo}, ctl & 63, (ctl >> 8) & 63);'] + e.vset(insn, d, 'rl', None, False, False) + ['}']
    if m == 'extrq' and imm is not None:
        ims = [o.imm & 0xff for o in ops if o.type == X.X86_OP_IMM]
        d = vops[0]
        lo, _ = e.vsrc(insn, d, False)
        return ['{', f'simde__m128i rl = extrq_imm({lo}, {ims[0]}, {ims[1]});'] + e.vset(insn, d, 'rl', None, False, False) + ['}']
    raise Unsupported(('v' if vex else '') + m)


def _vex_shift_imm(e, insn, vops, fn, imm, wide, vex):
    d = vops[0]
    s = vops[1] if len(vops) > 1 else vops[0]
    lo, hi = e.vsrc(insn, s, wide)
    out = ['{', f'simde__m128i rl = simde_mm_{fn}({lo}, {imm});']
    if wide:
        out.append(f'simde__m128i rh = simde_mm_{fn}({hi}, {imm});')
    return out + e.vset(insn, d, 'rl', 'rh' if wide else None, vex, wide) + ['}']
