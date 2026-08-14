/* SPDX-License-Identifier: BSD-2-Clause */

/* usbintr.S - freestanding multiboot test for: completion /
 * interrupt-loss on the xHCI path, with the polling fallback a real
 * driver performs.
 *
 * A minimal xHCI driver (32-bit addressing, event ring, IDT + PIC)
 * drives the STOCK qemu-xhci (1b36:000d, p3=0) with one composite
 * usb-nto64 (two 64-byte bulk echo functions).  Unlike
 * harnesses, this one runs the xHCI with device interrupts ENABLED:
 * it brings the device up with INTE=0 (polling), then enables the
 * INTx line (PIC-unmasked IRQ from config 0x3C) and proves:
 *
 *   a1 - composite bring-up (slot, address, config, bulk pair parsed);
 *   a2 - two interrupt-driven phases complete with the data verified
 *        (a 64-byte bulk OUT latch + bulk IN echo read-back);
 *   a3 - 0 = every completion arrived via the ISR; 1 = the armed
 *        interrupt was LOST (qemu-xhci,nto64-msix-drop=1) - the
 *        driver's bounded ISR wait timed out, it fell back to polling
 *        the event ring, found the completion, and interrupt delivery
 *        resumed on the next transfer (the hook is one-shot).
 *
 * The device hook: with `nto64-msix-drop=N` the Nth deliverable
 * interrupt raise is suppressed - the completion EVENT still lands in
 * the event ring and IMAN_IP / ERDP_EHB stay set, but no INTx/MSI is
 * raised.  That is the interrupt-loss shape: a driver that trusts the
 * interrupt stalls; one that bounds its wait and polls recovers.
 *
 * Prints 'USB-INTR a1=... a2=... a3=... f=...' and halts.  Machine:
 * -machine pc -m 64, -device qemu-xhci,p3=0[,nto64-msix-drop=1]
 * plus -device usb-nto64,composite=on on root port 1 (see the
 * Makefile run-usbintr* targets).  Specs: xHCI 1.1 (4.8.3 event
 * ring, 5.3.2/5.3.4 interrupt enable, 5.5.2.3.1 ERDP EHB), USB 2.0.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

/* --- xHCI register / TRB constants (xHCI 1.1) ---- */
#define XHCI_VID        0x1b36
#define XHCI_DID        0x000d

#define CAP_CAPLENGTH   0x00
#define CAP_HCSPARAMS1  0x04
#define CAP_HCCPARAMS1  0x10
#define CAP_DBOFF       0x14
#define CAP_RTSOFF      0x18

#define OP_USBCMD       0x00
#define OP_USBSTS       0x04
#define OP_CRCR         0x18
#define OP_DCBAAP       0x30
#define OP_CONFIG       0x38
#define OP_PORTSC(n)    (0x400 + ((n) - 1) * 0x10)

#define RT_IR0          0x20
#define RT_ERSTSZ       0x08
#define RT_ERSTBA       0x10
#define RT_ERDP         0x18

#define USBCMD_RS       0x01
#define USBCMD_HCRST    0x02
#define USBCMD_INTE     0x04
#define USBSTS_HCH      0x01
#define USBSTS_CNR      0x800

#define IMAN_IP         0x01
#define IMAN_IE         0x02
/* xHCI 5.5.2.3.1: ERDP bit 3 = Event Handler Busy; a driver writes
 * 1 there when advancing ERDP to clear it, so the next event raises
 * the interrupt again. */
#define ERDP_EHB        0x08

#define PORT_CCS        0x01
#define PORT_PED        0x02
#define PORT_PR         0x10
#define PORT_PP         0x200
#define PORT_SPEED_MASK 0x3c00
#define PORT_SPEED_FULL 0x400
#define PORT_SPEED_HIGH 0xc00
#define PORT_CSC        0x20000
#define PORT_PEC        0x40000
#define PORT_PRC        0x200000

#define TRB_NORMAL      1
#define TRB_SETUP       2
#define TRB_DATA        3
#define TRB_STATUS      4
#define TRB_LINK        6
#define TRB_ENABLE_SLOT 9
#define TRB_ADDRESS_DEV 11
#define TRB_CONFIGURE_EP 12
#define TRB_EV_TRANSFER 32
#define TRB_EV_CMD_COMP 33

#define CC_SUCCESS      1
#define CC_SHORT_PACKET 13

/* ring geometry (same as: 64 TRBs + Link, never wraps) */
#define RING_TRBS       64
#define RING_BYTES      0x410
#define RING_LINK       0x400

/* event ring: 64 TRBs, single segment */
#define EV_TRBS         64
#define EV_BYTES        (64 * 16)

/* xHCI endpoint types */
#define EP_BULK_OUT     2
#define EP_BULK_IN      6

    .section .text
    .globl _start
_start:
    movl %ebx, mbi_ptr          /* save the multiboot info pointer (EBX) */
    movl $stack_top, %esp
    andl $-16, %esp
    movl $1, dev_port

    /* --- scan for qemu-xhci (1b36:000d) ---- */
    xorl %edi, %edi
scan:
    movl %edi, %ecx
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x000d1b36, %eax
    je found_xhci
scan_next:
    incl %edi
    cmpl $64, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    jmp halt
found_xhci:
    /* enable memory + bus master */
    movl $4, %ecx
    call cfgread32
    orl $0x7, %eax
    movl %eax, %ebp
    movl $4, %ecx
    call cfgwrite32
    /* BAR0 (64-bit MMIO) */
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, xhci_base
    movl $0x14, %ecx
    call cfgread32
    testl %eax, %eax
    jz 1f
    movl $msg_badbar, %esi
    call puts
    jmp halt
