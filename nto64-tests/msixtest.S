/* SPDX-License-Identifier: BSD-2-Clause */

/* msixtest.S - UEFI (OVMF) test app for MSI/MSI-X delivery with
 * per-CPU (node) locality.
 *
 * Loaded as \EFI\BOOT\BOOTX64.EFI from the FAT image built by
 * fatimg.py (see the Makefile).  Runs as a flat 64-bit blob, no EFI
 * API usage: raw physical accesses + serial output.
 *
 * Brings up APs 1..3 with per-CPU IDTs (shared stubs at 0x78000,
 * per-CPU IDT at 0x70000 + id*0x2000), then:
 *  MSI (single vector): programs nto64-irqgen's MSI capability to
 *    target APIC 1 with vector 0x50, fires twice, verifies AP1's
 *    handler count reaches 2 and no other CPU saw it.
 *  MSI-X (multi-vector): programs nto64-msix's 4-vector table so
 *    vector i targets APIC i with vector 0x60+i, fires each vector
 *    individually and verifies per-CPU receipt; reprograms vector 3
 *    to a nonexistent APIC (7) and verifies nobody receives it;
 *    restores it and fires all four at once (burst), verifying all
 *    CPUs get theirs.
 *
 * Build: `make msixtest`, run: `make run-msixtest`.
 */
    .code64
    .text
    .globl _start
_start:
    lea stack_top(%rip), %rsp
    and $-16, %rsp
    call main
1:  hlt
    jmp 1b

/* --- check macros ---- */
.macro chk_msix slot, mask, cnt
    movl $\slot, %edx
    movl 8(%edx), %eax
    cmpl $\mask, %eax
    jne 91f
    movl 12(%edx), %eax
    cmpl $\cnt, %eax
    je 92f
91: movl $1, fail(%rip)
92:
.endm

.macro chk_msi slot, cnt
    movl $\slot, %edx
    movl 16(%edx), %eax
    cmpl $\cnt, %eax
    je 93f
    movl $1, fail(%rip)
93:
.endm

.macro chk_id slot, id
    movl $\slot, %edx
    movl 4(%edx), %eax
    cmpl $\id, %eax
    je 94f
    movl $1, fail(%rip)
94:
.endm

.macro wait_msix slot, min
    movl $\slot, %edx
    movl $\min, %eax
    call wait_msix_cnt
.endm

main:
    push %rbp
    mov %rsp, %rbp

    /* --- copy the shared IDT stubs + common handler to 0x78000 ---- */
    lea stubs_start(%rip), %rsi
    lea common_end(%rip), %rcx
    sub %rsi, %rcx
    movl $0x78000, %edi
    rep movsb

    /* --- BSP IDT at 0x70000 (gates use the current CS), LAPIC on ---- */
    xorl %r12d, %r12d
    movl $0x70000, %r13d
    movw %cs, %r14w
    call build_idt
    movw $0xfff, 0x71000
    movq $0x70000, 0x71002
    lidt 0x71000
    movl $0xfee00000, %r10d
    movl $0x1ff, 0xf0(%r10d)  /* SPIV: enable, spurious vector 0xff */
    sti
    movl $1, 0x9100           /* BSP slot: ready, id 0 */
    movl $0, 0x9104

    /* --- PCI scan: nto64-irqgen (1234:1ee7), nto64-msix (1234:1ee8) ---- */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x1ee71234, %eax
    je irqgen_found
    cmpl $0x1ee81234, %eax
    je msix_found
scan_next:
    incl %edi
    cmpl $32, %edi
    jb scan
    jmp scan_done
irqgen_found:
    movl %edi, irqgen_dev(%rip)
    jmp scan_next
msix_found:
    movl %edi, msix_dev(%rip)
    jmp scan_next
scan_done:
    cmpl $0, irqgen_dev(%rip)
    jne 1f
    movl $1, fail(%rip)
1:  cmpl $0, msix_dev(%rip)
    jne 2f
    movl $1, fail(%rip)
