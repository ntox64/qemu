/* SPDX-License-Identifier: BSD-2-Clause */

/* scsiintr.S - freestanding multiboot virtio-scsi completion /
 * interrupt-loss test.
 *
 * A minimal LEGACY virtio-scsi driver (PCI I/O BAR, request vring) that
 * enables the MSI-X completion interrupt (IDT + BSP LAPIC, vector 0x20 ->
 * isr_common) and proves the polling-fallback recovery when an interrupt
 * is lost.  Uses TEST UNIT READY (0x00, no data stage) on the request vq:
 *
 *   a1 - one TUR completes via the ISR (irq_seen=1, no poll fallback);
 *   a2 - the armed interrupt is LOST (-device virtio-scsi-pci,nto64-msix-drop=2):
 *        the used-ring entry lands but no MSI fires, the bounded ISR wait
 *        times out, the driver falls back to polling the used ring and
 *        recovers (a2=2, poll=1);
 *   a3 - delivery RESUMES on the next command (a3=1).
 *
 * Device hook: the generic virtio-pci `nto64-msix-drop=N` (hw/virtio/
 * virtio-pci.c virtio_pci_notify) - drops the Nth notify while MSI-X is
 * enabled (the used-ring entry still lands).
 *
 * Run:
 *   make run-scsiintr           (clean: a1=1 a2=1 a3=1 p=0)
 *   make run-scsiintrinj        (-device virtio-scsi-pci,nto64-msix-drop=2, a2=2)
 *
 * Prints 'SINTR a1=.. a2=.. a3=.. p=.. f=00000000'.
 */

#define VQ_REQ    2
#define RING_REQ  0x220000
#define CMD_HDR   0x300000        /* 64-byte virtio-scsi cmd req buffer */
#define CDB_BUF   0x300100        /* 16-byte CDB staging */
#define RESP      0x300200        /* 256-byte response+sense buffer (204 used) */
#define DATA      0x300400        /* 512-byte data buffer */

#define VIRTIO_PCI_HOST_FEATURES  0x00
#define VIRTIO_PCI_GUEST_FEATURES 0x04
#define VIRTIO_PCI_QUEUE_PFN      0x08
#define VIRTIO_PCI_QUEUE_SIZE     0x0c
#define VIRTIO_PCI_QUEUE_SEL      0x0e
#define VIRTIO_PCI_QUEUE_NOTIFY   0x10
#define VIRTIO_PCI_STATUS         0x12
#define VIRTIO_PCI_CONFIG         0x14
#define VIRTIO_MSI_CONFIG_VECTOR  0x00
#define VIRTIO_MSI_QUEUE_VECTOR   0x20
#define VRING_DESC_F_NEXT         1
#define VRING_DESC_F_WRITE        2

#define IDT_BASE   0x11000
#define LAPIC      0xfee00000
#define IRQ_TIMEOUT 300000000

/* Legacy virtio-pci registers are I/O-PORT registers (I/O BAR). */
.macro voutl off, val
    movl io_base, %edx
    addl $\off, %edx
    movl \val, %eax
    outl %eax, %dx
.endm
.macro voutw off, val
    movl io_base, %edx
    addl $\off, %edx
    movw \val, %ax
    outw %ax, %dx
.endm
.macro vinw off, dst
    movl io_base, %edx
    addl $\off, %edx
    inw %dx, %ax
    movzwl %ax, \dst
.endm

    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

    .section .text
    .globl _start
_start:
    movl %ebx, mbi_ptr          /* save the multiboot info pointer (EBX) */
    movl $stack_top, %esp
    andl $-16, %esp
    movl $0, fail
    movl $0, a1
    movl $0, a2
    movl $0, a3
    movl $0, irq_total
    movl $0, poll_total

    /* zero the staging area */
    movl $0x300000, %edi
    xorl %eax, %eax
    movl $0x1200, %ecx
1:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 1b

    /* --- scan for virtio-scsi legacy (1af4:1004) ---- */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x10041af4, %eax
    je found_scsi
scan_next:
    incl %edi
    cmpl $64, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report
found_scsi:
    movl %edi, scsi_dev

    /* --- enable I/O + bus master, read I/O BAR0 ---- */
    movl $4, %ecx
    call cfgread32
    orl $3, %eax
    movl %eax, %ebp
    movl scsi_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl scsi_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    testl %eax, %eax
    jz no_dev
    movl %eax, io_base

    /* --- MSI-X: find cap (id 0x11), program vector 0 -> BSP ---- */
    movl scsi_dev, %edi
    movl $0x34, %ecx
    call cfgread32
    andl $0xfc, %eax
    movl %eax, msix_cap
