// Calls a native (AAPCS64) function with the guest's System V argument registers.
// Integer arguments go to x0-x7, vector/float arguments to q0-q7 (both ABIs assign the two
// classes independently and in order), further arguments on the stack.
//
// void recomp_hostcall(void *fn, const uint64_t ints[8], const void *vecs /*8 x 16 bytes*/,
//                      const uint64_t *stack, uint64_t nstack, uint64_t out[6]);
// out: x0, x1, q0 (2 words), q1 (2 words)
    .text
    .p2align 2
    .globl _recomp_hostcall
_recomp_hostcall:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x5
    lsl x9, x4, #3
    add x9, x9, #15
    and x9, x9, #~15
    sub sp, sp, x9
    mov x10, #0
1:  cmp x10, x4
    b.ge 2f
    ldr x11, [x3, x10, lsl #3]
    str x11, [sp, x10, lsl #3]
    add x10, x10, #1
    b 1b
2:  ldp q0, q1, [x2]
    ldp q2, q3, [x2, #32]
    ldp q4, q5, [x2, #64]
    ldp q6, q7, [x2, #96]
    mov x9, x1
    ldp x0, x1, [x9]
    ldp x2, x3, [x9, #16]
    ldp x4, x5, [x9, #32]
    ldp x6, x7, [x9, #48]
    blr x19
    stp x0, x1, [x20]
    stp q0, q1, [x20, #16]
    sub sp, x29, #32
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
