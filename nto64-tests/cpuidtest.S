/* SPDX-License-Identifier: BSD-2-Clause */

/* cpuidtest.S - freestanding multiboot test for the testbed's per-CPU
 * CPUID override (main project / AMP: "vary
 * env->features per cpu_index").
 *
 * BSP + AP1 each read CPUID leaf 0x1A (core type), leaf 7/0 EBX bit 5
 * (AVX2) and EDX bit 15 (hybrid flag) and the max leaf; the results
 * must differ per the machine properties:
 *   -machine pc,nto64-per-cpu-cpuid="0:avx2,avx;1:sse4.2",\
 *          nto64-per-cpu-core-type="0:0x40;1:0x20" -smp 2
 * Expected: cpu0 core type 0x40 (P-core) with AVX2, cpu1 core type
 * 0x20 (E-core, or 0x40 for the same-class build) without AVX2; both
 * report the hybrid flag and a max leaf that reaches leaf 0x1A.  The
 * values are asserted, not printed for the reader: core type, AVX2,
 * hybrid flag, max leaf, the two TSC spans and the AVX2 #UD.  The TSC
 * scale is checked by sampling rdtsc on both vCPUs over the SAME
 * wall-clock window (a shared-memory handshake): the per-CPU factor
 * multiplies a common clock, so the spans must come out as the
 * configured ratio (2 here) with a wide tolerance for scheduling
 * jitter - a fixed-iteration loop would instead measure the 0x20
 * core's per-TB pause, which is ~25x the wall time and says nothing
 * about the scale.
 * Prints 'CPUID c0t=... c0a=... c0h=... c0m=... c1t=... c1a=...
 * c1h=... c1m=... c0tsc=... c1tsc=... ud=... f=...' and halts.
 * Build: `make cpuidtest` (hybrid), `make cpuidtest-same` (both cores
 * 0x40, differing AVX2 - the TB-key collision case); run:
 * `make run-cpuidtest`, `make run-cpuidtestsame`.
 */

/* AP core type the machine is configured for.  The hybrid run puts an
 * 0x20 E-core in APIC 1; the same-class run gives APIC 1 the BSP's own
 * 0x40 class with a different feature set, which must still be a
 * different translation unit (its AVX2 #UD is asserted below). */
#ifdef NTO64_SAME_CLASS
#define EXPECT_AP_CORE 0x40
#else
#define EXPECT_AP_CORE 0x20
#endif

/* Host cycles the shared TSC window stays open (this tree's TSC counts
 * host cycles); ~30-40 ms, long enough that a delayed vCPU thread still
 * lands inside the band the ratio check allows. */
#define TSC_SPAN 100000000
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

#define TRAMP   0x8000
#define AP_GDT  0x8040
#define AP_GDTD 0x8060
#define AP_SLOT 0x9100          /* core_type, avx2, hybrid, maxleaf,
                                 * tsc delta/start/end */
#define AP_READY 0x9130
#define IDT_BASE 0x8800
#define IDT_DESC 0x9800
#define LAPIC   0xfee00000

    .section .text
    .globl _start
_start:
    movl $stack_top, %esp
    andl $-16, %esp
    call enable_os_avx
    call build_idt
    lidt IDT_DESC

    /* BSP CPUID */
    movl $0, %eax
    cpuid
    movl %eax, bsp_max
    movl $7, %eax
    xorl %ecx, %ecx
    cpuid
    movl %ebx, bsp_f7
    movl %edx, bsp_f7d
    movl $0x1a, %eax
    xorl %ecx, %ecx
    cpuid
    shrl $24, %eax
    movl %eax, bsp_core

    /* execute the AVX2 instruction on the BSP first (so its TB exists) */
    movl $0, who
    call avx2_fn

    call ap_bringup
    /* TSC window: only once the AP is actually up (ap_bringup counted
     * the timeout itself; without the AP the ack would never come). */
    cmpl $0, AP_READY
    je 1f
    call tsc_window