1:
    /* PCI interrupt line (assigned by SeaBIOS during POST) */
    movl $0x3c, %ecx
    call cfgread32
    andl $0xff, %eax
    movl %eax, irq_line

    /* --- IDT: default gates + PIT tick + xHCI ISR at the device
     * vector (0x20+irq master, 0x28+irq-8 slave) ---- */
    movl $idt_table, %edi
    movl $default_isr, %eax
    movw %cs, %dx
    movl $256, %ecx
idt_loop:
    movl %eax, %ebx
    movw %bx, 0(%edi)
    movw %dx, 2(%edi)
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %ebx
    movw %bx, 6(%edi)
    addl $8, %edi
    decl %ecx
    jnz idt_loop
    /* vector 0x08: PIT tick counter - SeaBIOS leaves the 8259 at the
     * BIOS vector bases (master IRQ0-7 -> 0x08-0x0f, slave IRQ8-15 ->
     * 0x70-0x77), so the tick gate must sit at 0x08, not 0x20. */
    movl $idt_table + 0x08*8, %edi
    movl $tick_isr, %eax
    call idt_gate
    /* xHCI vector */
    movl irq_line, %eax
    cmpl $8, %eax
    jae 1f
    addl $0x08, %eax
    jmp 2f
1:  subl $8, %eax
    addl $0x70, %eax
2:  shll $3, %eax
    lea idt_table(%eax), %edi
    movl $xhci_isr, %eax
    call idt_gate
    movw $2047, idt_ptr
    movl $idt_table, idt_ptr+2
    lidt idt_ptr

    /* PIT channel 0: rate generator, ~1 ms (reload 1193) */
    movb $0x34, %al
    outb %al, $0x43
    movb $0xa9, %al
    outb %al, $0x40
    movb $0x04, %al
    outb %al, $0x40
    /* unmask IRQ0 only (the xHCI IRQ is unmasked later) */
    movb $0xfe, %al
    outb %al, $0x21
    movb $0xff, %al
    outb %al, $0xa1
    sti

    call xhci_init
    movl %eax, %ebp
    testl %ebp, %ebp
    jz 2f
    movl $msg_init, %esi
    call puts
    jmp halt
2:
    call bringup
    movl %eax, %ebp
    testl %ebp, %ebp
    jnz 3f
    movl $1, a1
    call enable_intr
    call phase_t1
    call phase_t2
    call report
    jmp halt
3:  call fail_phase
    call report
    jmp halt

/* idt_gate: edi = gate, eax = handler (cs in dx from the loop). */
idt_gate:
    movl %eax, %ebx
    movw %bx, 0(%edi)
    movw %dx, 2(%edi)
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %ebx
    movw %bx, 6(%edi)
    ret

/* --- interrupts ---- */
tick_isr:
    pushl %eax
    incl ticks
    movb $0x20, %al
    outb %al, $0x20
    popl %eax
    iret

xhci_isr:
    pushl %eax
    pushl %ecx
    incl isr_count
    /* ack the interrupter first: clearing IMAN_IP deasserts the INTx
     * level, so the PIC stops re-firing the ISR before the main loop
     * drains the event ring */
    movl $(IMAN_IP | IMAN_IE), %eax
    movl $RT_IR0, %ecx
    call rt_write
    popl %ecx
    movb $0x20, %al
    outb %al, $0x20
    outb %al, $0xa0
    popl %eax
    iret

default_isr:
    iret

/* --- controller init (xHCI 4.2) - same as  ---- */
xhci_init:
    movl xhci_base, %eax
    movzbl CAP_CAPLENGTH(%eax), %ecx
    addl %ecx, %eax
    movl %eax, op_base
    movl xhci_base, %eax
    movl CAP_DBOFF(%eax), %ecx
    addl xhci_base, %ecx
    movl %ecx, db_base
    movl xhci_base, %eax
    movl CAP_RTSOFF(%eax), %ecx
    addl xhci_base, %ecx
    movl %ecx, rt_base
    movl xhci_base, %eax
    movl CAP_HCSPARAMS1(%eax), %eax
    movl %eax, %ebx
    andl $0xff, %eax
    movl %eax, maxslots
    movl %ebx, %eax
    shrl $24, %eax
    movl %eax, maxports
    /* event ring state */
    movl $ev_ring_storage, %eax
    movl %eax, ev_ring
    movl $0, ev_off
    movl $1, ev_ccs

    /* HCRST, wait until it self-clears */
    movl $USBCMD_HCRST, %eax
    movl $OP_USBCMD, %ecx
    call op_write
    movl $1000, %ecx
1:  movl $OP_USBCMD, %eax
    call op_read
    testl $USBCMD_HCRST, %eax
    jz 2f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 1b
    movl $1, %eax
    ret
2:  /* wait for CNR = 0 */
    movl $2000, %ecx
3:  movl $OP_USBSTS, %eax
    call op_read
    testl $USBSTS_CNR, %eax
    jz 4f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 3b
    movl $1, %eax
    ret
