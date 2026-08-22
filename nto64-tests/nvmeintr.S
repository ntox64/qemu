/* SPDX-License-Identifier: BSD-2-Clause */

/* nvmeintr.S - freestanding multiboot NVMe completion / interrupt-loss
 * test.
 *
 * A minimal single-queue NVMe driver that runs the controller with a
 * MSI-X completion interrupt ENABLED (IDT + BSP LAPIC, vector 0x20 ->
 * irq_common) and proves the recovery-with-polling fallback a real
 * driver must have when an interrupt is lost:
 *
 *   a1 - clean-ish baseline: one Write completes via the ISR
 *        (irq_seen=1, no poll fallback) - proves interrupts work.
 *   a2 - the armed interrupt is LOST (-device nvme,nto64-msix-drop=2):
 *        the CQ entry lands but no ISR fires; the driver's bounded ISR
 *        wait times out, it falls back to polling the CQ, completes the
 *        command and sets poll_used.  a2=2 on the drop target, a2=1 on
 *        the clean target (no drop -> interrupts arrive normally).
 *   a3 - delivery RESUMES on the next command (the drop is one-shot):
 *        a3=1.
 *
 * Device hook: hw/nvme/ctrl.c nvme_irq_assert -> `nto64-msix-drop=N`
 * drops the Nth deliverable completion interrupt (the CQ entry still
 * lands, so a driver that bounds its ISR wait and polls recovers).
 *
 * Run:
 *   make run-nvmeintr          - no drop (a1=a3=1, a2=1)
 *   make run-nvmeintrdrop      - -device nvme,nto64-msix-drop=2 (a2=2)
 *
 * Prints to COM1, halts.  Expected:
 *   'NINTR a1=1 a2=<1|2> a3=1 i=<irq total> p=<poll fallbacks> f=00000000'
 */

/* NVMe register offsets in BAR0 (NvmeBar) */
.equ NVME_CAP,   0x00
.equ NVME_CC,    0x14
.equ NVME_CSTS,  0x1c
.equ NVME_AQA,   0x24
.equ NVME_ASQ,   0x28
.equ NVME_ACQ,   0x30
.equ NVME_SQTDBL, 0x1000      /* SQ0TDBL; stride 8 per queue pair */
.equ NVME_CQHDBL, 0x1004      /* CQ0HDBL */

.equ QSIZE,      16            /* entries per queue (phase never wraps) */
.equ CQES,       16
.equ SQES,       64

/* guest memory layout */
.equ IDT_BASE,   0x11000
.equ IDT_PTR,    0x11800
.equ ASQ_ADDR,   0x13000       /* admin SQ (16 x 64B) */
.equ ACQ_ADDR,   0x14000       /* admin CQ (16 x 16B) */
.equ CMD_TMPL,   0x17000       /* 64-byte command template */
.equ CQ1,        0x200000      /* I/O CQ1 (16 x 16B) */
.equ SQ1,        0x201000      /* I/O SQ1 (16 x 64B) */
.equ WBUF,       0x202000      /* write buffer (4 KiB) */
.equ LAPIC,      0xfee00000

/* bounded-ISR-wait bound (large enough that a clean phase never
 * times out under TCG; the drop phase exhausts it) */
.equ IRQ_TIMEOUT, 300000000
/* bounded CQ-poll bound (same order as nvmetest.S io_cmd) */
.equ CQ_TIMEOUT,  100000000

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
    movl $0, irq_total
    movl $0, poll_total

    /* --- find the NVMe device (class 0x010802 or 8086:5845) ---- */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x58458086, %eax
    je nvme_found
    movl $0x08, %ecx
    call pcicfg
    andl $0xffffff00, %eax
    cmpl $0x01080200, %eax
    je nvme_found
scan_next:
    incl %edi
    cmpl $32, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

nvme_found:
    movl %edi, nvme_dev
    /* BAR0 (memory BAR, lower dword at config 0x10) */
    movl $0x10, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, bar0
    /* enable memory + bus master */
    movl $0x04, %ecx
    call pcicfg
    orl $0x7, %eax
    movl $0x04, %ecx
    call pcicfg_write

    /* --- find MSI-X cap, program one vector, enable ---- */
    movl $0x34, %ecx
    call pcicfg
    andl $0xff, %eax
    movl %eax, msix_cap
msix_cap_loop:
    movl msix_cap, %ebx
    testl %ebx, %ebx
    jz msix_bad
    movl %ebx, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xff, %edx
    cmpl $0x11, %edx           /* MSI-X */
    je msix_found
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, msix_cap
    jmp msix_cap_loop
msix_bad:
    movl $msg_msix, %esi
    call puts
    incl fail
    jmp report
msix_found:
    movl msix_cap, %ebx
    leal 4(%ebx), %ecx
    call pcicfg
    andl $0xfffffff8, %eax
    addl bar0, %eax
    movl %eax, msix_table
    /* vector 0 -> data 0x20, dest CPU0 (BSP) */
    movl %eax, %edx
    movl $0xfee00000, (%edx)
    movl $0, 4(%edx)
    movl $0x20, 8(%edx)
    movl $0, 12(%edx)
    /* enable MSI-X: dword bit 31 (of the capability dword) = enable,
     * dword bit 30 = function-mask-clear. */
    movl nvme_dev, %edi
    movl msix_cap, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xffff, %edx
    shrl $16, %eax
    orl $0x8000, %eax
    andl $0xbfff, %eax
    shll $16, %eax
    orl %edx, %eax
    movl nvme_dev, %edi
    movl msix_cap, %ecx
    call pcicfg_write

    /* --- IDT: vector 0x20 -> irq_common, rest dummy ---- */
    movl $IDT_BASE, %edi
    xorl %ebx, %ebx
idt_loop:
    cmpl $0x20, %ebx
    je idt_irq
    movl $dummy_isr, %edx
    jmp idt_set
idt_irq:
    movl $irq_common, %edx
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

    /* mask the legacy PICs (IRQ0 cannot fake NVMe) */
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    /* BSP local APIC: SVR enable, mask LINT0/LINT1 */
    movl $LAPIC, %eax
    movl $0x1f0, 0xf0(%eax)
    movl $0x10000, 0x350(%eax)
    movl $0x10000, 0x360(%eax)

    sti

    /* --- NVMe controller enable (reset SeaBIOS's state first) ---- */
    movl bar0, %ebp
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)
    movl $10000000, %ecx
rdy0_wait:
    movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jz rdy0_ok
    decl %ecx
    jnz rdy0_wait
    movl $msg_rdy, %esi
    call puts
    incl fail
    jmp report
rdy0_ok:
    movl $0x000f000f, NVME_AQA(%ebp)
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)   /* EN, IOCQES=4, IOSQES=6 */
    movl $10000000, %ecx
rdy_wait:
    movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jnz rdy_ok
    decl %ecx
    jnz rdy_wait
    movl $msg_rdy, %esi
    call puts
    incl fail
    jmp report
rdy_ok:

    /* --- create I/O CQ1 ---- */
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl $CQ1, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40       /* qid | (qsize-1)<<16 */
    movl $3, CMD_TMPL+44         /* PC | IEN, IV=0 (MSI-X vector 0) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    /* --- create I/O SQ1 ---- */
    call clr_cmd
    movb $1, CMD_TMPL            /* Create I/O SQ */
    movl $SQ1, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $1, %eax
    shll $16, %eax
    orl $((2 << 2) | 1), %eax
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad

    /* --- fill the write buffer with a pattern ---- */
    movl $WBUF, %edi
    movl $0x11223344, %eax
    movl $1024, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    incl %eax
    decl %ecx
    jnz 1b

    /* --- phase a1: Write, interrupt-driven (no drop) ---- */
    call clr_cmd
    movb $1, CMD_TMPL            /* Write */
    movl $1, CMD_TMPL+4          /* nsid */
    movl $WBUF, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40         /* slba 0 */
    movl $0, CMD_TMPL+48         /* nlb 0 = 1 LBA */
    movl $1, %ebx                /* qid */
    movl $CMD_TMPL, %esi
    call io_cmd_irq
    testl %eax, %eax
    jnz io_fail
    cmpl $0, poll_last
    jne io_fail                  /* a1 must be interrupt-driven */
    movl $1, a1

    /* --- phase a2: Write whose completion interrupt is LOST ---- */
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WBUF, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, CMD_TMPL+40         /* slba 1 */
    movl $0, CMD_TMPL+48
    movl $1, %ebx
    movl $CMD_TMPL, %esi
    call io_cmd_irq
    testl %eax, %eax
    jnz io_fail
    cmpl $1, poll_last
    jne 1f
    movl $2, a2                  /* the armed interrupt was lost */
    jmp 2f
1:  movl $1, a2                  /* clean: interrupt delivered */
2:
    /* The run config must actually exercise the path it claims: the
     * clean run has to stay interrupt-driven and the drop run has to
     * time out and poll.  Otherwise a dead nto64-msix-drop silently
     * "passes" with a2=1 and f=0. */
#ifdef EXPECT_DROP
    cmpl $2, a2
    jne a2_bad
#else
    cmpl $1, a2
    jne a2_bad
#endif
    jmp a2_done
a2_bad:
    movl $msg_path, %esi
    call puts
    incl fail
    jmp report
a2_done:

    /* --- phase a3: Write, delivery resumed (drop is one-shot) ---- */
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WBUF, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $2, CMD_TMPL+40         /* slba 2 */
    movl $0, CMD_TMPL+48
    movl $1, %ebx
    movl $CMD_TMPL, %esi
    call io_cmd_irq
    testl %eax, %eax
    jnz io_fail
    cmpl $0, poll_last
    jne io_fail
    movl $1, a3

    jmp report

io_fail:
    movl $msg_io, %esi
    call puts
    incl fail
    jmp report

/* ----------------------------------------------------------------- */
q_bad:
    movl $msg_q, %esi
    call puts
    incl fail
    jmp report

/* io_cmd_irq: %ebx = qid (1), %esi -> 64-byte command.  Submits the
 * command, bounds its wait for the ISR (irq_seen), and - on timeout -
 * falls back to polling the CQ.  Sets poll_last env for the caller and
 * returns eax = CQ status (0 = ok).  Clobbers eax..edi. */
io_cmd_irq:
    /* copy the 64-byte command into SQ1 */
    movl sq_head, %ecx
    shll $6, %ecx
    addl $SQ1, %ecx
    movl %esi, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    /* advance SQ tail, ring SQ1TDBL */
    movl sq_head, %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, sq_head
    /* reset the ISR flag before the doorbell so a completion IRQ that
     * races the submit is not cleared by a late flag reset (which would
     * misreport a normal completion as a lost interrupt) */
    movl $0, irq_seen
    movl bar0, %eax
    movl %ecx, NVME_SQTDBL+8(%eax)   /* SQ1TDBL (stride 8: SQ1 at +8) */
    movl $IRQ_TIMEOUT, %edi
2:  cmpl $1, irq_seen
    je 3f
    decl %edi
    jnz 2b
    /* lost interrupt: fall back to polling */
    movl $1, poll_last
    incl poll_total
    jmp 4f
3:  movl $0, poll_last
4:  /* consume the CQ1 entry (poll until the phase bit is set) */
    movl $CQ_TIMEOUT, %edi
5:  movl cq_head, %ecx
    shll $4, %ecx
    movl $CQ1, %edx
    addl %ecx, %edx
    movzwl 14(%edx), %eax
    testb $1, %al
    jnz 6f
    decl %edi
    jnz 5b
    movl $msg_cq, %esi
    call puts
    movl $1, %eax                /* completion never landed */
    ret
6:  movl %eax, %ebx              /* CQ status (with phase); keep qid safe */
    movl cq_head, %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, cq_head
    movl bar0, %eax
    movl %ecx, NVME_CQHDBL+8(%eax)   /* CQ1HDBL (stride 8) */
    movl %ebx, %eax
    shrl $1, %eax                /* status */
    incl irq_total
    ret

/* clr_cmd: zero the 64-byte command template. */
clr_cmd:
    movl $CMD_TMPL, %edi
    movl $16, %ecx
1:  movl $0, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    ret

/* admin_cmd: esi -> 64-byte command; returns eax = status (0 = ok),
 * result dword in adm_res.  Clobbers eax, ecx, edx, esi, edi, ebp. */
admin_cmd:
    cli                          /* mask completions around the submit */
    movl admin_tail, %ecx
    shll $6, %ecx
    addl $ASQ_ADDR, %ecx
    movl %esi, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    movl admin_tail, %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, admin_tail
    movl bar0, %eax
    movl %ecx, NVME_SQTDBL(%eax)
    movl $100000000, %ebp
1:  movl admin_head, %ecx
    shll $4, %ecx
    movl $ACQ_ADDR, %eax
    movzwl 14(%eax,%ecx), %edx
    testb $1, %dl
    jnz 2f
    decl %ebp
    jnz 1b
    movl $msg_acq, %esi
    call puts
    incl fail
    sti
    movl $1, %eax
    ret
2:  movl $ACQ_ADDR, %eax
    movl 0(%eax,%ecx), %eax
    movl %eax, adm_res
    movl admin_head, %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, admin_head
    movl bar0, %eax
    movl %ecx, NVME_CQHDBL(%eax)
    sti
    movl %edx, %eax
    shrl $1, %eax
    ret

/* -------- low-level helpers (copied from nvmetest.S) --------- */
pcicfg:
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

pcicfg_write:
    movl %eax, %esi
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

/* irq_common: the NVMe completion ISR - set irq_seen, EOI. */
irq_common:
    pushal
    movl $1, irq_seen
    movl $LAPIC, %eax
    movl $0, 0xb0(%eax)          /* EOI */
    popal
    iret

dummy_isr:
    iret

/* report: print the result line, then halt */
report:
    movl $msg_nintr, %esi
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
    movl $sp_i, %esi
    call puts
    movl irq_total, %eax
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

/* ----------------------------------------------------------------- */
    .bss
    .balign 16
fail:       .long 0
nvme_dev:   .long 0
bar0:       .long 0
msix_cap:   .long 0
msix_table: .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
irq_seen:   .long 0
poll_last:  .long 0
irq_total:  .long 0
poll_total: .long 0
sq_head:    .long 0
cq_head:    .long 0
admin_tail: .long 0
admin_head: .long 0
adm_res:    .long 0

    .data
idt_desc:
    .word 256*8 - 1
    .long IDT_BASE

msg_nodev: .asciz "NVME: no device\n"
msg_msix:  .asciz "NVME: no MSI-X\n"
msg_rdy:   .asciz "NVME: no RDY\n"
msg_q:     .asciz "NVME: queue\n"
msg_io:    .asciz "NVME: io\n"
msg_cq:    .asciz "NVME: cq\n"
msg_acq:   .asciz "NVME: acq\n"
msg_path:  .asciz "NVME: wrong interrupt path\n"
msg_nintr: .asciz "NINTR"
sp_a1:     .asciz " a1="
sp_a2:     .asciz " a2="
sp_a3:     .asciz " a3="
sp_i:      .asciz " i="
sp_p:      .asciz " p="
sp_f:      .asciz " f="
nl:        .asciz "\n"