msix_loop:
    movl msix_cap, %ebx
    testl %ebx, %ebx
    jz msix_bad
    movl %ebx, %ecx
    call cfgread32
    movl %eax, %edx
    andl $0xff, %edx
    cmpl $0x11, %edx
    je msix_found
    shrl $8, %eax
    andl $0xfc, %eax
    movl %eax, msix_cap
    jmp msix_loop
msix_bad:
    movl $msg_msix, %esi
    call puts
    incl fail
    jmp report
msix_found:
    movl msix_cap, %ebx
    leal 4(%ebx), %ecx
    call cfgread32
    movl %eax, %edx             /* table offset register */
    andl $7, %edx               /* BIR (bar index) */
    andl $0xfffffff8, %eax      /* table offset */
    movl %eax, msix_tbloff
    movl %edx, %ebx
    shll $2, %ebx
    addl $0x10, %ebx            /* config reg of the BIR BAR */
    movl scsi_dev, %edi
    movl %ebx, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    addl msix_tbloff, %eax
    movl %eax, msix_table
    /* program MSI-X vector 0: data 0x20, dest BSP (LAPIC) */
    movl %eax, %edi
    movl $0xfee00000, (%edi)
    movl $0, 4(%edi)
    movl $0x20, 8(%edi)
    movl $0, 12(%edi)

    /* --- IDT: vector 0x20 -> isr_common, rest dummy ---- */
    movl $IDT_BASE, %edi
    xorl %ebx, %ebx
idt_loop:
    cmpl $0x20, %ebx
    je idt_irq
    movl $dummy_isr, %edx
    jmp idt_set
idt_irq:
    movl $isr_common, %edx
idt_set:
    movw %dx, 0(%edi)
    movw $0x08, 2(%edi)
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %edx
    movw %dx, 6(%edi)
    addl $8, %edi
    incl %ebx
    cmpl $256, %ebx
    jne idt_loop
    lidt idt_desc

    /* BSP local APIC: SVR enable, mask LINT0/LINT1 */
    movl $LAPIC, %eax
    movl $0x1f0, 0xf0(%eax)
    movl $0x10000, 0x350(%eax)
    movl $0x10000, 0x360(%eax)

    /* --- legacy virtio bring-up ---- */
    voutw VIRTIO_PCI_STATUS, $0
    voutw VIRTIO_PCI_STATUS, $1
    voutw VIRTIO_PCI_STATUS, $3
    vinw VIRTIO_PCI_HOST_FEATURES, %ebx
    voutl VIRTIO_PCI_GUEST_FEATURES, $0

    /* zero vring area */
    movl $RING_REQ, %edi
    xorl %eax, %eax
    movl $0x3000, %ecx
1:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 1b

    /* set up vq2 (request) */
    movl $VQ_REQ, %edi
    movl $RING_REQ, %esi
    call setup_vq
    voutw VIRTIO_PCI_STATUS, $7        /* DRIVER_OK */

    /* enable MSI-X (cap+0 dword bit 31) */
    movl scsi_dev, %edi
    movl msix_cap, %ecx
    call cfgread32
    movl %eax, %edx
    andl $0xffff, %edx
    shrl $16, %eax
    orl $0x8000, %eax
    andl $0xbfff, %eax
    shll $16, %eax
    orl %edx, %eax
    movl %eax, %ebp            /* cfgwrite32 writes EBP, not EAX! */
    movl scsi_dev, %edi
    movl msix_cap, %ecx
    call cfgwrite32

    /* assign the REQ vq (vq2) to MSI-X vector 0; config vector unused */
    voutw VIRTIO_PCI_QUEUE_SEL, $2        /* select vq2 */
    movl io_base, %edx
    addl $0x16, %edx      /* legacy I/O VIRTIO_MSI_QUEUE_VECTOR (absolute) */
    xorl %eax, %eax
    outw %ax, %dx
    movl io_base, %edx
    addl $0x14, %edx      /* legacy I/O VIRTIO_MSI_CONFIG_VECTOR (absolute) */
    movw $0xffff, %ax
    outw %ax, %dx

    /* debug: read back MSI-X control + queue vector + table[0] */
    movl scsi_dev, %edi
    movl msix_cap, %ecx
    call cfgread32
    movl %eax, dbg
    movl $msg_sctrl, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    voutw VIRTIO_PCI_QUEUE_SEL, $2        /* select vq2 for the vector read */
    movl io_base, %edx
    addl $0x16, %edx
    inw %dx, %ax
    movl %eax, dbg
    movl $msg_qvec, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl msix_table, %eax
    movl %eax, dbg
    movl $msg_mtbl, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl msix_table, %edi
    movl 0(%edi), %eax
    movl %eax, dbg
    movl $msg_maddr, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl

    sti

    /* --- phase a1: TUR, interrupt-driven ---- */
    call tur_cmd_irq
    cmpl $0xff, %eax
    je io_fail
    cmpl $0, poll_last
    jne io_fail
    movl $1, a1

    /* --- phase a2: TUR whose completion interrupt is LOST ---- */
    call tur_cmd_irq
    cmpl $0xff, %eax
    je io_fail
    cmpl $1, poll_last
    je a2_drop
    movl $1, a2
    jmp a2_done