4:
    call ring_init_all
    movl cmd_ring_state+0, %eax
    orl $1, %eax
    movl $OP_CRCR, %ecx
    call op_write
    movl $0, %eax
    movl $(OP_CRCR + 4), %ecx
    call op_write
    movl $dcbaa, %eax
    movl $OP_DCBAAP, %ecx
    call op_write
    movl $0, %eax
    movl $(OP_DCBAAP + 4), %ecx
    call op_write
    movl maxslots, %eax
    movl $OP_CONFIG, %ecx
    call op_write
    movl ev_ring, %eax
    movl %eax, erst+0
    movl $0, erst+4
    movl $EV_TRBS, erst+8
    movl $0, erst+12
    movl $1, %eax
    movl $RT_IR0, %ecx
    addl $RT_ERSTSZ, %ecx
    call rt_write
    movl ev_ring, %eax
    movl $RT_IR0, %ecx
    addl $RT_ERDP, %ecx
    call rt_write
    movl $0, %eax
    movl $(RT_IR0 + RT_ERDP + 4), %ecx
    call rt_write
    movl $erst, %eax
    movl $RT_IR0, %ecx
    addl $RT_ERSTBA, %ecx
    call rt_write
    movl $0, %eax
    movl $(RT_IR0 + RT_ERSTBA + 4), %ecx
    call rt_write
    movl $USBCMD_RS, %eax
    movl $OP_USBCMD, %ecx
    call op_write
    movl $2000, %ecx
5:  movl $OP_USBSTS, %eax
    call op_read
    testl $USBSTS_HCH, %eax
    jz 6f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 5b
    movl $1, %eax
    ret
6:  xorl %eax, %eax
    ret

/* ring_init_all: command ring + the device's 3 ring slots (EP0 + 2
 * data endpoints). */
ring_init_all:
    movl $cmd_ring_state, %edi
    movl $cmd_ring, %eax
    call ring_init
    movl $0, ring_dev
    xorl %ecx, %ecx
1:  cmpl $3, %ecx
    jae 9f
    pushl %ecx
    call ring_for_dev_ep        /* eax = ring storage, edi = state */
    call ring_init
    popl %ecx
    incl %ecx
    jmp 1b
9:  ret

/* ring_for_dev_ep: dev = ring_dev (0), ep slot = ecx.
 * Returns eax = ring storage base, edi = ring state. */
ring_for_dev_ep:
    movl ring_dev, %eax
    imull $5, %eax, %edx
    addl %ecx, %edx
    imull $12, %edx, %edx
    lea dev_ring_states(%edx), %edi
    movl ring_dev, %eax
    imull $5, %eax, %edx
    addl %ecx, %edx
    imull $RING_BYTES, %edx, %edx
    lea dev_rings(%edx), %eax
    ret

/* ring_init: edi = ring state (base/enq/pcs), eax = ring base.
 * Writes the Link TRB at base+0x100 (TC=1, cycle=1). */
ring_init:
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl $1, 8(%edi)
    addl $RING_LINK, %eax
    movl 0(%edi), %ecx
    movl %ecx, 0(%eax)
    movl $0, 4(%eax)
    movl $0, 8(%eax)
    movl $((1 << 1) | (TRB_LINK << 10) | 1), 12(%eax)
    ret

/* enq_trb: esi = 16-byte TRB template (cycle bit 0), edi = ring state. */
enq_trb:
    movl 4(%edi), %eax
    movl 0(%esi), %ebx
    movl %ebx, 0(%eax)
    movl 4(%esi), %ebx
    movl %ebx, 4(%eax)
    movl 8(%esi), %ebx
    movl %ebx, 8(%eax)
    movl 12(%esi), %ebx
    andl $0xfffffffe, %ebx
    orl 8(%edi), %ebx
    movl %ebx, 12(%eax)
    pushl %eax
    addl $16, %eax
    movl 0(%edi), %ebx
    addl $RING_LINK, %ebx
    cmpl %ebx, %eax
    jne 1f
    movl 0(%edi), %ecx
    addl $RING_LINK, %ecx
    movl 12(%ecx), %ebx
    andl $0xfffffffe, %ebx
    orl 8(%edi), %ebx
    movl %ebx, 12(%ecx)
    movl 8(%edi), %ebx
    xorl $1, %ebx
    movl %ebx, 8(%edi)
    movl 0(%edi), %eax
1:  movl %eax, 4(%edi)
    popl %eax
    ret

/* --- event ring ---- */
ev_get:
    movl ev_ring, %ebx
    addl ev_off, %ebx
    movl 12(%ebx), %ecx
    movl %ecx, %eax
    andl $1, %eax
    movl ev_ccs, %edx
    andl $1, %edx
    cmpl %edx, %eax
    jne 9f
    movl 0(%ebx), %eax
    movl %eax, ev_ptr
    movl 8(%ebx), %eax
    movl %eax, ev_stat
    movl 12(%ebx), %eax
    movl %eax, ev_ctrl
    addl $16, ev_off
    movl ev_off, %eax
    cmpl $EV_BYTES, %eax
    jb 1f
    movl $0, ev_off
    xorl $1, ev_ccs
1:  call ev_erdp_write
    call intr_ack
    clc
    ret
9:  call ev_erdp_write
    stc
    ret

/* intr_ack: clear IMAN_IP (deassert the INTx level) and keep IE set -
 * a real driver acks the interrupter once the event ring is drained,
 * otherwise the level-triggered line re-fires the ISR forever. */
intr_ack:
    pushl %eax
    pushl %ecx
    movl $(IMAN_IP | IMAN_IE), %eax
    movl $RT_IR0, %ecx
    call rt_write
    popl %ecx
    popl %eax
    ret

/* ev_erdp_write: ERDP = next slot with EHB=1 (xHCI 5.5.2.3.1: writing
 * 1 to EHB clears the event-ring busy flag, so the next event raises
 * the interrupt again). */
ev_erdp_write:
    movl ev_ring, %eax
    addl ev_off, %eax
    orl $ERDP_EHB, %eax
    movl rt_base, %ecx
    addl $(RT_IR0 + RT_ERDP), %ecx
    movl %eax, (%ecx)
    movl $0, 4(%ecx)
    ret

/* ev_wait: bounded poll for TRB_EV_TRANSFER at tx_addr.
 * Returns eax = cc (0xffffffff timeout), edx = residual, carry on
 * timeout.  This is the POLLING fallback a driver uses when the
 * completion interrupt is lost. */
ev_wait:
    movl ticks, %eax
    addl %eax, %ecx
    movl %ecx, ev_deadline
1:  call ev_get
    jnc 2f
    movl $1, %ecx
    call wait_ticks
    movl ticks, %eax
    cmpl ev_deadline, %eax
    jae 9f
    jmp 1b
2:  movl ev_ctrl, %eax
    shrl $10, %eax
    andl $0x3f, %eax
    cmpl $TRB_EV_TRANSFER, %eax
    jne 1b
    movl ev_ptr, %eax
    cmpl tx_addr, %eax
    jne 1b
    movl ev_stat, %edx
    andl $0xffffff, %edx
    movl ev_stat, %eax
    shrl $24, %eax
    clc
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    stc
    ret

/* --- commands / transfers ---- */
xhci_cmd:
    movl $cmd_ring_state, %edi
    call enq_trb
    movl %eax, cmd_last
    movl db_base, %ecx
    movl $0, (%ecx)
    movl $1000, %ecx
    movl $TRB_EV_CMD_COMP, ev_expect_type
    movl cmd_last, %eax
    movl %eax, ev_expect_ptr
    /* bounded poll for the command-completion event */
    movl ticks, %eax
    addl %eax, %ecx
    movl %ecx, ev_deadline
1:  call ev_get
    jnc 2f
    movl $1, %ecx
    call wait_ticks
    movl ticks, %eax
    cmpl ev_deadline, %eax
    jae 9f
    jmp 1b
2:  movl ev_ctrl, %eax
    shrl $10, %eax
    andl $0x3f, %eax
    cmpl ev_expect_type, %eax
    jne 1b
    movl ev_ptr, %eax
    cmpl ev_expect_ptr, %eax
    jne 1b
    movl ev_ctrl, %edx
    movl ev_stat, %eax
    shrl $24, %eax
    clc
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    stc
    ret

/* xhci_ctrl: control transfer on EP0.
 * ebx = 8-byte setup, ecx = data ptr (0 = none), edx = data length,
 * esi = data direction (1 = IN, 0 = OUT/none).
 * Returns eax = cc (0xffffffff timeout), edx = residual. */
xhci_ctrl:
    movl %ebx, %ebp
    movl %ecx, ctrl_data
    movl %edx, ctrl_len
    movl %esi, ctrl_dir
    movl $ctrl_trb, %esi
    movl 0(%ebp), %eax
    movl %eax, 0(%esi)
    movl 4(%ebp), %eax
    movl %eax, 4(%esi)
    movl $8, %eax
    movl %eax, 8(%esi)
    movl $0, %eax
    movl ctrl_dir, %edx
    testl %edx, %edx
    jz 1f
    movl $3, %eax
    jmp 2f
1:  movl ctrl_len, %edx
    testl %edx, %edx
    jz 2f
    movl $2, %eax
2:  shll $16, %eax
    orl $(TRB_SETUP << 10), %eax
    orl $(1 << 6), %eax
    movl %eax, 12(%esi)
    movl $0, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    call enq_trb
    movl %eax, status_addr
    movl ctrl_len, %edx
    testl %edx, %edx
    jz 4f
    movl $ctrl_trb2, %esi
    movl ctrl_data, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl ctrl_len, %eax
    movl %eax, 8(%esi)
    movl $0, %eax
    movl ctrl_dir, %edx
    shll $16, %edx
    orl $(TRB_DATA << 10), %edx
    movl %edx, 12(%esi)
    movl $0, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    call enq_trb
4:  movl $ctrl_trb3, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl $0, %eax
    movl ctrl_dir, %edx
    testl %edx, %edx
    jnz 5f
    movl $1, %eax
5:  shll $16, %eax
    orl $(TRB_STATUS << 10), %eax
    orl $(1 << 5), %eax
    movl %eax, 12(%esi)
    movl $0, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    call enq_trb
    movl %eax, status_addr
    movl dev_slot, %eax
    shll $2, %eax
    addl db_base, %eax
    movl $1, (%eax)
    movl $5000, %ecx
    movl $TRB_EV_TRANSFER, ev_expect_type
    movl status_addr, %eax
    movl %eax, ev_expect_ptr
    movl ticks, %eax
    addl %eax, %ecx
    movl %ecx, ev_deadline
6:  call ev_get
    jnc 7f
    movl $1, %ecx
    call wait_ticks
    movl ticks, %eax
    cmpl ev_deadline, %eax
    jae 9f
    jmp 6b
7:  movl ev_ctrl, %eax
    shrl $10, %eax
    andl $0x3f, %eax
    cmpl ev_expect_type, %eax
    jne 6b
    movl ev_ptr, %eax
    cmpl ev_expect_ptr, %eax
    jne 6b
    movl ev_stat, %edx
    andl $0xffffff, %edx
    movl ev_stat, %eax
    shrl $24, %eax
    clc
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    stc
    ret

/* tx_submit: enqueue a data TRB on the endpoint ring for DCI edi and
 * ring the doorbell.  esi = data, ecx = len, ebp = 1 for IN.
 * The completion event is waited for separately (tx_wait). */
tx_submit:
    movl %ecx, tx_len
    movl %ebp, tx_dir
    movl %edi, tx_dci
    /* ring slot for this DCI */
    movl ep_count, %ecx
    movl $0, %edx
    movl tx_dci, %ebp
1:  cmpl %ecx, %edx
    jae 9f
    movl ep_dci(,%edx,4), %eax
    cmpl %ebp, %eax
    jne 2f
    jmp 3f
2:  incl %edx
    jmp 1b
3:  movl ep_ring(,%edx,4), %eax
    movl %eax, tx_ring
    movl $tx_trb, %ebx
    movl %esi, 0(%ebx)
    movl $0, 4(%ebx)
    movl tx_len, %ecx
    movl %ecx, 8(%ebx)
    movl $(TRB_NORMAL << 10), %eax
    orl $(1 << 5), %eax          /* IOC */
    movl %eax, 12(%ebx)
    movl $0, %eax
    addl tx_ring, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    movl $tx_trb, %esi
    call enq_trb
    movl %eax, tx_addr
    movl dev_slot, %eax
    shll $2, %eax
    addl db_base, %eax
    movl tx_dci, %ecx
    movl %ecx, (%eax)
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* tx_wait: bounded poll for the transfer-completion event of the last
 * tx_submit.  Returns eax = cc (0xffffffff timeout). */
tx_wait:
    movl $5000, %ecx
    movl $TRB_EV_TRANSFER, ev_expect_type
    movl tx_addr, %eax
    movl %eax, ev_expect_ptr
    call ev_wait
    ret

/* --- bring-up ---- */
/* portsc helpers: port_used = 1 (the composite's root port) */
portsc_read:
    movl port_used, %eax
    decl %eax
    shll $4, %eax
    addl $0x400, %eax
    call op_read
    ret
portsc_write:
    pushl %eax
    movl port_used, %eax
    decl %eax
    shll $4, %eax
    addl $0x400, %eax
    movl %eax, %ecx
    popl %eax
    call op_write
    ret

/* root_port_reset: reset port_used, wait PRC, return speed
 * (1 full / 2 high, 0 fail). */
root_port_reset:
    movl $PORT_PR, %eax
    call portsc_write
    movl $500, %ecx
1:  call portsc_read
    testl $PORT_PRC, %eax
    jnz 2f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 1b
    xorl %eax, %eax
    ret
2:  movl $(PORT_CSC | PORT_PEC | PORT_PRC), %eax
    call portsc_write
    call portsc_read
    testl $PORT_PED, %eax
    jz 9f
    movl %eax, %ecx
    andl $PORT_SPEED_MASK, %ecx
    cmpl $PORT_SPEED_HIGH, %ecx
    je 3f
    cmpl $PORT_SPEED_FULL, %ecx
    jne 9f
    movl $1, %eax
    ret
3:  movl $2, %eax
    ret
9:  xorl %eax, %eax
    ret

/* bringup: reset root port 1, enable a slot, address the device,
 * read descriptors, configure the endpoints, set config, classify.
 * Returns eax error code (0 ok). */
bringup:
    movl $1, port_used
    call root_port_reset
    testl %eax, %eax
    jz 9f
    movl %eax, dev_speed
    call dev_slot_alloc
    testl %eax, %eax
    jnz 9f
    call dev_address
    testl %eax, %eax
    jnz 9f
    call dev_read_desc
    testl %eax, %eax
    jnz 9f
    call dev_configure
    testl %eax, %eax
    jnz 9f
    call classify_dev
    testl %eax, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* dev_slot_alloc: Enable Slot.  Returns eax = 0 ok. */
dev_slot_alloc:
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl $(TRB_ENABLE_SLOT << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 9f
    movl %edx, %eax
    shrl $24, %eax
    movl %eax, dev_slot
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* dev_address: input context (route 0, root port 1, EP0 maxpkt by
 * speed) + Address Device (BSR=0). */
dev_address:
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    movl $0x3, in_ctx+4           /* A0|A1 */
    movl $(1 << 27), in_ctx+0x20  /* context entries 1, route 0 */
    movl dev_port, %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    movl dev_speed, %eax
    cmpl $2, %eax
    je 1f
    movl $8, %eax
    jmp 2f
1:  movl $64, %eax
2:  shll $16, %eax
    orl $0x26, %eax
    movl %eax, in_ctx+0x44
    movl $0, %eax
    imull $5, %eax, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %ecx
    movl 0(%ecx), %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    movl dev_slot, %eax
    shll $3, %eax
    addl $dcbaa, %eax
    movl $dev_ctxs, %edx
    movl %edx, 0(%eax)
    movl $0, 4(%eax)
    movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl dev_slot, %eax
    shll $24, %eax
    orl $(TRB_ADDRESS_DEV << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* dev_read_desc: device descriptor -> config descriptor -> power
 * check -> SET_CONFIGURATION(1) -> GET_CONFIGURATION. */
dev_read_desc:
    movl $dev_desc_buf, %ecx
    movl $18, %edx
    movl $1, %esi
    movl $setup_gdd, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
1:  movzbl dev_desc_buf, %eax
    cmpl $18, %eax
    jne 9f
    movzbl dev_desc_buf+1, %eax
    cmpl $1, %eax
    jne 9f
    movzbl dev_desc_buf+7, %eax
    movl %eax, dev_maxpkt0
    movl dev_desc_buf+8, %eax
    movl %eax, dev_vidpid
    /* GET_DESCRIPTOR(CONFIG, 9) for wTotalLength */
    movl $cfg_buf, %ecx
    movl $9, %edx
    movl $1, %esi
    movl $setup_gdc9, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    jne 8f
2:  movzwl cfg_buf+2, %eax
    cmpl $256, %eax
    ja 8f
    movl %eax, %edx
    movl $setup_gdc, %ebx
    movw %ax, setup_gdc+6
    movl $cfg_buf, %ecx
    movl $1, %esi
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 3f
    cmpl $CC_SHORT_PACKET, %eax
    jne 8f
3:  call parse_cfg
    testl %eax, %eax
    jnz 8f
    /* bMaxPower byte 8 (x 2 mA) vs the 500 mA budget */
    movzbl cfg_buf+8, %eax
    shll $1, %eax
    cmpl $500, %eax
    ja 8f
    /* SET_CONFIGURATION(1) */
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_sc, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 4f
    cmpl $CC_SHORT_PACKET, %eax
    jne 8f
4:  /* GET_CONFIGURATION == 1 */
    movl $cfg_buf, %ecx
    movl $1, %edx
    movl $1, %esi
    movl $setup_gc, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 5f
    cmpl $CC_SHORT_PACKET, %eax
    jne 8f
5:  movzbl cfg_buf, %eax
    cmpl $1, %eax
    jne 8f
    xorl %eax, %eax
    ret
8:  movl $1, %eax
    ret
9:  movl $1, %eax
    ret

/* parse_cfg: walk cfg_buf; record endpoints (address, type, max
 * packet) with their ring slots. */
parse_cfg:
    movl $0, ep_count
    movl $-1, parse_iface
    movl $0, %edi
    movzwl cfg_buf+2, %esi
1:  cmpl %esi, %edi
    jae 9f
    lea cfg_buf(%edi), %ecx
    movzbl 0(%ecx), %eax
    testl %eax, %eax
    jz 9f
    movl %eax, parse_len
    movzbl 1(%ecx), %eax
    cmpl $4, %eax            /* interface descriptor */
    jne 3f
    movzbl 2(%ecx), %eax
    movl %eax, parse_iface
    jmp 4f
3:  cmpl $5, %eax            /* endpoint descriptor */
    jne 4f
    movl parse_iface, %eax
    cmpl $-1, %eax
    je 4f
    cmpl $0, %eax            /* composite: keep only iface 0's pair */
    jne 4f
    movl ep_count, %eax
    cmpl $4, %eax
    jae 4f
    movl %eax, %ebp
    movzbl 2(%ecx), %eax
    movl %eax, ep_addr(,%ebp,4)
    movzbl 2(%ecx), %eax
    andl $0xf, %eax
    shll $1, %eax
    movzbl 2(%ecx), %ecx
    shrl $7, %ecx
    orl %ecx, %eax
    movl %eax, ep_dci(,%ebp,4)
    movl %ebp, %eax
    incl %eax
    movl %eax, ep_ring(,%ebp,4)
    movl %ebp, %eax
    incl %eax
    movl %eax, ep_count
4:  addl parse_len, %edi
    jmp 1b
9:  xorl %eax, %eax
    ret

/* classify_dev: the composite's iface-0 bulk pair (EP 0x01 OUT / 0x81
 * IN) become bulkout_dci / bulkin_dci.  Returns eax = 0 ok. */
classify_dev:
    movl dev_vidpid, %eax
    cmpl $0x1eeb1234, %eax
    jne 9f
    movl $0, %ecx
1:  movl ep_count, %eax
    cmpl %eax, %ecx
    jae 2f
    movl ep_addr(,%ecx,4), %eax
    cmpl $0x01, %eax
    jne 3f
    movl ep_dci(,%ecx,4), %eax
    movl %eax, bulkout_dci
3:  cmpl $0x81, %eax
    jne 4f
    movl ep_dci(,%ecx,4), %eax
    movl %eax, bulkin_dci
4:  incl %ecx
    jmp 1b
2:  movl bulkout_dci, %eax
    testl %eax, %eax
    jz 9f
    movl bulkin_dci, %eax
    testl %eax, %eax
    jz 9f
    /* keep only the iface-0 pair in the endpoint table, so Configure
     * Endpoint enables exactly DCI 2/3 (ring slots 1/2) */
    movl $2, ep_count
    movl bulkout_dci, %eax
    movl %eax, ep_dci
    movl $1, ep_ring
    movl $0x01, ep_addr
    movl bulkin_dci, %eax
    movl %eax, ep_dci+4
    movl $2, ep_ring+4
    movl $0x81, ep_addr+4
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* dev_configure: Configure Endpoint with EP0 + the recorded data
 * endpoints (add flags A0 + one bit per DCI). */
dev_configure:
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    movl $1, %ebp              /* add flags: A0 */
    movl $0, %edi
1:  movl ep_count, %eax
    cmpl %eax, %edi
    jae 2f
    movl $1, %eax
    movl ep_dci(,%edi,4), %ecx
    shll %cl, %eax
    orl %eax, %ebp
    incl %edi
    jmp 1b
2:  movl %ebp, in_ctx+4
    /* slot ctx: entries = max DCI, route, root port */
    movl $1, %eax
    movl $0, %ecx
3:  movl ep_count, %edx
    cmpl %edx, %ecx
    jae 4f
    movl ep_dci(,%ecx,4), %edx
    cmpl %edx, %eax
    jae 5f
    movl %edx, %eax
5:  incl %ecx
    jmp 3b
4:  shll $27, %eax
    movl dev_route, %ecx
    orl %ecx, %eax
    movl %eax, in_ctx+0x20
    movl dev_port, %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    /* EP0 context */
    movl dev_maxpkt0, %eax
    shll $16, %eax
    orl $0x26, %eax
    movl %eax, in_ctx+0x44
    movl $0, %eax
    imull $5, %eax, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %ecx
    movl 0(%ecx), %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    /* per-endpoint contexts */
    movl $0, %ecx
6:  movl ep_count, %eax
    cmpl %eax, %ecx
    jae 7f
    movl %ecx, parse_ep
    pushl %ecx
    call cfg_ep_ctx
    popl %ecx
    incl %ecx
    jmp 6b
7:  movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl dev_slot, %eax
    shll $24, %eax
    orl $(TRB_CONFIGURE_EP << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* cfg_ep_ctx: fill the input-context endpoint entry for endpoint
 * index parse_ep.  ICI = DCI + 1; type/maxpkt from the record. */
cfg_ep_ctx:
    movl parse_ep, %ecx
    movl ep_dci(,%ecx,4), %edx
    movl %edx, %eax
    incl %eax
    shll $5, %eax
    addl $in_ctx, %eax
    movl %eax, %edi
    movl $0, 0(%edi)
    movl $0, %eax
    /* type: bulk OUT = 2, bulk IN = 6 (from the ep address direction) */
    movl ep_addr(,%ecx,4), %edx
    shrl $7, %edx
    cmpl $1, %edx
    jne 1f
    movl $EP_BULK_IN, %eax
    jmp 2f
1:  movl $EP_BULK_OUT, %eax
2:  shll $3, %eax
    orl $(3 << 1), %eax          /* CErr 3 */
    movl $64, %edx
    shll $16, %edx
    orl %edx, %eax
    movl %eax, 4(%edi)
    movl ep_ring(,%ecx,4), %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edx
    movl 0(%edx), %eax
    orl $1, %eax
    movl %eax, 8(%edi)
    movl $64, %eax
    movl %eax, 16(%edi)
    ret

/* --- interrupt enable ---- */
enable_intr:
    /* PIC: unmask the xHCI IRQ (and the master cascade for slave
     * IRQs); the IDT gate was installed at _start. */
    movl irq_line, %eax
    cmpl $8, %eax
    jae 1f
    movl $0x21, %edx
    inb %dx, %al
    movl irq_line, %ecx
    movb $1, %bl
    shlb %cl, %bl
    notb %bl
    andb %bl, %al
    outb %al, %edx
    jmp 2f
1:  movl irq_line, %ecx
    subl $8, %ecx
    movl $0xa1, %edx
    inb %dx, %al
    movb $1, %bl
    shlb %cl, %bl
    notb %bl
    andb %bl, %al
    outb %al, %edx
    movl $0x21, %edx
    inb %dx, %al
    andb $0xfb, %al             /* cascade: master IRQ2 unmasked */
    outb %al, %edx
2:
    /* xHCI: clear pending IP, enable IE */
    movl $(IMAN_IP | IMAN_IE), %eax
    movl $RT_IR0, %ecx
    call rt_write
    /* USBCMD: INTE=1 */
    movl $OP_USBCMD, %eax
    call op_read
    orl $USBCMD_INTE, %eax
    movl $OP_USBCMD, %ecx
    call op_write
    /* clear EHB: ERDP = ring head with EHB=1 */
    movl ev_ring, %eax
    addl ev_off, %eax
    orl $ERDP_EHB, %eax
    movl rt_base, %ecx
    addl $(RT_IR0 + RT_ERDP), %ecx
    movl %eax, (%ecx)
    movl $0, 4(%ecx)
    ret

/* --- test phases ---- */
phase_t1:
    movl $1, a2
    /* prime: bulk OUT with pattern_a (the device latches it) */
    movl isr_count, %eax
    movl %eax, isr_want
    incl isr_want
    movl $pattern_a, %esi
    movl $64, %ecx
    xorl %ebp, %ebp
    movl bulkout_dci, %edi
    call tx_submit
    testl %eax, %eax
    jnz fail_phase
    /* bounded wait for the completion interrupt */
    movl $2000, %ecx
    call wait_isr
    jnc 1f
    /* no interrupt: the armed raise was lost - poll the event ring */
    movl $1, a3
1:  call tx_wait
    jc fail_phase
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    jne fail_phase
2:  ret

phase_t2:
    /* echo read-back: bulk IN - the interrupt MUST be delivered
     * again (the drop hook is one-shot) */
    movl $2, a2
    movl isr_count, %eax
    movl %eax, isr_want
    incl isr_want
    movl $rw_buf, %esi
    movl $64, %ecx
    movl $1, %ebp
    movl bulkin_dci, %edi
    call tx_submit
    testl %eax, %eax
    jnz fail_phase
    movl $2000, %ecx
    call wait_isr
    jc fail_phase
    call tx_wait
    jc fail_phase
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne fail_phase
1:  call cmp_pattern_a
    testl %eax, %eax
    jnz fail_phase
    ret

cmp_pattern_a:
    movl $pattern_a, %esi
    movl $rw_buf, %edi
    movl $16, %ecx
1:  movl (%esi), %eax
    cmpl (%edi), %eax
    jne 9f
    addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz 1b
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* wait_isr: bounded wait (ecx ticks) until isr_count >= isr_want.
 * Carry on timeout. */
wait_isr:
    movl ticks, %eax
    addl %eax, %ecx
    movl %ecx, ev_deadline
1:  movl isr_count, %eax
    cmpl isr_want, %eax
    jae 2f
    movl $1, %ecx
    call wait_ticks
    movl ticks, %eax
    cmpl ev_deadline, %eax
    jae 9f
    jmp 1b
2:  xorl %eax, %eax
    clc
    ret
9:  movl $0xffffffff, %eax
    stc
    ret

fail_phase:
    movl $1, fail
    ret

/* --- helpers ---- */
op_read:
    addl op_base, %eax
    movl (%eax), %eax
    ret
op_write:
    addl op_base, %ecx
    movl %eax, (%ecx)
    ret
rt_write:
    addl rt_base, %ecx
    movl %eax, (%ecx)
    ret

wait_ticks:
    movl ticks, %eax
    addl %ecx, %eax
    movl %eax, wait_target
1:  movl ticks, %eax
    cmpl wait_target, %eax
    jae 2f
    sti
    hlt
    jmp 1b
2:  ret

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
    movl %eax, %ebp
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $11, %ebx
    orl %ebx, %eax
    movl %ecx, %ebx
    andl $0xfc, %ebx
    orl %ebx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl %ebp, %eax
    movl $0xcfc, %edx
    outl %eax, %edx
    ret

puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %esi
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

report:
    call verify_expect
    movl $msg, %esi
    call puts
    movl a1, %eax
    call puthex
    movl $sp_a2, %esi
    call puts
    movl a2, %eax
    call puthex
    movl $sp_a3, %esi
    call puts
    movl a3, %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    ret

halt:
    cli
1:  hlt
    jmp 1b

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: the A3 phase must match the run config.  Bit 0 of the
 * expected mask means "the armed xHCI interrupt must be lost" (a3=1);
 * otherwise the run is clean (a3=0).  A mismatch increments fail. */
verify_expect:
    call nto64_expect
    movl %eax, %ebx
    testl $1, %ebx
    jnz .Lve_drop
    cmpl $0, a3
    je .Lve_done
    incl fail
    jmp .Lve_done
.Lve_drop:
    cmpl $1, a3
    je .Lve_done
    incl fail
.Lve_done:
    ret

    .bss
    .balign 16
mbi_ptr:    .long 0
xhci_base:  .long 0
op_base:    .long 0
rt_base:    .long 0
db_base:    .long 0
maxslots:   .long 0
maxports:   .long 0
irq_line:   .long 0
port_used:  .space 4
ring_dev:   .long 0
tx_ring:    .long 0
ticks:      .long 0
wait_target:.long 0
ev_deadline:.long 0
isr_count:  .long 0
isr_want:   .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
fail:       .long 0
ev_ring:    .long 0
ev_off:     .long 0
ev_ccs:     .long 0
ev_ptr:     .long 0
ev_stat:    .long 0
ev_ctrl:    .long 0
ev_expect_type: .long 0
ev_expect_ptr:  .long 0
status_addr:.long 0
tx_len:     .long 0
tx_dir:     .long 0
tx_addr:    .long 0
tx_dci:     .long 0
ctrl_data:  .long 0
ctrl_len:   .long 0
ctrl_dir:   .long 0
cmd_last:   .long 0
cmd_ring_state: .long 0, 0, 0
parse_iface:.long 0
parse_len:  .long 0
parse_ep:   .long 0
dev_slot:   .long 0
dev_port:   .space 4
dev_route:  .long 0
dev_speed:  .long 0
dev_maxpkt0:.long 0
dev_vidpid: .long 0
ep_count:   .long 0
ep_addr:    .space 16
ep_dci:     .space 16
ep_ring:    .space 16
bulkout_dci:.long 0
bulkin_dci: .long 0

    .balign 64
dev_ctxs:   .space 1024
dev_ring_states: .space 3 * 12
    .balign 64
dev_rings:  .space 3 * RING_BYTES
    .balign 64
cmd_ring:   .space RING_BYTES
    .balign 64
ev_ring_storage: .space EV_BYTES
    .balign 64
erst:       .space 16
    .balign 64
dcbaa:      .space 65 * 8
    .balign 64
in_ctx:     .space 33 * 32

    .balign 16
tx_trb:     .space 16
cmd_trb:    .space 16
ctrl_trb:   .space 16
ctrl_trb2:  .space 16
ctrl_trb3:  .space 16
dev_desc_buf: .space 32
cfg_buf:    .space 256
rw_buf:     .space 64

    .data
    .balign 16
setup_gdd:  .byte 0x80,0x06,0x00,0x01,0x00,0x00,0x12,0x00
setup_gdc9: .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x09,0x00
setup_gdc:  .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x00,0x00
setup_sc:   .byte 0x00,0x09,0x01,0x00,0x00,0x00,0x00,0x00
setup_gc:   .byte 0x80,0x08,0x00,0x00,0x00,0x00,0x01,0x00
pattern_a:  .fill 16, 4, 0x11111111

    .balign 16
idt_ptr:    .space 6
    .bss
    .balign 16
idt_table:  .space 256*8
stack:      .space 8192
stack_top:

    .section .rodata
msg:        .asciz "USB-INTR a1="
sp_a2:      .asciz " a2="
sp_a3:      .asciz " a3="
sp_f:       .asciz " f="
nl:         .asciz "\n"
msg_nodev:  .asciz "no xhci\n"
msg_badbar: .asciz "bad bar\n"
msg_init:   .asciz "xhci init failed\n"
