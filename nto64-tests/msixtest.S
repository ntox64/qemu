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
 *  DMA (single engine): node-bound bulk + descriptor-ring transfers
 *    with completion MSI-X vector 0 -> CPU0 (vector 0x70).
 *  multi-queue: nto64-dma with queues=4, queue i bound
 *    vCPU i (ring + DMA run through vCPU i's memory view), completion
 *    MSI-X vector i -> CPU i (vector 0x80+i).  Each queue copies
 *    4 x 64 bytes from its own window page (direct) to the next
 *    node's page +0x200 (cross-node via the interconnect, counted),
 *    verifying per-queue ring completion, per-CPU receipt, direct
 *    local reads (rd delta 0) and counted cross-node writes.
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
91: incl fail(%rip)
92:
.endm

.macro chk_msi slot, cnt
    movl $\slot, %edx
    movl 16(%edx), %eax
    cmpl $\cnt, %eax
    je 93f
    incl fail(%rip)
93:
.endm

.macro chk_id slot, id
    movl $\slot, %edx
    movl 4(%edx), %eax
    cmpl $\id, %eax
    je 94f
    incl fail(%rip)
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
    incl fail(%rip)
1:  cmpl $0, msix_dev(%rip)
    jne 2f
    incl fail(%rip)
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
    movl $30000000, %ecx
ap_wait:
    cmpl $0, 0(%r13d)
    jne ap_done
    decl %ecx
    jnz ap_wait
ap_done:
    cmpl $0, 0(%r13d)
    jne 1f
    incl fail(%rip)
1:  movl 4(%r13d), %eax
    cmpl %r12d, %eax
    je 2f
    incl fail(%rip)
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
    incl fail(%rip)
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
    incl fail(%rip)
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
1:  incl fail(%rip)
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

    /* --- DMA: nto64-dma bound to node 0 ----
     * local DMA within node0's window page (direct RAM), then
     * cross-node DMA into node1's page (interconnect in ccNUMA
     * mode); completion MSI-X vector 0 -> CPU0 (vector 0x70). */
    xorl %edi, %edi
dma_scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je dma_next
    cmpl $0x1ee91234, %eax
    je dma_found
dma_next:
    incl %edi
    cmpl $32, %edi
    jb dma_scan
    jmp dma_scan_done
dma_found:
    movl %edi, dma_dev(%rip)
dma_scan_done:
    cmpl $0, dma_dev(%rip)
    jne 1f
    incl fail(%rip)
1:  /* enable memory, read BARs */
    movl dma_dev(%rip), %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %r8d
    movl dma_dev(%rip), %edi
    movl $4, %ecx
    call cfgwrite32
    movl dma_dev(%rip), %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, dma_bar0(%rip)
    movl dma_dev(%rip), %edi
    movl $0x14, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, dma_bar1(%rip)
    /* MSI-X: vector 0 -> dest 0 (CPU0), vector number 0x70 */
    movl dma_dev(%rip), %edi
    movl $0x11, %edx
    call findcap
    movl %ecx, %r15d
    testl %ecx, %ecx
    jnz 1f
    incl fail(%rip)
1:  movl dma_dev(%rip), %edi
    leal 4(%r15d), %ecx
    call cfgread32
    andl $0xfffffff8, %eax
    addl dma_bar1(%rip), %eax
    movl %eax, %r14d          /* table base */
    movl $0xfee00000, 0(%r14d)
    movl $0, 4(%r14d)
    movl $0x70, 8(%r14d)
    movl $0, 12(%r14d)
    movl dma_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgread32
    orl $0x80000000, %eax
    movl %eax, %r8d
    movl dma_dev(%rip), %edi
    leal 2(%r15d), %ecx
    call cfgwrite32
    movl dma_dev(%rip), %edi
    leal 12(%r15d), %ecx
    movl $0, %r8d
    call cfgwrite32
    /* interconnect in ccNUMA (coherent) mode */
    movl $0xdf100000, %ebp
    movl $0x10, 0x0c(%ebp)
    /* fill node0's page source region with a pattern */
    movl $0xdf000000, %edi
    movl $0xa5a5a5a5, %eax
    movl $256, %ecx
2:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 2b
    /* local DMA: 0xdf000000 -> 0xdf000800, 1 KiB (same page) */
    movl dma_bar0(%rip), %esi
    movl 0x10(%ebp), %eax
    movl %eax, rd0(%rip)
    movl 0x14(%ebp), %eax
    movl %eax, wr0(%rip)
    movl $0xdf000000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0xdf000800, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x400, 0x18(%esi)
    movl $3, 0x04(%esi)      /* start + irq on done */
    movl $30000000, %ecx
3:  movl 0x1c(%esi), %eax
    testl $2, %eax
    jnz 4f
    decl %ecx
    jnz 3b
4:  movl $0xdf000800, %edi
    movl (%edi), %eax
    cmpl $0xa5a5a5a5, %eax
    je 5f
    incl fail(%rip)
5:  /* local DMA must not traverse the interconnect */
    movl 0x10(%ebp), %eax
    subl rd0(%rip), %eax
    jz 6f
    incl fail(%rip)
6:  movl 0x14(%ebp), %eax
    subl wr0(%rip), %eax
    jz 7f
    incl fail(%rip)
7:  /* cross-node DMA: 0xdf000000 -> 0xdf001000 (node1's page) */
    movl 0x10(%ebp), %eax
    movl %eax, rd1(%rip)
    movl 0x14(%ebp), %eax
    movl %eax, wr1(%rip)
    movl $0x9100, %edx
    movl 20(%edx), %eax
    movl %eax, dma_before(%rip)
    movl $0xdf001000, 0x10(%esi)
    movl $3, 0x04(%esi)
    movl $30000000, %ecx
8:  movl 0x1c(%esi), %eax
    testl $2, %eax
    jz 9f
    movl $0x9100, %edx
    movl 20(%edx), %eax
    cmpl dma_before(%rip), %eax
    jg 10f
9:  decl %ecx
    jnz 8b
10: /* cross-node copy must be coherent (ccNUMA) and counted */
    movl $0xdf001000, %edi
    movl (%edi), %eax
    cmpl $0xa5a5a5a5, %eax
    je 11f
    incl fail(%rip)
11: movl 0x10(%ebp), %eax
    subl rd1(%rip), %eax
    movl %eax, rd_delta(%rip)
    jnz 12f
    incl fail(%rip)
12: movl 0x14(%ebp), %eax
    subl wr1(%rip), %eax
    movl %eax, wr_delta(%rip)
    jnz 13f
    incl fail(%rip)
13: movl $0x9100, %edx
    movl 20(%edx), %eax
    movl %eax, bsp_dma(%rip)
    /* large GPU-like DMA: 32 MiB between plain-RAM buffers
     * (0x01000000 -> 0x10000000, safe from the app image),
     * fill the whole source with a pattern, verify the copy at
     * 1 MiB intervals */
    movl $0x01000000, %edi
    movl $0xa5a5a5a5, %eax
    movl $0x800000, %ecx
    rep stosl
    movl dma_bar0(%rip), %esi
    movl $0x01000000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x10000000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x02000000, 0x18(%esi)
    movl $3, 0x04(%esi)      /* start + irq on done */
    movl $30000000, %ecx
14: movl 0x1c(%esi), %eax
    testl $2, %eax
    jnz 15f
    decl %ecx
    jnz 14b
15: movl $0x10000000, %edi
    movl $32, %ebx
samp:
    movl (%edi), %eax
    cmpl $0xa5a5a5a5, %eax
    je 1f
    incl fail(%rip)
1:  addl $0x100000, %edi
    decl %ebx
    jnz samp
17: movl $0x9100, %edx
    movl 20(%edx), %eax
    movl %eax, bsp_dma(%rip)
    /* descriptor-ring DMA (NIC/RDMA-like): 64 x 64-byte messages,
     * one completion MSI-X per message.  Pattern at 0x07001000,
     * descriptors at 0x07000000, destinations 0x07002000 + i*64. */
    movl $0x07001000, %edi
    movl $0xc3c3c3c3, %eax
    movl $16, %ecx
fillp:
    movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz fillp
    movl $0x07000000, %edi
    xorl %ebx, %ebx
desc:
    movl $0x07001000, 0(%edi)      /* src */
    movl %ebx, %eax
    shll $6, %eax
    addl $0x07002000, %eax
    movl %eax, 4(%edi)             /* dst = 0x07002000 + i*64 */
    movl $64, 8(%edi)              /* len */
    movl $1, 12(%edi)              /* valid */
    addl $16, %edi
    incl %ebx
    cmpl $64, %ebx
    jb desc
    movl dma_bar0(%rip), %esi
    movl $0x07000000, 0x28(%esi)
    movl $0, 0x2c(%esi)
    movl $64, 0x30(%esi)
    movl $16, 0x34(%esi)
    movl $7, 0x04(%esi)            /* start + irq + ring mode */
    movl $30000000, %ecx
ring_wait:
    movl 0x1c(%esi), %eax
    testl $2, %eax
    jnz ring_done
    decl %ecx
    jnz ring_wait
ring_done:
    movl 0x38(%esi), %eax
    movl %eax, ring_done_cnt(%rip)
    cmpl $64, %eax
    je 18f
    incl fail(%rip)
18: movl $0x07002000, %edi
    movl $64, %ebx
rchk:
    movl (%edi), %eax
    cmpl $0xc3c3c3c3, %eax
    je 1f
    incl fail(%rip)
1:  addl $64, %edi
    decl %ebx
    jnz rchk
20: movl $0x9100, %edx
    movl 20(%edx), %eax
    movl %eax, bsp_dma(%rip)

    /* ---: per-queue DMA + per-vector MSI-X locality ----
     * Program the DMA MSI-X table so vector i -> APIC i with vector
     * number 0x80+i (completion for queue i lands on CPU i).  Queue i
     * is bound to vCPU i.  Each queue copies 4 x 64 bytes from its
     * own window page (direct in its view) to the next node's page
     * +0x200 (cross-node via the interconnect, counted), one
     * completion MSI-X per message. */
    movl %r14d, dma_tab(%rip)
    movl $0xdf100000, %ebp
    xorl %ebx, %ebx
pq_tab:
    movl %ebx, %eax
    shll $12, %eax
    addl $0xfee00000, %eax
    movl %ebx, %ecx
    shll $4, %ecx
    addl dma_tab(%rip), %ecx
    movl %eax, 0(%ecx)        /* addr low: dest = i */
    movl $0, 4(%ecx)          /* addr high */
    movl %ebx, %eax
    addl $0x80, %eax
    movl %eax, 8(%ecx)        /* data: vector 0x80+i */
    movl $0, 12(%ecx)         /* unmasked */
    incl %ebx
    cmpl $4, %ebx
    jb pq_tab

    movl dma_bar0(%rip), %esi
    xorl %r15d, %r15d         /* queue index */
pq_loop:
    /* pattern p_i = 0x11111111 * (i+1), 64 bytes at own window page */
    movl %r15d, %eax
    incl %eax
    imull $0x11111111, %eax, %eax
    movl %eax, pq_pat(%rip)
    movl %r15d, %eax
    shll $12, %eax
    addl $0xdf000000, %eax
    movl %eax, %r13d          /* own page */
    movl pq_pat(%rip), %eax
    movl %r13d, %edi
    movl $16, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    /* ring of 4 descriptors at 0x07008000 + i*0x40 */
    movl %r15d, %eax
    shll $6, %eax
    addl $0x07008000, %eax
    movl %eax, %r12d          /* ring base */
    movl %r12d, %edi
    xorl %ebx, %ebx
pq_desc:
    movl %r13d, %eax
    movl %ebx, %ecx
    shll $6, %ecx
    addl %ecx, %eax
    movl %eax, 0(%edi)        /* src = own + k*64 */
    movl %r15d, %eax
    addl $1, %eax
    andl $3, %eax
    shll $12, %eax
    addl $0xdf000000, %eax    /* next page base */
    addl $0x200, %eax         /* + 0x200 */
    movl %ebx, %ecx
    shll $6, %ecx
    addl %ecx, %eax
    movl %eax, 4(%edi)        /* dst = next page + 0x200 + k*64 */
    movl $64, 8(%edi)
    movl $1, 12(%edi)
    addl $16, %edi
    incl %ebx
    cmpl $4, %ebx
    jb pq_desc
    /* snapshot the interconnect counters, program + start queue i */
    movl 0x10(%ebp), %eax
    movl %eax, pq_rd(%rip)
    movl 0x14(%ebp), %eax
    movl %eax, pq_wr(%rip)
    movl %r15d, 0x40(%esi)    /* queue select */
    movl %r12d, 0x44(%esi)
    movl $0, 0x48(%esi)
    movl $4, 0x4c(%esi)
    movl $16, 0x50(%esi)
    movl $1, 0x54(%esi)       /* start queue i */
    movl $30000000, %ecx
pq_wait:
    movl 0x58(%esi), %eax
    cmpl $4, %eax
    je pq_done
    decl %ecx
    jnz pq_wait
pq_done:
    cmpl $4, 0x58(%esi)
    je 1f
    incl fail(%rip)
1:  /* completion MSI-X must land on CPU i.  Edge MSI-X to the same
     * vector coalesce (the device fires 4 back-to-back), so assert
     * delivery (>= 1) here - the ring_done check above already proved
     * all four messages completed. */
    movl %r15d, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %edx
    movl $1, %eax
    call wait_pq_cnt
    /* direct local reads: rd delta 0 (own-page src is direct);
     * counted cross-node writes: wr delta 0x40 (4 x 64 bytes =
     * dword writes through the interconnect) */
    movl 0x10(%ebp), %eax
    subl pq_rd(%rip), %eax
    movl %eax, pq_rd_delta(%rip)
    jz 2f
    incl fail(%rip)
2:  movl 0x14(%ebp), %eax
    subl pq_wr(%rip), %eax
    movl %eax, pq_wr_delta(%rip)
    cmpl $0x40, %eax
    je 3f
    incl fail(%rip)
3:  /* coherent cross-node data at the next node's page + 0x200 */
    movl %r15d, %eax
    addl $1, %eax
    andl $3, %eax
    shll $12, %eax
    addl $0xdf000000, %eax
    addl $0x200, %eax
    movl (%eax), %edx
    cmpl pq_pat(%rip), %edx
    je 4f
    incl fail(%rip)
4:  /* save CPU i's per-queue count */
    movl %r15d, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl 28(%eax), %ecx
    movl %r15d, %eax
    shll $2, %eax
    lea pq_cnt(%rip), %rdi
    add %rax, %rdi
    movl %ecx, (%rdi)
    incl %r15d
    cmpl $4, %r15d
    jb pq_loop
    /* each CPU i saw its own per-queue vector (mask 1<<i, >= 1
     * delivery; the rest coalesce) */
    xorl %ebx, %ebx
pq_chk:
    movl $1, %r9d
    movl %ebx, %ecx
    shll %cl, %r9d            /* expected mask bit */
    movl %ebx, %eax
    shll $5, %eax
    addl $0x9100, %eax
    cmpl %r9d, 24(%eax)
    jne pq_bad
    cmpl $1, 28(%eax)
    jge pq_next
pq_bad:
    incl fail(%rip)
pq_next:
    incl %ebx
    cmpl $4, %ebx
    jb pq_chk

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
    lea sp_f(%rip), %rsi
    call puts
    movl fail(%rip), %eax
    call puthex
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
    lea sp_dma(%rip), %rsi
    call puts
    movl bsp_dma(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl rd_delta(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl wr_delta(%rip), %eax
    call puthex
    lea sp_ring(%rip), %rsi
    call puts
    movl ring_done_cnt(%rip), %eax
    call puthex
    lea sp_pq(%rip), %rsi
    call puts
    movl pq_cnt(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pq_cnt+4(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pq_cnt+8(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl pq_cnt+12(%rip), %eax
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
    cmpl $0x70, %eax
    je 4f
    cmpl $0x80, %eax
    jb 6f
    cmpl $0x83, %eax
    ja 6f
    /* per-queue DMA completion MSI-X vector 0x80..0x83: my slot,
     * per-queue mask bit (vector - 0x80) + count */
    movl 0x20(%r10d), %esi
    shrl $24, %esi
    movl %esi, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %edx
    movl 48(%rsp), %eax
    subl $0x80, %eax
    movl %eax, %ecx           /* cl = vector offset */
    movl $1, %eax
    shll %cl, %eax            /* bit = 1 << offset */
    orl %eax, 24(%edx)
    incl 28(%edx)
    jmp 3f
6:
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
    jmp 3f
4:  /* DMA-completion MSI-X vector 0x70: my slot, dma count */
    movl 0x20(%r10d), %esi
    shrl $24, %esi
    movl %esi, %eax
    shll $5, %eax
    addl $0x9100, %eax
    movl %eax, %edx
    incl 20(%edx)
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
    movl $30000000, %ecx
1:  cmpl %r9d, 12(%edx)
    jge 2f
    decl %ecx
    jnz 1b
2:  ret

/* wait_msi_cnt: edx=slot base, eax=min count (clobbers ecx, r9d) */
wait_msi_cnt:
    movl %eax, %r9d
    movl $30000000, %ecx
1:  cmpl %r9d, 16(%edx)
    jge 2f
    decl %ecx
    jnz 1b
2:  ret

/* wait_pq_cnt: edx=slot base, eax=min count (clobbers ecx, r9d) */
wait_pq_cnt:
    movl %eax, %r9d
    movl $30000000, %ecx
1:  cmpl %r9d, 28(%edx)
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
dma_dev:    .long 0
dma_bar0:   .long 0
dma_bar1:   .long 0
rd0:        .long 0
wr0:        .long 0
rd1:        .long 0
wr1:        .long 0
dma_before: .long 0
bsp_dma:    .long 0
rd_delta:   .long 0
wr_delta:   .long 0
ring_done_cnt: .long 0
dma_tab:    .long 0
pq_pat:     .long 0
pq_rd:      .long 0
pq_wr:      .long 0
pq_rd_delta: .long 0
pq_wr_delta: .long 0
pq_cnt:     .long 0, 0, 0, 0
ok:         .asciz "MSIX EFI "
okmsg:      .asciz "OK"
failmsg:    .asciz "FAIL"
sp_msi:     .asciz " msi="
sp_f:       .asciz " f="
sp_ids:     .asciz " ids="
sp_m0:      .asciz " m0="
sp_m1:      .asciz " m1="
sp_m2:      .asciz " m2="
sp_m3:      .asciz " m3="
sp_neg:     .asciz " neg="
sp_dev:     .asciz " dev="
sp_pv:      .asciz " pv="
sp_dma:     .asciz " dma="
sp_ring:    .asciz " ring="
sp_pq:      .asciz " pq="
sp_slash:   .asciz "/"
nl:         .asciz "\n"
    .balign 16
    .space 0x4000, 0
stack_top:
