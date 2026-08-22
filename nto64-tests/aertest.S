/* SPDX-License-Identifier: BSD-2-Clause */

/* aertest.S - freestanding multiboot PCIe AER injection test
 * (the "Bad-behaviour coverage gaps" PCIe AER item, 2026-08-22).
 *
 * Drives nto64-dma's guest-armed AER hook (BAR0+0x94: write "AERC" /
 * "AERU" / "AERF") on the q35 root bus and verifies each injected
 * transport error through the DEVICE's AER capability (extended
 * config, cap id 0x0001, read via the ECAM window at 0xb0000000):
 *
 *   a1 - correctable (Receiver Error, COR status bit 0; correctable
 *        errors do NOT log the TLP header in QEMU's AER model - the
 *        header log is only written for uncorrectable / advisory
 *        errors, so a1 checks status + count only);
 *   a2 - uncorrectable non-fatal (Data Link Protocol, UNCOR bit 4);
 *   a3 - uncorrectable fatal (Internal Error, UNCOR bit 22).
 *
 * Each phase: inject -> the expected status bit is set and the TLP
 * header log holds the injected header -> the AER inject count
 * (BAR0+0x98) advanced -> the status is cleared (W1C) and stays clear.
 *
 * Run: make run-aertest  (-machine q35 -device nto64-dma)
 * Expected: 'AERTEST a1=1 a2=1 a3=1 cnt=00000003 f=00000000'.
 */

#define ECAM_BASE  0xb0000000
#define AER_OFF    0x100
#define ERR_COR_STATUS   0x10
#define ERR_UNCOR_STATUS 0x04
#define ERR_HEADER_LOG   0x1c
#define COR_RCVR  0x00000001
#define UNC_DLP   0x00000010
#define UNC_INTN  0x00400000
#define MAG_AERC  0x43524541
#define MAG_AERU  0x55524541
#define MAG_AERF  0x46524541

    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

    .section .text
    .globl _start
_start:
    movl $0, fail
    movl $0, a1
    movl $0, a2
    movl $0, a3
    movl $0, aer_cnt

    /* --- find nto64-dma (1234:1ee9) ---- */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x1ee91234, %eax
    je found
scan_next:
    incl %edi
    cmpl $256, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

found:
    movl %edi, dma_dev
    /* enable memory + bus master */
    movl $4, %ecx
    call pcicfg
    orl $6, %eax
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    /* BAR0 */
    movl dma_dev, %edi
    movl $0x10, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, bar0
    /* magic check */
    movl bar0, %esi
    cmpl $0x4d44544e, (%esi)   /* "NTDM" */
    je 1f
    incl fail
    jmp report
1:
    /* --- ECAM: walk the extended capability list for id 1 (AER) ---- */
    movl dma_dev, %eax
    shrl $3, %eax
    andl $0x1f, %eax
    shll $15, %eax
    movl dma_dev, %edx
    andl $7, %edx
    shll $12, %edx
    orl %edx, %eax
    addl $ECAM_BASE, %eax
    movl %eax, ecam
    movl $AER_OFF, %ebx
    movl $16, %ecx            /* bound the walk; a cycle must terminate */
aer_walk:
    testl %ecx, %ecx
    jz aer_miss
    decl %ecx
    movl ecam, %eax
    addl %ebx, %eax
    movl (%eax), %edx
    movl %edx, %eax
    andl $0xffff, %eax
    cmpl $1, %eax              /* PCI_EXT_CAP_ID_ERR */
    je aer_found
    movl %edx, %eax
    shrl $20, %eax
    andl $0xffc, %eax          /* next capability, byte offset (bits [31:20],
                                 low 2 bits reserved/zero - no <<2 needed) */
    movl %eax, %ebx            /* advance the traversal cursor */
    testl %ebx, %ebx
    jz aer_miss
    cmpl $0x100, %ebx
    jb aer_miss
    cmpl $0xfff, %ebx
    ja aer_miss
    jmp aer_walk
aer_miss:
    movl $msg_noaer, %esi
    call puts
    incl fail
    jmp report

aer_found:
    movl %ebx, aer_off

    /* --- a1: correctable (Receiver Error) ---- */
    movl bar0, %esi
    movl $MAG_AERC, 0x94(%esi)
    call chk_cor
    jnz a1_bad
    movl $1, a1
    jmp a1_done
a1_bad:
    incl fail
a1_done:

    /* --- a2: uncorrectable non-fatal (Data Link Protocol) ---- */
    movl bar0, %esi
    movl $MAG_AERU, 0x94(%esi)
    movl $UNC_DLP, %edi
    call chk_unc
    jnz a2_bad
    movl $1, a2
    jmp a2_done
a2_bad:
    incl fail
a2_done:

    /* --- a3: uncorrectable fatal (Internal Error) ---- */
    movl bar0, %esi
    movl $MAG_AERF, 0x94(%esi)
    movl $UNC_INTN, %edi
    call chk_unc
    jnz a3_bad
    movl $1, a3
    jmp a3_done
a3_bad:
    incl fail
a3_done:

    jmp report

/* chk_cor: verify a correctable error is logged: COR status bit 0 set,
 * header log holds 0x1234, inject count advanced, then clear + verify.
 * eax = 0 ok, non-zero fail.  Clobbers eax, ecx, edx, esi. */
chk_cor:
    movl aer_off, %ecx
    addl $ERR_COR_STATUS, %ecx
    call ecam_read
    testl $COR_RCVR, %eax
    jz 9f
    /* device count advanced */
    call chk_cnt
    jnz 9f
    /* clear COR status (W1C) and verify */
    movl aer_off, %ecx
    addl $ERR_COR_STATUS, %ecx
    movl $COR_RCVR, %eax
    call ecam_write
    movl aer_off, %ecx
    addl $ERR_COR_STATUS, %ecx
    call ecam_read
    testl $COR_RCVR, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* chk_unc: same for an uncorrectable error: UNCOR status bit = the
 * error bit in edi, header log verified, count advanced, cleared. */
chk_unc:
    movl aer_off, %ecx
    addl $ERR_UNCOR_STATUS, %ecx
    call ecam_read
    testl %edi, %eax
    jz 9f
    movl aer_off, %ecx
    addl $ERR_HEADER_LOG, %ecx
    call ecam_read
    bswap %eax                 /* header log is big-endian (TLP wire) */
    cmpl $0x1234, %eax
    jne 9f
    call chk_cnt
    jnz 9f
    movl aer_off, %ecx
    addl $ERR_UNCOR_STATUS, %ecx
    movl %edi, %eax
    call ecam_write
    movl aer_off, %ecx
    addl $ERR_UNCOR_STATUS, %ecx
    call ecam_read
    testl %edi, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* chk_cnt: the AER inject count (BAR0+0x98) must equal aer_cnt+1, then
 * aer_cnt++.  eax = 0 ok, non-zero fail. */
chk_cnt:
    movl bar0, %esi
    movl 0x98(%esi), %eax
    movl aer_cnt, %edx
    incl %edx
    cmpl %edx, %eax
    jne 9f
    movl aer_cnt, %edx
    incl %edx
    movl %edx, aer_cnt
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* ecam_read: ecx = register offset -> eax (clobbers esi, edx) */
ecam_read:
    movl ecam, %esi
    addl %ecx, %esi
    movl (%esi), %eax
    ret

/* ecam_write: ecx = register offset, eax = value */
ecam_write:
    movl ecam, %esi
    addl %ecx, %esi
    movl %eax, (%esi)
    ret

/* -------- low-level helpers (copied from ahciintr.S) --------- */
pcicfg:
    movl %edi, %ebx
    movl %ebx, %eax
    shrl $3, %eax
    andl $0x1f, %eax
    shll $11, %eax
    movl %ebx, %edx
    andl $7, %edx
    shll $8, %edx
    orl %edx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    inl %edx, %eax
    ret

pcicfg_write:
    movl %eax, %esi
    movl %edi, %ebx
    movl %ebx, %eax
    shrl $3, %eax
    andl $0x1f, %eax
    shll $11, %eax
    movl %ebx, %edx
    andl $7, %edx
    shll $8, %edx
    orl %edx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    movl %esi, %eax
    outl %eax, %edx
    ret

puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    incl %esi
    jmp puts
2:  ret

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

putdec:
    movl %eax, %ecx
    xorl %edi, %edi
    testl %ecx, %ecx
    jnz 1f
    movl $'0', %eax
    call putc
    ret
1:  xorl %edx, %edx
    movl $10, %ebx
    divl %ebx
    pushl %edx
    incl %edi
    testl %eax, %eax
    jnz 1b
2:  popl %eax
    addl $'0', %eax
    call putc
    decl %edi
    jnz 2b
    ret

putnl:
    movl $'\n', %eax
    call putc
    ret

report:
    movl $msg_aertest, %esi
    call puts
    movl $sp_a1, %esi
    call puts
    movl a1, %eax
    call putdec
    movl $sp_a2, %esi
    call puts
    movl a2, %eax
    call putdec
    movl $sp_a3, %esi
    call puts
    movl a3, %eax
    call putdec
    movl $sp_cnt, %esi
    call puts
    movl aer_cnt, %eax
    call puthex
    movl $sp_devcnt, %esi
    call puts
    movl bar0, %esi
    movl 0x98(%esi), %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

    .bss
    .balign 16
fail:       .long 0
dma_dev:    .long 0
bar0:       .long 0
ecam:       .long 0
aer_off:    .long 0
aer_cnt:    .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0

    .data
msg_nodev:  .asciz "AERTEST: no nto64-dma\n"
msg_noaer:  .asciz "AERTEST: no AER cap\n"
msg_aertest: .asciz "AERTEST"
sp_a1:      .asciz " a1="
sp_a2:      .asciz " a2="
sp_a3:      .asciz " a3="
sp_cnt:     .asciz " cnt="
sp_devcnt:  .asciz " dev="
sp_f:       .asciz " f="
nl:         .asciz "\n"