1:

    /* report */
    movl $msg, %esi
    call puts
    movl $sp_c0t, %esi
    call puts
    movl bsp_core, %eax
    call puthex
    movl $sp_c0a, %esi
    call puts
    movl bsp_f7, %eax
    andl $32, %eax
    call puthex
    movl $sp_c0h, %esi
    call puts
    movl bsp_f7d, %eax
    andl $0x8000, %eax
    call puthex
    movl $sp_c0m, %esi
    call puts
    movl bsp_max, %eax
    call puthex
    movl $sp_c1t, %esi
    call puts
    movl AP_SLOT, %eax
    call puthex
    movl $sp_c1a, %esi
    call puts
    movl AP_SLOT+4, %eax
    andl $32, %eax
    call puthex
    movl $sp_c1h, %esi
    call puts
    movl AP_SLOT+8, %eax
    andl $0x8000, %eax
    call puthex
    movl $sp_c1m, %esi
    call puts
    movl AP_SLOT+12, %eax
    call puthex
    movl $sp_c0tsc, %esi
    call puts
    movl bsp_tsc_span, %eax
    call puthex
    movl $sp_c1tsc, %esi
    call puts
    movl AP_SLOT+16, %eax
    call puthex
    movl $sp_ud, %esi
    call puts
    movl ap_ud, %eax
    call puthex
    movl $sp_bud, %esi
    call puts
    movl bsp_ud, %eax
    call puthex
    movl $sp_be, %esi
    call puts
    movl bad_exc, %eax
    call puthex

    /* assert the per-CPU CPUID override: P-core class (0x40) on the
     * BSP with AVX2, the configured class on the AP without AVX2, the
     * hybrid flag on both, and a max leaf that actually reaches 0x1A
     * (the leaf the core type lives in) on both vCPUs. */
    cmpl $0, AP_READY
    jne 1f
    incl fail
    jmp 3f
1:  cmpl $0x40, bsp_core
    jne 3f
    cmpl $EXPECT_AP_CORE, AP_SLOT
    jne 3f
    testl $32, bsp_f7
    jz 3f
    testl $32, AP_SLOT+4
    jnz 3f
    movl bsp_f7d, %eax
    andl $0x8000, %eax
    cmpl $0x8000, %eax
    jne 3f
    movl AP_SLOT+8, %eax
    andl $0x8000, %eax
    cmpl $0x8000, %eax
    jne 3f
    cmpl $0x1a, bsp_max
    jb 3f
    movl AP_SLOT+12, %eax
    cmpl bsp_max, %eax
    je 4f
3:  incl fail

    /* assert the TSC scaling: both spans cover the same window, so the
     * AP's must be the configured 2x the BSP's, within the wide band
     * the handshake tolerates ([1.5, 2.5] of a vCPU thread that is
     * late to a flag).  Zero spans mean the window never ran. */
4:  cmpl $0, AP_READY
    je 8f
    cmpl $0, bsp_tsc_span
    je 7f
    movl AP_SLOT+16, %eax
    cmpl $0, %eax
    je 7f
    addl %eax, %eax             /* 2 x AP span */
    movl bsp_tsc_span, %ecx
    imull $3, %ecx, %ecx        /* 3 x BSP span */
    cmpl %ecx, %eax
    jl 7f                       /* AP too slow: ratio < 1.5 */
    movl bsp_tsc_span, %ecx
    imull $5, %ecx, %ecx        /* 5 x BSP span */
    cmpl %ecx, %eax
    jg 7f                       /* AP too fast: ratio > 2.5 */
    jmp 8f
7:  incl fail

    /* assert: BSP executed AVX2 cleanly, AP hit exactly one #UD at the
     * vpaddd (avx2_fn), and no other exception was miscounted. */
8:
    cmpl $1, ap_ud
    jne 9f
    cmpl $0, bsp_ud
    jne 9f
    cmpl $0, bad_exc
    jne 9f
    cmpl $avx2_fn, ud_rip
    je 10f
9:  incl fail
10:
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
1:  hlt
    jmp 1b

/* ap_bringup: copy the trampoline to 0x8000, build the GDT, INIT +
 * SIPI to APIC 1, wait for AP_READY. */
ap_bringup:
    movl $ap_tramp, %esi
    movl $TRAMP, %edi
    movl $ap_tramp_end, %ecx
    subl $ap_tramp, %ecx
1:  movb (%esi), %al
    movb %al, (%edi)
    incl %esi
    incl %edi
    decl %ecx
    jnz 1b

    movl $0, AP_GDT
    movl $0, AP_GDT+4
    movl $0x0000ffff, AP_GDT+8
    movl $0x00cf9a00, AP_GDT+12
    movl $0x0000ffff, AP_GDT+16
    movl $0x00cf9200, AP_GDT+20
    movw $23, AP_GDTD
    movl $AP_GDT, AP_GDTD+2
    movl $0, AP_GDTD+6

    movl $LAPIC, %eax
    movl $1 << 24, 0x310(%eax)
    movl $0x00004500, 0x300(%eax)
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax)
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax)

    movl $1000000000, %ecx