2:

    /* --- enable memory space, read BARs ---- */
    movl irqgen_dev(%rip), %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %r8d
    movl irqgen_dev(%rip), %edi
    movl $4, %ecx
    call cfgwrite32
    movl irqgen_dev(%rip), %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, irqgen_bar(%rip)

    movl msix_dev(%rip), %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %r8d
    movl msix_dev(%rip), %edi
    movl $4, %ecx
    call cfgwrite32
    movl msix_dev(%rip), %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, msix_bar0(%rip)
    movl msix_dev(%rip), %edi
    movl $0x14, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, msix_bar1(%rip)

    /* --- AP bring-up: trampoline to 0x8000, GDT to 0x9000,
     * INIT+SIPI for APIC IDs 1..3, wait per-AP ready ---- */
    lea ap_tramp(%rip), %rsi
    lea ap_tramp_end(%rip), %rcx
    sub %rsi, %rcx
    movl $0x8000, %edi
    rep movsb
    lea ap_pm(%rip), %rax
    lea ap_tramp(%rip), %rcx
    sub %rcx, %rax
    add $0x8000, %rax
    movw %ax, 0x8016
    lea ap_ljmpl(%rip), %rdx
    sub %rcx, %rdx
    add $0x8000, %rdx
    lea ap_lm64(%rip), %rax
    sub %rcx, %rax
    add $0x8000, %rax
    movl %eax, 1(%rdx)
    movl $0x9000, %edi
    movl $0x00000000, 0(%edi)
    movl $0x00000000, 4(%edi)
    movl $0x0000ffff, 8(%edi)
    movl $0x00cf9a00, 12(%edi)
    movl $0x0000ffff, 16(%edi)
    movl $0x00cf9200, 20(%edi)
    movl $0x0000ffff, 24(%edi)
    movl $0x00af9a00, 28(%edi)
    movw $0x1f, 0x9020
    movl $0x9000, 0x9022
    mov %cr3, %rax
    movl %eax, 0x9040
    lea ap_main(%rip), %rax
    movl %eax, 0x9050
    movl $1, %r12d            /* APIC ID */
ap_loop:
    movl %r12d, %eax
    shll $16, %eax
    addl $0x100000, %eax
    movl %eax, 0x9060         /* AP stack top */
    movl %r12d, %eax
    shll $24, %eax
    movl $0xfee00310, %edx
    movl %eax, (%edx)         /* ICR2: dest APIC ID */
    movl $0xfee00300, %edx
    movl $0x000c4500, (%edx)  /* INIT */
    movl $2000000, %ecx
1:  decl %ecx
    jnz 1b
    movl %r12d, %eax
    shll $24, %eax
    movl $0xfee00310, %edx
    movl %eax, (%edx)
    movl $0xfee00300, %edx
    movl $0x000c4608, (%edx)  /* SIPI: vector 8 -> 0x8000 */
    movl %r12d, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %r13d          /* AP slot */
    movl $200000000, %ecx
ap_wait:
    cmpl $0, 0(%r13d)
    jne ap_done
    decl %ecx
    jnz ap_wait
ap_done:
    cmpl $0, 0(%r13d)
    jne 1f
    movl $1, fail(%rip)
1:  movl 4(%r13d), %eax
    cmpl %r12d, %eax
    je 2f
    movl $1, fail(%rip)
2:  incl %r12d
    cmpl $4, %r12d
    jb ap_loop

    /* --- MSI (single vector): nto64-irqgen -> APIC 1, vector 0x50 ---- */
    movl irqgen_dev(%rip), %edi
    movl $0x05, %edx
    call findcap
    movl %ecx, %r15d          /* MSI cap offset */
    testl %ecx, %ecx
    jnz 1f
    movl $1, fail(%rip)
