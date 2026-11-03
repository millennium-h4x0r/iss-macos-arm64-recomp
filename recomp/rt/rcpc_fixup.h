/* Emulates an acquire/release access (LDAPR, LDAPUR/LDAPURS, LDAR, STLR, STLUR) that faulted
 * because it straddles a 16-byte block (FEAT_LSE2 allows other misalignment). Returns 1 when
 * the instruction was emulated and the pc advanced. */
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <sys/ucontext.h>
#include <unistd.h>
static int recomp_rcpc_fixup(ucontext_t *uc) {
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    if (((uc->uc_mcontext->__es.__esr >> 26) & ~1u) != 0x24 || (uc->uc_mcontext->__es.__esr & 0x3f) != 0x21)
        return 0; /* not a data abort with an alignment fault */
    const uint32_t insn = *(const uint32_t *)(uintptr_t)ss->__pc;
    const unsigned size = 1u << (insn >> 30), rn = (insn >> 5) & 31, rt = insn & 31;
    int load, sign = 0, dst64 = size == 8;
    int64_t offset = 0;
    if ((insn & 0x3ffffc00) == 0x38bfc000 || (insn & 0x3ffffc00) == 0x08dffc00) {
        load = 1;                                   /* LDAPR, LDAR */
    } else if ((insn & 0x3ffffc00) == 0x089ffc00) {
        load = 0;                                   /* STLR */
    } else if ((insn & 0x3f200c00) == 0x19000000) { /* STLUR, LDAPUR, LDAPURS */
        const unsigned opc = (insn >> 22) & 3;
        offset = (int64_t)((insn >> 12) & 0x1ff) << 55 >> 55;
        load = opc != 0;
        if (opc >= 2) { sign = 1; dst64 = opc == 2; }
    } else {
        return 0;
    }
    const uint64_t base = rn == 31 ? ss->__sp : rn == 29 ? ss->__fp : rn == 30 ? ss->__lr : ss->__x[rn];
    unsigned char *p = (unsigned char *)(uintptr_t)(base + (uint64_t)offset);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    if (load) {
        uint64_t v = 0;
        memcpy(&v, p, size);
        if (sign && size < 8) v = (uint64_t)((int64_t)(v << (64 - 8 * size)) >> (64 - 8 * size));
        if (!dst64) v &= 0xffffffffu;
        if (rt == 29) ss->__fp = v; else if (rt == 30) ss->__lr = v; else if (rt != 31) ss->__x[rt] = v;
    } else {
        const uint64_t v = rt == 31 ? 0 : rt == 29 ? ss->__fp : rt == 30 ? ss->__lr : ss->__x[rt];
        memcpy(p, &v, size);
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    ss->__pc += 4;
    static uint64_t count; /* logged at powers of two: frequent fixups would cost time */
    const uint64_t n = __atomic_add_fetch(&count, 1, __ATOMIC_RELAXED);
    if (!(n & (n - 1))) {
        char line[96];
        const int len = snprintf(line, sizeof line, "Recomp: %llu straddling ordered accesses emulated\n",
                                 (unsigned long long)n);
        if (len > 0) write(2, line, (size_t)len);
    }
    return 1;
}