1:  movl AP_READY, %eax
    testl %eax, %eax
    jnz 2f
    decl %ecx
    jnz 1b
    movl $msg_ap, %esi
    call puts
    incl fail
2:  ret

ap_delay:
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    ret

/* tsc_window: BSP side of the shared-clock TSC window.  Opens the
 * window (tsc_go), waits for the AP's sample (tsc_ack), spins until its
 * own clock advanced TSC_SPAN host cycles, then closes the window
 * (tsc_stop) with bsp_tsc_span = its own delta, and then waits for the
 * AP to publish its own delta (tsc_apdone) before returning: the AP
 * samples rdtsc only after it sees tsc_stop, so a reader that returns
 * as soon as the flag is set can still find AP_SLOT+16 at zero and
 * blame the missing span on the scaling.  The wait is bounded so a
 * stuck AP reports instead of hanging the run.  Both vCPUs' deltas
 * therefore cover the same wall-clock span, which is what makes the
 * per-CPU scale observable: the scale multiplies a clock shared by
 * every vCPU.  Clobbers eax/ecx/edx/esi. */
tsc_window:
    movl $0, tsc_ack
    movl $0, tsc_stop
    movl $0, tsc_apdone
    rdtsc
    movl %eax, tsc_ref
    movl $1, tsc_go
1:  cmpl $0, tsc_ack
    je 1b
2:  rdtsc
    subl tsc_ref, %eax
    cmpl $TSC_SPAN, %eax
    jb 2b
    movl %eax, bsp_tsc_span
    movl $1, tsc_stop
    movl $100000000, %ecx
3:  cmpl $0, tsc_apdone
    jne 4f
    decl %ecx
    jnz 3b
    movl $msg_tscto, %esi
    call puts
    incl fail
4:
    ret

/* AP trampoline: 16-bit real mode -> protected mode 32, then read
 * CPUID into the result slot and halt. */
    .code16
ap_tramp:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7f00, %sp
    lgdtl AP_GDTD
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long ap_entry32
    .word 0x08
ap_tramp_end:
    .code32

ap_entry32:
    movl $0x10, %eax
    movl %eax, %ds
    movl %eax, %es
    movl %eax, %ss
    call enable_os_avx
    lidt IDT_DESC
    movl $7, %eax
    xorl %ecx, %ecx
    cpuid
    movl %ebx, AP_SLOT+4
    movl %edx, AP_SLOT+8
    movl $0x1a, %eax
    xorl %ecx, %ecx
    cpuid
    shrl $24, %eax
    movl %eax, AP_SLOT
    /* same AVX2 instruction as the BSP - must #UD on a non-AVX2 core */
    movl $1, who
    call avx2_fn
    movl $0, %eax
    cpuid
    movl %eax, AP_SLOT+12
    movl $1, AP_READY
    /*
     * TSC window responder: sample rdtsc between the BSP's start and
     * stop flags so both vCPUs' deltas cover the same wall-clock span,
     * then report the span (see the tsc_window comment on the BSP
     * side).  Clear the handshake first: the BSP opens the window only
     * after AP_READY.
     */
    movl $0, tsc_ack
    movl $0, tsc_stop
    movl $0, tsc_apdone
8:  cmpl $0, tsc_go
    je 8b
    rdtsc
    movl %eax, %esi
    movl $1, tsc_ack
9:  cmpl $0, tsc_stop
    je 9b
    rdtsc
    subl %esi, %eax
    movl %eax, AP_SLOT+16
    movl $1, tsc_apdone
1:  hlt
    jmp 1b

/* avx2_fn: one AVX2 instruction (vpaddd ymm0,ymm0,ymm0 = c5 fd fe c0).
 * On a vCPU without AVX2 the translator must raise #UD (EXCP06). */
avx2_fn:
    .byte 0xc5, 0xfd, 0xfe, 0xc0
avx2_after:
    ret

/* build_idt: 256 IDT entries at IDT_BASE; vector 6 (#UD) -> ud_handler,
 * every other vector -> bad_handler, with the 6-byte pseudo-descriptor
 * at IDT_DESC.  Only the #UD path may count as the expected trap. */