a2_drop:
    movl $2, a2
a2_done:

    /* --- phase a3: TUR, delivery resumed ---- */
    call tur_cmd_irq
    cmpl $0xff, %eax
    je io_fail
    cmpl $0, poll_last
    jne io_fail
    movl $1, a3

    jmp report

io_fail:
    movl $msg_io, %esi
    call puts
    incl fail
    jmp report

/* tur_cmd_irq: submit a TEST UNIT READY (0x00, no data) on the request
 * vq, bounded-wait for the ISR, and - on timeout - poll the used ring.
 * Returns 0 on clean completion (used idx advanced, status GOOD),
 * 0xff on timeout.  Sets poll_last + the a2 recovery flag. */
tur_cmd_irq:
    /* build the cmd_req at CMD_HDR: lun{1,0,...}, tag, cdb */
    movb $1, CMD_HDR          /* lun[0]=1 */
    movl $0, CMD_HDR+4
    movl $1, CMD_HDR+8        /* tag lo */
    movl $0, CMD_HDR+12       /* tag hi */
    movl $0, CMD_HDR+16       /* attr/prio/crn */
    movl $0, CDB_BUF          /* TUR cdb = 0x00 */
    movl $CDB_BUF, %ebx
    xorl %edx, %edx
1:  movb (%ebx,%edx), %al
    movb %al, CMD_HDR+19(%edx)
    incl %edx
    cmpl $16, %edx
    jb 1b
    xorl %eax, %eax
    movl $15, %edx
2:  movb %al, CMD_HDR+35(%edx)
    decl %edx
    jns 2b
    movl $0, RESP            /* clear response+status area */

    /* descriptors on the request vq: d0=CMD_HDR(NEXT->1), d1=RESP(WRITE) */
    movl $RING_REQ, %edi
    movl $CMD_HDR, 0(%edi)
    movl $83, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)
    movl $RESP, 16(%edi)
    movl $204, 24(%edi)
    movw $VRING_DESC_F_WRITE, 28(%edi)

    /* submit on vq2 */
    movl $VQ_REQ, %eax
    call vq_submit_irq
    movl %eax, dbg
    movl $msg_vq, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl q_lastused+8, %eax
    movl $msg_used, %esi
    call puts
    call puthex
    call putnl
    movl dbg, %eax
    ret

/* vq_submit_irq: eax = vq.  Sets avail idx, notifies, bounded-waits for
 * irq_seen, falls back to polling the used ring.  Returns 0 on used-idx
 * advance, 0xff on poll timeout.  Clobbers eax, ecx, edx, edi. */
vq_submit_irq:
    pushl %eax
    movl %eax, %ecx
    movl q_avail(,%ecx,4), %edi
    movl q_availidx(,%ecx,4), %eax
    movl q_mask(,%ecx,4), %edx
    andl %edx, %eax
    movw $0, 4(%edi,%eax,2)
    movl q_availidx(,%ecx,4), %eax
    incl %eax
    movl %eax, q_availidx(,%ecx,4)
    movw %ax, 2(%edi)
    popl %eax
    movl $0, irq_seen          /* reset before notify (no race) */
    /* notify */
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    outw %ax, %dx
    /* bounded ISR wait */
    movl $IRQ_TIMEOUT, %edx
