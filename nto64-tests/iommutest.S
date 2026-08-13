/* SPDX-License-Identifier: BSD-2-Clause */

/* iommutest.S - freestanding multiboot test for the per-CPU-AS x IOMMU
 * interplay.
 *
 * Machine: q35 + intel-iommu + nto64-per-cpu-ram + nto64-dma,iommu=on.
 * The device's DMA AS is rooted at the PCI/IOMMU address space
 * (iommu=on), so DMA IOVAs are translated by the guest-programmed VT-d
 * page tables instead of resolving through the vCPU (node) view.
 *
 * Steps:
 *   DMAR disabled: passthrough DMA (identity) works;
 *   program VT-d: root table -> context table (device bus/dev/fn,
 *     aw=1 / 3-level, multi-level TT) -> L3 -> L2 with 2 MiB pages
 *     mapping IOVA 0x10000000 -> phys 0x01000000 and
 *     IOVA 0x11000000 -> phys 0x01100000; RTADDR + GCMD.SRTP/TE;
 *   DMA via IOVAs succeeds and the data lands in the mapped phys
 *     buffers (translation works);
 *   DMA to an unmapped IOVA (0x12000000) faults: the device reports
 *     status error.
 * Prints to COM1, halts.  Build: `make iommutest`,
 * run: `make run-iommutest`.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

    .section .text
    .globl _start
_start:
    /* find nto64-dma (1234:1ee9) */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x1ee91234, %eax
    je found
scan_next:
    incl %edi
    cmpl $32, %edi
    jb scan
    incl fail
    jmp report
found:
    movl %edi, dev
    /* enable memory + bus master, read BAR0 */
    movl $4, %ecx
    call cfgread32
    orl $6, %eax
    movl %eax, %ebp
    movl dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, bar0

    /* fill phys 0x01000000 (4 KiB) with the pattern */
    movl $0x01000000, %edi
    movl $0xaa55aa55, %eax
    movl $1024, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b

    /* --- passthrough baseline (DMAR disabled): identity DMA ---- */
    movl bar0, %esi
    movl $0x01000000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x01100000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x1000, 0x18(%esi)
    movl $1, 0x04(%esi)
    call wait_done
    testl $4, 0x1c(%esi)
    jz 1f
    incl fail
1:  movl $0x01100000, %edi
    cmpl $0xaa55aa55, (%edi)
    je 2f
    incl fail
2:  movl bar0, %esi
    movl 0x1c(%esi), %eax
    movl %eax, pt_status
    movl $0x01100000, %edi
    movl (%edi), %eax
    movl %eax, pt_data

    /* --- program VT-d ---- */
    /* root @ 0x02000000 -> ctx @ 0x02001000 -> L3 @ 0x02002000 ->
     * L2 @ 0x02003000 (2 MiB pages, aw=1 / 3-level) */
    movl $0x02000000, %edi
    movl $0x02001001, 0(%edi)     /* root[bus0] = ctx | P */
    movl $0, 4(%edi)
    movl $0x02001000, %edi
    movl dev, %eax
    shll $7, %eax                 /* devfn * 16 (16-byte entries) */
    movl $0x02002001, 0(%edi,%eax)        /* ctx[devfn].lo = L3 | P */
    movl $0, 4(%edi,%eax)
    movl $1, 8(%edi,%eax)                 /* ctx[devfn].hi = aw=1 */
    movl $0, 12(%edi,%eax)
    movl $0x02002000, %edi
    movl $0x02003003, 0(%edi)     /* L3[0] = L2 | P | RW */
    movl $0, 4(%edi)
    movl $0x02003000, %edi
    /* entries: 128 = iova 0x10000000, 136 = iova 0x11000000 */
    movl $128, %ecx
    movl $0x01000000, %eax
    orl $0x83, %eax               /* phys | PS(2M) | RW | P */
    movl %eax, 0(%edi,%ecx,8)
    movl $136, %ecx
    movl $0x01200000, %eax        /* 2 MiB-aligned phys for the 2M page */
    orl $0x83, %eax
    movl %eax, 0(%edi,%ecx,8)

    /* DMAR: RTADDR, SRTP, TE */
    movl $0xfed90000, %esi
    movl $0x02000000, 0x20(%esi)
    movl $0, 0x24(%esi)
    movl $0x40000000, 0x18(%esi)  /* GCMD: SRTP */
    call wait_rtps
    movl $0x80000000, 0x18(%esi)  /* GCMD: TE */
    call wait_tes

    /* --- IOVA DMA: src 0x10000000 -> dst 0x11000000 ---- */
    movl bar0, %esi
    movl $0x10000000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x11000000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x1000, 0x18(%esi)
    movl $1, 0x04(%esi)
    call wait_done
    testl $4, 0x1c(%esi)
    jz 1f
    incl fail
1:  movl $0x01200000, %edi
    cmpl $0xaa55aa55, (%edi)
    je 2f
    incl fail
2:  movl $1, trans_ok

    /* --- negative: DMA to unmapped IOVA 0x12000000 faults ---- */
    movl bar0, %esi
    movl $0x10000000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x12000000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x1000, 0x18(%esi)
    movl $1, 0x04(%esi)
    call wait_done
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jnz 3f
    incl fail
3:  movl $1, fault_ok

report:
    movl $msg, %esi
    call puts
    cmpl $0, fail
    je 1f
    lea failmsg, %esi
    call puts
    jmp 2f
1:  lea okmsg, %esi
    call puts
2:  movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $sp_t, %esi
    call puts
    movl trans_ok, %eax
    call puthex
    movl $sp_x, %esi
    call puts
    movl fault_ok, %eax
    call puthex
    movl $sp_dev, %esi
    call puts
    movl dev, %eax
    call puthex
    movl $sp_ps, %esi
    call puts
    movl pt_status, %eax
    call puthex
    movl $sp_pd, %esi
    call puts
    movl pt_data, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* wait_done: poll status (esi=bar0) until done or error */
wait_done:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $6, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
    ret

/* wait_rtps: poll GSTS.RTPS (bit 30) */
wait_rtps:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $0x40000000, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
    ret

/* wait_tes: poll GSTS.TES (bit 31) */
wait_tes:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $0x80000000, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
    ret

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

/* cfgwrite32: edi=dev, ecx=byteoff, ebp=val (clobbers eax, ebx, edx) */
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
    movl %ebp, %eax
    outl %eax, %edx
    ret

/* puts: esi = string */
puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %esi
    jmp puts
2:  ret

/* puthex: eax */
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

/* putc: al */
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
dev:       .long 0
bar0:      .long 0
trans_ok:  .long 0
fault_ok:  .long 0
pt_status: .long 0
pt_data:   .long 0
fail:      .long 0

    .section .rodata
msg:     .asciz "IOMMU "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_t:    .asciz " trans="
sp_x:    .asciz " fault="
sp_dev:  .asciz " dev="
sp_ps:   .asciz " ptst="
sp_pd:   .asciz " ptd="
nl:      .asciz "\n"