build_idt:
    movl $IDT_BASE, %edi
    xorl %ebx, %ebx             /* vector index */
    movl $256, %ecx
1:  movl $bad_handler, %eax
    cmpl $6, %ebx
    jne 2f
    movl $ud_handler, %eax
2:  movw %ax, 0(%edi)
    movw $0x08, 2(%edi)
    movl $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %eax
    movw %ax, 6(%edi)
    addl $8, %edi
    incl %ebx
    decl %ecx
    jnz 1b
    movw $0x7ff, IDT_DESC
    movl $IDT_BASE, IDT_DESC+2
    movl $0, IDT_DESC+6
    ret

/* ud_handler (vector 6): record WHO trapped (BSP vs AP), validate the
 * faulting address is exactly the vpaddd (avx2_fn), and resume at the
 * explicit post-AVX2 label (avx2_after) so the handler never hardcodes
 * the instruction length (vpaddd is 4 bytes). */
ud_handler:
    movl 0(%esp), %eax          /* saved EIP = faulting instruction */
    movl %eax, ud_rip
    cmpl $avx2_fn, %eax
    je 1f
    movl $1, bad_exc            /* a #UD outside the vpaddd is unexpected */
    jmp 3f
1:  cmpl $0, who
    jne 2f
    movl $1, bsp_ud
    jmp 3f
2:  movl $1, ap_ud
3:  movl $avx2_after, 0(%esp)
    iret

/* bad_handler (every vector except 6): an exception other than the
 * expected #UD fired; record it and resume past the AVX2 test so the
 * report still runs. */
bad_handler:
    movl $1, bad_exc
    movl $avx2_after, 0(%esp)
    iret

/* enable_os_avx: CR4.OSXSAVE + XCR0 = x87|SSE|AVX, so VEX decoding
 * depends only on the CPUID feature, not on missing OS state. */
enable_os_avx:
    /* skip if the model has no XSAVE (leaf 1 ECX bit 26): xsetbv would
     * #GP and the harness has no IDT to survive it */
    movl $1, %eax
    cpuid
    testl $(1 << 26), %ecx
    jz 2f
    movl %cr4, %eax
    orl $(1 << 18), %eax
    movl %eax, %cr4
    movl $0, %ecx
    movl $7, %eax
    movl $0, %edx
    xsetbv
2:  ret

/* puts / puthex / putc - same console helpers as the other tests */
puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    incl %esi
    jmp puts
2:  ret

puthex:
    movl %eax, %ebx
    movl $8, %ecx
1:  roll $4, %ebx
    movl %ebx, %eax
    andl $0xf, %eax
    cmpl $10, %eax
    jl 3f
    addl $('a'-10), %eax
    jmp 4f
3:  addl $'0', %eax
4:  call putc
    decl %ecx
    jnz 1b
    ret

putc:
    pushl %edx
    pushl %eax
1:  movl $0x3fd, %edx
    inb %dx, %al
    testb $0x20, %al
    jz 1b
    movl $0x3f8, %edx
    popl %eax
    outb %al, %edx
    popl %edx
    ret

    .bss
    .balign 16
bsp_core: .long 0
bsp_f7:   .long 0
bsp_f7d:  .long 0
bsp_max:  .long 0
bsp_tsc_span: .long 0
tsc_ref:  .long 0
tsc_go:   .long 0
tsc_ack:  .long 0
tsc_stop: .long 0
tsc_apdone: .long 0
fail:     .long 0
who:      .long 0
bsp_ud:   .long 0
ap_ud:    .long 0
bad_exc:  .long 0
ud_rip:   .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:      .asciz "CPUID"
msg_ap:   .asciz " AP-TIMEOUT"
msg_tscto: .asciz " TSC-TIMEOUT"
sp_c0t:   .asciz " c0t="
sp_c0a:   .asciz " c0a="
sp_c0h:   .asciz " c0h="
sp_c0m:   .asciz " c0m="
sp_c1t:   .asciz " c1t="
sp_c1a:   .asciz " c1a="
sp_c1h:   .asciz " c1h="
sp_c1m:   .asciz " c1m="
sp_c0tsc: .asciz " c0tsc="
sp_c1tsc: .asciz " c1tsc="
sp_ud:    .asciz " ud="
sp_bud:   .asciz " bud="
sp_be:    .asciz " be="
sp_f:     .asciz " f="
nl:       .asciz "\n"