1:  cmpl $1, irq_seen
    je 2f
    decl %edx
    jnz 1b
    movl $1, poll_last
    incl poll_total
    jmp 3f
2:  movl $0, poll_last
3:  /* poll used.idx */
    movl %eax, %ecx             /* vq */
    movl q_used(,%ecx,4), %edi
    movl $200000000, %edx
4:  movzwl 2(%edi), %eax
    cmpl q_lastused(,%ecx,4), %eax
    jne 5f
    decl %edx
    jnz 4b
    movl $0xff, %eax
    ret
5:  movl %eax, q_lastused(,%ecx,4)
    xorl %eax, %eax
    incl irq_total
    ret

/* --- setup_vq (from scsitest.S) ---- */
setup_vq:
    voutw VIRTIO_PCI_QUEUE_SEL, %di
    vinw VIRTIO_PCI_QUEUE_SIZE, %eax
    testl %eax, %eax
    jz no_dev
    cmpl $256, %eax
    jbe 1f
    movl $256, %eax
1:  movl %edi, %ecx
    movl %eax, q_ring(,%ecx,4)
    decl %eax
    movl %eax, q_mask(,%ecx,4)
    movl q_ring(,%ecx,4), %eax
    shll $4, %eax
    addl %esi, %eax
    movl %eax, q_avail(,%ecx,4)
    addl $6, %eax
    movl q_ring(,%ecx,4), %ebx
    shll $1, %ebx
    addl %ebx, %eax
    addl $0xfff, %eax
    andl $0xfffff000, %eax
    movl %eax, q_used(,%ecx,4)
    movl %esi, %edi
    xorl %eax, %eax
    movl $0x3000, %ecx
2:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 2b
    movl %esi, %eax
    shrl $12, %eax
    movl %eax, %ebx
    voutl VIRTIO_PCI_QUEUE_PFN, %ebx
    ret

no_dev:
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

/* -------- low-level helpers --------- */
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

cfgwrite32:
    movl %ebp, %esi
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $11, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
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

isr_common:
    pushal
    movl $1, irq_seen
    movl $LAPIC, %eax
    movl $0, 0xb0(%eax)
    popal
    iret
dummy_isr:
    iret

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: the A2 phase must match the run config.  Bit 0 of the
 * expected mask means "the armed interrupt must be lost" (a2=2);
 * otherwise the run is clean (a2=1).  A mismatch increments fail. */
verify_expect:
    call nto64_expect
    movl %eax, %ebx
    testl $1, %ebx
    jnz .Lve_drop
    cmpl $1, a2
    je .Lve_done
    incl fail
    jmp .Lve_done
.Lve_drop:
    cmpl $2, a2
    je .Lve_done
    incl fail
.Lve_done:
    ret

report:
    call verify_expect
    movl $msg_sintr, %esi
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
    movl $sp_p, %esi
    call puts
    movl poll_total, %eax
    call putdec
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
mbi_ptr:    .long 0
stack:   .fill 1024,1,0
stack_top:
fail:       .long 0
scsi_dev:   .long 0
io_base:    .long 0
msix_cap:   .long 0
msix_table: .long 0
msix_tbloff: .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
irq_seen:   .long 0
poll_last:  .long 0
irq_total:  .long 0
poll_total: .long 0
dbg:        .long 0
q_ring:     .long 0,0,0
q_mask:     .long 0,0,0
q_avail:    .long 0,0,0
q_used:     .long 0,0,0
q_availidx: .long 0,0,0
q_lastused: .long 0,0,0

    .data
idt_desc:
    .word 256*8 - 1
    .long IDT_BASE
msg_nodev: .asciz "SINTR: no device\n"
msg_msix:  .asciz "SINTR: no MSI-X\n"
msg_io:    .asciz "SINTR: io\n"
msg_vq:    .asciz "SINTR: vq="
msg_used:  .asciz "SINTR: used="
msg_sctrl: .asciz "SINTR: sctrl="
msg_qvec:  .asciz "SINTR: qvec="
msg_mtbl:  .asciz "SINTR: mtbl="
msg_maddr: .asciz "SINTR: maddr="
msg_sintr: .asciz "SINTR"
sp_a1:     .asciz " a1="
sp_a2:     .asciz " a2="
sp_a3:     .asciz " a3="
sp_p:      .asciz " p="
sp_f:      .asciz " f="
nl:        .asciz "\n"