1:
    /* message address low = 0xfee01000 (dest APIC 1) */
    movl irqgen_dev(%rip), %edi
    leal 4(%r15d), %ecx
    movl $0xfee01000, %r8d
    call cfgwrite32
    /* address high = 0 */
    movl irqgen_dev(%rip), %edi
    leal 8(%r15d), %ecx
    movl $0, %r8d
    call cfgwrite32
    /* data = 0x50 */
    movl irqgen_dev(%rip), %edi
    leal 12(%r15d), %ecx
    movl $0x50, %r8d
    call cfgwrite32
    /* enable MSI: message control bit0 (16-bit at cap+2) */
    movl irqgen_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgread32
    orl $0x10000, %eax        /* bit0 of the 16-bit ctrl = bit16 of the word */
    movl %eax, %r8d
    movl irqgen_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgwrite32
    /* device: prefer MSI, fire twice */
    movl irqgen_bar(%rip), %esi
    movl $4, 4(%esi)
    movl $1, 0x10(%esi)
    /* two edge-triggered MSIs to the same vector coalesce, so wait for
     * the first delivery before firing the second */
    movl $0x9120, %edx
    movl $1, %eax
    call wait_msi_cnt
    movl $1, 0x10(%esi)
    /* wait AP1 msi count >= 2; nobody else may have seen any */
    movl $0x9120, %edx
    movl $2, %eax
    call wait_msi_cnt
    chk_msi 0x9100, 0
    chk_msi 0x9120, 2
    chk_msi 0x9140, 0
    chk_msi 0x9160, 0

    /* --- MSI-X: program 4-vector table (vector i -> APIC i,
     * vector number 0x60+i), enable ---- */
    movl msix_dev(%rip), %edi
    movl $0x11, %edx
    call findcap
    movl %ecx, %r15d          /* MSI-X cap offset */
    testl %ecx, %ecx
    jnz 1f
    movl $1, fail(%rip)
1:
    /* table = bar1 + (table offset & ~7) */
    movl msix_dev(%rip), %edi
    leal 4(%r15d), %ecx
    call cfgread32
    andl $0xfffffff8, %eax
    addl msix_bar1(%rip), %eax
    movl %eax, %r14d          /* table base */
    xorl %ebx, %ebx
2:
    movl %ebx, %eax
    shll $12, %eax
    addl $0xfee00000, %eax
    movl %ebx, %ecx
    shll $4, %ecx
    addl %r14d, %ecx
    movl %eax, 0(%ecx)        /* addr low: dest = i */
    movl $0, 4(%ecx)          /* addr high */
    movl %ebx, %eax
    addl $0x60, %eax
    movl %eax, 8(%ecx)        /* data: vector 0x60+i */
    movl $0, 12(%ecx)         /* vector control: unmasked */
    incl %ebx
    cmpl $4, %ebx
    jb 2b
    /* enable MSI-X: message control bit15 (16-bit at cap+2) */
    movl msix_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgread32
    orl $0x80000000, %eax     /* bit15 of the 16-bit ctrl = bit31 of the word */
    movl %eax, %r8d
    movl msix_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgwrite32
    /* vector control (cap+0xc): function unmasked */
    movl msix_dev(%rip), %edi
    leal 12(%r15d), %ecx
    movl $0, %r8d
    call cfgwrite32
    /* device enable */
    movl msix_bar0(%rip), %esi
    movl $1, 4(%esi)

    /* --- fire each vector individually ---- */
    xorl %ebx, %ebx
3:
    movl %ebx, 0x0c(%esi)     /* vector select */
    movl $1, 0x10(%esi)       /* trigger */
    incl %ebx
    cmpl $4, %ebx
    jb 3b
    wait_msix 0x9100, 1
    wait_msix 0x9120, 1
    wait_msix 0x9140, 1
    wait_msix 0x9160, 1
    chk_id 0x9100, 0
    chk_id 0x9120, 1
    chk_id 0x9140, 2
    chk_id 0x9160, 3
    chk_msix 0x9100, 1, 1
    chk_msix 0x9120, 2, 1
    chk_msix 0x9140, 4, 1
    chk_msix 0x9160, 8, 1

    /* --- negative: vector 3 -> nonexistent APIC 7, data 0x64 ---- */
    movl $0xfee07000, %eax
    movl %r14d, %ecx
    addl $48, %ecx
    movl %eax, 0(%ecx)
    movl $0x64, %eax
    movl %r14d, %ecx
    addl $56, %ecx
    movl %eax, 8(%ecx)
    movl msix_bar0(%rip), %esi
    movl 0x08(%esi), %eax
    movl %eax, devcnt0(%rip)
    movl 0x24(%esi), %eax     /* pv[3] */
    movl %eax, pv3_0(%rip)
    movl $8, 0x14(%esi)       /* fire mask bit 3 */
    movl 0x08(%esi), %eax
    movl %eax, devcnt1(%rip)
    movl 0x24(%esi), %eax
    movl %eax, pv3_1(%rip)
    /* device-side: exactly one more fire, one more pv[3] */
    movl devcnt1(%rip), %eax
    subl devcnt0(%rip), %eax
    cmpl $1, %eax
    jne 1f
    movl pv3_1(%rip), %eax
    subl pv3_0(%rip), %eax
    cmpl $1, %eax
    je 2f
1:  movl $1, fail(%rip)
2:  /* guest-side: no CPU recorded anything (counts unchanged) */
    chk_msix 0x9100, 1, 1
    chk_msix 0x9120, 2, 1
    chk_msix 0x9140, 4, 1
    chk_msix 0x9160, 8, 1
    movl $1, negdrop(%rip)

    /* --- restore vector 3 (dest 3, 0x63), fire-all burst ---- */
    movl $0xfee03000, %eax
    movl %r14d, %ecx
    addl $48, %ecx
    movl %eax, 0(%ecx)
    movl $0x63, %eax
    movl %r14d, %ecx
    addl $56, %ecx
    movl %eax, 8(%ecx)
    movl msix_bar0(%rip), %esi
    movl $0xf, 0x14(%esi)     /* fire all four at once */
    wait_msix 0x9100, 2
    wait_msix 0x9120, 2
    wait_msix 0x9140, 2
    wait_msix 0x9160, 2
    chk_msix 0x9100, 1, 2
    chk_msix 0x9120, 2, 2
    chk_msix 0x9140, 4, 2
    chk_msix 0x9160, 8, 2
    /* device totals: count 9, per-vector 2/2/2/3 */
    movl 0x08(%esi), %eax
    movl %eax, devcnt_final(%rip)
    movl 0x18(%esi), %eax
    movl %eax, pv0(%rip)
    movl 0x1c(%esi), %eax
    movl %eax, pv1(%rip)
    movl 0x20(%esi), %eax
    movl %eax, pv2(%rip)
    movl 0x24(%esi), %eax
    movl %eax, pv3(%rip)

    /* --- report ---- */
    lea ok(%rip), %rsi
    call puts
    cmpl $0, fail(%rip)
    je 1f
    lea failmsg(%rip), %rsi
    call puts
    jmp 2f
1:  lea okmsg(%rip), %rsi
    call puts
2:
    movl $0x9100, %edx
    movl 16(%edx), %eax
    movl %eax, bsp_msi(%rip)
    movl $0x9120, %edx
    movl 16(%edx), %eax
    movl %eax, ap1_msi(%rip)
    lea sp_msi(%rip), %rsi
    call puts
    movl bsp_msi(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl ap1_msi(%rip), %eax
    call puthex
    lea sp_ids(%rip), %rsi
    call puts
    movl $0x9100, %edx
    movl 4(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9120, %edx
    movl 4(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9140, %edx
    movl 4(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9160, %edx
    movl 4(%edx), %eax
    call puthex
    lea sp_m0(%rip), %rsi
    call puts
    movl $0x9100, %edx
    movl 8(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9100, %edx
    movl 12(%edx), %eax
    call puthex
    lea sp_m1(%rip), %rsi
    call puts
    movl $0x9120, %edx
    movl 8(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9120, %edx
    movl 12(%edx), %eax
    call puthex
    lea sp_m2(%rip), %rsi
    call puts
    movl $0x9140, %edx
    movl 8(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9140, %edx
    movl 12(%edx), %eax
    call puthex
    lea sp_m3(%rip), %rsi
    call puts
    movl $0x9160, %edx
    movl 8(%edx), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl $0x9160, %edx
    movl 12(%edx), %eax
    call puthex
    lea sp_neg(%rip), %rsi
    call puts
    movl negdrop(%rip), %eax
    call puthex
    lea sp_dev(%rip), %rsi
    call puts
    movl devcnt_final(%rip), %eax
    call puthex
    lea sp_pv(%rip), %rsi
    call puts
    movl pv0(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pv1(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pv2(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pv3(%rip), %eax
    call puthex
    lea nl(%rip), %rsi
    call puts

    pop %rbp
    ret

/* --- build a 256-entry IDT at r13d; gates -> shared stubs at
 * 0x78000 + vec*10, selector r14w, type 0x8e (64-bit int gate) ---- */
build_idt:
    push %rbx
    xorl %ebx, %ebx
1:
    movl %ebx, %eax
    imull $10, %eax, %eax
    addl $0x78000, %eax
    movl %ebx, %ecx
    shll $4, %ecx
    movl %r13d, %edx
    addl %ecx, %edx
    movw %ax, 0(%edx)
    movw %r14w, 2(%edx)
    movb $0, 4(%edx)
    movb $0x8e, 5(%edx)
    shrl $16, %eax
    movw %ax, 6(%edx)
    movq $0, 8(%edx)
    incl %ebx
    cmpl $256, %ebx
    jb 1b
    pop %rbx
    ret

/* --- AP trampoline (copied to 0x8000) ---- */
    .code16
ap_tramp:
    cli
    xor %ax, %ax
    mov %ax, %ds
    lgdtl 0x9020
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmpw $0x08, $0x8020
ap_pm:
    .code32
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    movl 0x9040, %eax
    mov %eax, %cr3
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4
    mov $0xc0000080, %ecx     /* EFER */
    rdmsr
    or $0x100, %eax           /* LME */
    wrmsr
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0
ap_ljmpl:
    ljmpl $0x18, $0x8040
ap_lm64:
    .code64
    /* per-AP stack: 0x100000 + lapic_id*0x10000 (never touches the
     * shared slots at 0x9000-0x9060) */
    movabs $0xfee00020, %rax
    movl (%rax), %ebx
    shrl $24, %ebx
    shll $16, %ebx
    addl $0x100000, %ebx
    movq %rbx, %rsp
    movabs 0x9050, %rax
    call *%rax
1:  hlt
    jmp 1b
ap_tramp_end:

/* --- AP main (long mode, BSP's page tables): own IDT, LAPIC on,
 * slot ready, then wait for interrupts ---- */
ap_main:
    push %rbp
    mov %rsp, %rbp
    movl $0xfee00020, %esi
    movl (%esi), %eax
    shrl $24, %eax            /* my LAPIC ID */
    movl %eax, %r12d
    movl %r12d, %eax
    shll $13, %eax
    addl $0x70000, %eax
    movl %eax, %r13d          /* my IDT base */
    movw $0x18, %r14w         /* our GDT code64 selector */
    call build_idt
    movl %r12d, %eax
    shll $8, %eax
    addl $0x71000, %eax
    movl %eax, %esi           /* lidt pointer */
    movw $0xfff, (%esi)
    movl %r13d, %eax
    movq %rax, 2(%esi)
    lidt (%esi)
    movl $0xfee00000, %r10d
    movl $0x1ff, 0xf0(%r10d)  /* SPIV: enable */
    sti
    movl %r12d, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %r13d          /* slot: [0]=ready [4]=id [8]=msix mask
                                 [0xc]=msix cnt [0x10]=msi cnt */
    movl $1, 0(%r13d)
    movl %r12d, 4(%r13d)
1:  hlt
    jmp 1b

/* --- shared IDT stubs (10 bytes each) + common handler ---- */
    .balign 16
stubs_start:
    .set stub_idx, 0
    .rept 256
    .byte 0x68                /* push imm32 (sign-extended) */
    .long stub_idx
    .byte 0xe9                /* jmp rel32 */
    .long common_irq - (. + 4)
    .set stub_idx, stub_idx + 1
    .endr
common_irq:
    push %rdi
    push %rsi
    push %rdx
    push %rcx
    push %rax
    push %r10
    movl $0xfee00000, %r10d
    movl 48(%rsp), %eax       /* vector pushed by the stub */
    cmpl $0x50, %eax
    je 1f
    cmpl $0x60, %eax
    jb 3f
    cmpl $0x63, %eax
    ja 3f
    /* MSI-X vector 0x60..0x63: my slot, mask bit + count */
    movl 0x20(%r10d), %esi
    shrl $24, %esi
    movl %esi, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %edx
    movl 48(%rsp), %eax
    subl $0x60, %eax
    movl %eax, %ecx           /* cl = vector offset */
    movl $1, %eax
    shll %cl, %eax            /* bit = 1 << offset */
    orl %eax, 8(%edx)
    incl 12(%edx)
    jmp 3f
1:  /* MSI vector 0x50: my slot, msi count */
    movl 0x20(%r10d), %esi
    shrl $24, %esi
    movl %esi, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %edx
    incl 16(%edx)
3:
    movl $0, 0xb0(%r10d)      /* LAPIC EOI for every vector */
    /* PIC EOI (master always, slave for 0x28..0x2f) */
    movb $0x20, %al
    outb %al, $0x20
    cmpl $0x28, 48(%rsp)
    jb 2f
    cmpl $0x2f, 48(%rsp)
    ja 2f
    outb %al, $0xa0
2:
    pop %r10
    pop %rax
    pop %rcx
    pop %rdx
    pop %rsi
    pop %rdi
    add $8, %rsp              /* skip the stub-pushed vector */
    iretq
common_end:

/* --- PCI config helpers ---- */
/* cfgread32: edi=dev, ecx=byteoff -> eax (clobbers ebx, ecx, edx) */
cfgread32:
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $11, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    inl %edx, %eax
    ret

/* cfgread8: edi=dev, ecx=byteoff -> eax (clobbers ecx, edx, ebx) */
cfgread8:
    push %rcx
    movl %ecx, %r8d
    call cfgread32
    movl %r8d, %ecx
    andl $3, %ecx
    shll $3, %ecx
    shrl %cl, %eax
    andl $0xff, %eax
    pop %rcx
    ret

/* cfgwrite32: edi=dev, ecx=byteoff, r8d=val (clobbers eax, ebx, edx) */
cfgwrite32:
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $11, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    movl %r8d, %eax
    outl %eax, %edx
    ret

/* findcap: edi=dev, edx=cap id -> ecx=offset or 0 (clobbers eax, ebx,
 * edx, esi, rcx) */
findcap:
    push %rbx
    movl %edx, %r9d           /* want (cfgread8 clobbers ebx) */
    movl $0x34, %ecx
    call cfgread8
1:
    testl %eax, %eax
    jz 3f
    movl %eax, %esi
    movl %eax, %ecx
    call cfgread8
    cmpl %r9d, %eax
    je 2f
    leal 1(%rsi), %ecx
    call cfgread8
    jmp 1b
2:
    movl %esi, %ecx
    jmp 4f
3:
    xorl %ecx, %ecx
4:
    pop %rbx
    ret

/* wait_msix_cnt: edx=slot base, eax=min count (clobbers ecx, r9d) */
wait_msix_cnt:
    movl %eax, %r9d
    movl $200000000, %ecx
1:  cmpl %r9d, 12(%edx)
    jge 2f
    decl %ecx
    jnz 1b
2:  ret

/* wait_msi_cnt: edx=slot base, eax=min count (clobbers ecx, r9d) */
wait_msi_cnt:
    movl %eax, %r9d
    movl $200000000, %ecx
1:  cmpl %r9d, 16(%edx)
    jge 2f
    decl %ecx
    jnz 1b
2:  ret

/* --- serial output ---- */
puts:
    movzbl (%rsi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %rsi
    jmp puts
2:  ret

puthex:
    mov %eax, %ebx
    movl $8, %ecx
1:  roll $4, %ebx
    mov %ebx, %eax
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
    push %rdx
    push %rax
1:  movl $0x3fd, %edx
    inb %dx, %al
    testb $0x20, %al
    jz 1b
    movl $0x3f8, %edx
    pop %rax
    outb %al, %dx
    pop %rdx
    ret

    .balign 16
irqgen_dev: .long 0
msix_dev:   .long 0
irqgen_bar: .long 0
msix_bar0:  .long 0
msix_bar1:  .long 0
fail:       .long 0
negdrop:    .long 0
ap1_msi:    .long 0
bsp_msi:    .long 0
devcnt0:    .long 0
devcnt1:    .long 0
pv3_0:      .long 0
pv3_1:      .long 0
devcnt_final: .long 0
pv0:        .long 0
pv1:        .long 0
pv2:        .long 0
pv3:        .long 0
ok:         .asciz "MSIX EFI "
okmsg:      .asciz "OK"
failmsg:    .asciz "FAIL"
sp_msi:     .asciz " msi="
sp_ids:     .asciz " ids="
sp_m0:      .asciz " m0="
sp_m1:      .asciz " m1="
sp_m2:      .asciz " m2="
sp_m3:      .asciz " m3="
sp_neg:     .asciz " neg="
sp_dev:     .asciz " dev="
sp_pv:      .asciz " pv="
sp_slash:   .asciz "/"
nl:         .asciz "\n"
    .balign 16
    .space 0x4000, 0
stack_top:
