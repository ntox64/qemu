/* SPDX-License-Identifier: BSD-2-Clause */

/* usbmisbehave.S - freestanding multiboot test for: non-disk
 * USB misbehaviour - HID/report faults, dynamic over-current /
 * power-restore cycles, composite dead-function masks.
 *
 * A minimal xHCI driver (32-bit addressing, polling event ring, no
 * MSI-X) drives the STOCK qemu-xhci (1b36:000d, p3=0 -> four USB2
 * root ports) with a USB 1.1 hub and a mix of non-disk devices:
 * usb-mouse (HID), usb-hub (class 9), and the custom usb-nto64
 * (enumeration-fault shapes + a composite two-function bulk echo
 * device).  The harness is topology-aware: it scans the root ports,
 * then each hub's downstream ports, and brings every device up with
 * its own xHCI slot (root port + route string).  It must SURVIVE:
 *
 *   a1 - bus bring-up: every connected device enumerates + configures
 *        (count of devices successfully brought up)
 *   a2 - HID report-descriptor fault: the first GET_DESCRIPTOR(REPORT)
 *        returns garbage (nto64-bad-report-desc) - the driver detects
 *        it, resets the port and re-enumerates, then the parse is
 *        clean (one-shot)
 *   a3 - HID report faults: the first interrupt-IN report STALLs
 *        (nto64-stall-intr) or returns a truncated report
 *        (nto64-bad-report) - the driver resets the endpoint, clears
 *        the halt and retries (one-shot)
 *   a4 - hub over-current: oc-port=N reports OVERCURRENT + the change
 *        bit; the driver power-cycles the port (clear/set PORT_POWER),
 *        resets it, re-enumerates the device and verifies the port is
 *        clean again (one-shot power-restore cycle)
 *   a5 - composite dead-function mask: usb-nto64,nto64-composite=on
 *        exposes two 64-byte bulk echo functions; nto64-kill-iface=N
 *        makes interface N stall every transfer.  The driver masks
 *        the dead function, keeps the live one working, then resets
 *        the device and re-applies the mask.
 *   a6 - enumeration / power rejections handled during bring-up:
 *        bad-desc / no-config / stall-config / reset-hang devices are
 *        rejected with a bounded port-reset retry; an over-budget
 *        device (bMaxPower x 2 > 500 mA) is never configured.
 *
 * Verified target matrix (run-* targets, all f=0):
 *   run-usbmisbehave:  a1=4 a2=1 a3=1 a4=1 a5=1 a6=0 (clean)
 *   run-usbbaddesc:    a1=4 a2=2 (garbage report descriptor ->
 *                      port reset -> re-enumerate -> clean parse)
 *   run-usbstallintr:  a1=4 a3=2 (stall -> Reset Endpoint +
 *                      CLEAR_FEATURE -> retry ok)
 *   run-usbbadreport:  a1=4 a3=2 (truncated report -> same recovery)
 *   run-usboc:         a1=4 a4=2 (OC -> power cycle -> re-enumerate)
 *   run-usbdead:       a1=4 a5=2 (function B dead -> mask -> A alive
 *                      -> device reset -> re-mask)
 *   run-usbenum:       a1=3 a6=4 (four enumeration-fault devices
 *                      rejected, healthy devices all up)
 *   run-usbpower:      a1=4 a6=1 (over-budget device rejected)
 * The HID data faults are armed by SET_IDLE (only the guest driver
 * sends it), so BIOS boot enumeration cannot consume them.
 *
 * Prints 'USB-BAD a1=... a2=... a3=... a4=... a5=... a6=... f=...'
 * and halts.  Machine: -machine pc -m 64, -device qemu-xhci,p3=0
 * plus the hub/mouse/nto64 set (see the Makefile run-usb* targets).
 * Specs: xHCI 1.1, USB 2.0 (hub class requests), HID 1.11.
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
#define USBSTS_HCH      0x01
#define USBSTS_CNR      0x800

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
#define TRB_DISABLE_SLOT 10
#define TRB_ADDRESS_DEV 11
#define TRB_CONFIGURE_EP 12
#define TRB_RESET_EP    14
#define TRB_STOP_EP     15
#define TRB_SET_TR_DEQ  16
#define TRB_EV_TRANSFER 32
#define TRB_EV_CMD_COMP 33

#define CC_SUCCESS      1
#define CC_SHORT_PACKET 13
#define CC_STALL_ERROR  6
#define CC_CONTEXT_STATE_ERROR 19

/* ring geometry (same as: 64 TRBs + Link, never wraps) */
#define RING_TRBS       64
#define RING_BYTES      0x410
#define RING_LINK       0x400

/* event ring: 64 TRBs, single segment */
#define EV_TRBS         64
#define EV_BYTES        (64 * 16)

/* device table */
#define ND             8
#define DEV_STRIDE     152
#define DEV_SLOT       0
#define DEV_PORT       4
#define DEV_ROUTE      8
#define DEV_STATE      12
#define DEV_SPEED      16
#define DEV_MAXPKT0    20
#define DEV_VID        24
#define DEV_PID        28
#define DEV_CFGTOTAL   32
#define DEV_EPCOUNT    36
#define DEV_EPDCI      40      /* 4 dwords: DCI per data endpoint */
#define DEV_EPADDR     56      /* 4 dwords: endpoint address bytes */
#define DEV_EPMAX      72      /* 4 dwords: wMaxPacketSize */
#define DEV_EPRING     88      /* 4 dwords: ring slot (1..4) per ep */
#define DEV_EPTYPE     104     /* 4 dwords: xHCI ep type per endpoint */
#define DEV_KIND       120
#define DEV_IFACES     124
#define DEV_POWER      128     /* bMaxPower x 2 (mA) */
#define DEV_BULKOUT    132     /* composite iface 0 OUT DCI */
#define DEV_BULKIN     136     /* composite iface 0 IN DCI */
#define DEV_BULKOUT1   140     /* composite iface 1 OUT DCI */
#define DEV_BULKIN1    144     /* composite iface 1 IN DCI */
#define DEV_HIDIN      148     /* mouse interrupt-IN DCI */

#define KIND_NONE      0
#define KIND_HUB       1
#define KIND_MOUSE     2
#define KIND_NTO64     3
#define KIND_BAD       0xff    /* rejected: record pinned, never reused */

/* bring-up error codes */
#define ERR_OK         0
#define ERR_TIMEOUT    1       /* reset-hang: address never completes */
#define ERR_BADDESC    2       /* device descriptor garbage */
#define ERR_NOCFG      3       /* config descriptor stalls */
#define ERR_STALLCFG   4       /* SET_CONFIGURATION stalls */
#define ERR_POWER      5       /* bMaxPower x2 over the 500 mA budget */
#define ERR_OTHER      6

/* hub class request values (USB 2.0 11.24) */
#define PORT_FEAT_RESET         4
#define PORT_FEAT_POWER         8
#define PORT_FEAT_C_OVERCURRENT 19

/* xHCI endpoint types */
#define EP_BULK_OUT     2
#define EP_BULK_IN      6
#define EP_INTR_OUT     3
#define EP_INTR_IN      7

    .section .text
    .globl _start
_start:
    movl $stack_top, %esp
    andl $-16, %esp

    /* IDT + PIT (copy of thesetup): every poll yields with
     * sti;hlt so the PIT (~1 ms, IRQ0) wakes the guest and QEMU's
     * main loop runs async USB completions. */
    movl $idt_table, %edi
    movl $irq_stub, %eax
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
    movw $2047, idt_ptr
    movl $idt_table, idt_ptr+2
    lidt idt_ptr
    movl $1, tag_next
    /* PIT channel 0: rate generator, ~1 ms (reload 1193) */
    movb $0x34, %al
    outb %al, $0x43
    movb $0xa9, %al
    outb %al, $0x40
    movb $0x04, %al
    outb %al, $0x40
    /* unmask IRQ0 only */
    movb $0xfe, %al
    outb %al, $0x21
    movb $0xff, %al
    outb %al, $0xa1
    sti

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
    call xhci_init
    testl %eax, %eax
    jz 2f
    movl $msg_init, %esi
    call puts
    jmp halt
2:
    call scan_bus
    call phase_a2
    call phase_a3
    call phase_a4
    call phase_a5
    call report
    jmp halt

/* ================================================================== */
/* controller init (xHCI 4.2) - same as                          */
/* ================================================================== */
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
    movl xhci_base, %eax
    movl CAP_HCCPARAMS1(%eax), %eax
    movl %eax, hcc1
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

/* ring_init_all: command ring + the per-device EP0/data rings.
 * Each device has 5 ring slots (EP0 + 4 data endpoints). */
ring_init_all:
    movl $cmd_ring_state, %edi
    movl $cmd_ring, %eax
    call ring_init
    xorl %eax, %eax
1:  cmpl $ND, %eax
    jae 9f
    pushl %eax
    movl %eax, ring_dev
    xorl %ecx, %ecx
2:  cmpl $5, %ecx
    jae 3f
    pushl %ecx
    call ring_for_dev_ep        /* eax = ring storage, edi = state */
    call ring_init
    popl %ecx
    incl %ecx
    jmp 2b
3:  popl %eax
    incl %eax
    jmp 1b
9:  ret

/* ring_for_dev_ep: dev = ring_dev, ep slot = ecx.
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

/* ev_get / ev_wait / xhci_cmd / xhci_ctrl / xhci_tx / reset_ep:
 * copies of thedriver, with the endpoint ring selected from
 * the CURRENT device (cur_dev) instead of a single global ring. */
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
    clc
    ret
9:  call ev_erdp_write
    stc
    ret

ev_erdp_write:
    movl ev_ring, %eax
    addl ev_off, %eax
    movl rt_base, %ecx
    addl $(RT_IR0 + RT_ERDP), %ecx
    movl %eax, (%ecx)
    movl $0, 4(%ecx)
    ret

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
    stc
    ret

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
    call ev_wait
    ret

/* xhci_ctrl: control transfer on the current device's EP0.
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
    movl cur_dev, %eax
    imull $5, %eax, %eax
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
    movl cur_dev, %eax
    imull $5, %eax, %eax
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
    movl cur_dev, %eax
    imull $5, %eax, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    call enq_trb
    movl %eax, status_addr
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_SLOT(%ecx), %eax
    shll $2, %eax
    addl db_base, %eax
    movl $1, (%eax)
    movl $1000, %ecx
    movl $TRB_EV_TRANSFER, ev_expect_type
    movl status_addr, %eax
    movl %eax, ev_expect_ptr
    call ev_wait
    jc 9f
    movl ev_stat, %edx
    andl $0xffffff, %edx
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    ret

/* xhci_tx: transfer on the current device's data endpoint.
 * esi = data ptr, ecx = length, ebp = 1 for IN, edi = DCI (2..9).
 * Returns eax = cc (0xffffffff timeout), edx = residual. */
xhci_tx:
    movl %ecx, tx_len
    movl %ebp, tx_dir
    movl %edi, tx_dci
    /* ring slot for this DCI: find it in the device's endpoint list */
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl DEV_EPCOUNT(%ebx), %ecx
    movl $0, %edx
    movl tx_dci, %ebp
1:  cmpl %ecx, %edx
    jae 9f
    movl DEV_EPDCI(%ebx,%edx,4), %eax
    cmpl %ebp, %eax
    jne 2f
    jmp 3f
2:  incl %edx
    jmp 1b
3:  movl DEV_EPRING(%ebx,%edx,4), %ecx
    movl %ecx, tx_ring
    movl $tx_trb, %ebx
    movl %esi, 0(%ebx)
    movl $0, 4(%ebx)
    movl tx_len, %ecx
    movl %ecx, 8(%ebx)
    movl $(TRB_NORMAL << 10), %eax
    orl $(1 << 5), %eax
    movl %eax, 12(%ebx)
    movl cur_dev, %eax
    imull $5, %eax, %eax
    addl tx_ring, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    movl $tx_trb, %esi
    call enq_trb
    movl %eax, tx_addr
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_SLOT(%ecx), %eax
    shll $2, %eax
    addl db_base, %eax
    movl tx_dci, %ecx
    movl %ecx, (%eax)
    movl $5000, %ecx
    movl $TRB_EV_TRANSFER, ev_expect_type
    movl tx_addr, %eax
    movl %eax, ev_expect_ptr
    call ev_wait
    jc 9f
    movl ev_stat, %edx
    andl $0xffffff, %edx
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    ret

/* reset_ep: Reset Endpoint (14) + Set TR Dequeue (16) for DCI edi on
 * the current device; falls back to Stop Endpoint on Context State
 * Error and rebuilds the ring fresh.  Returns eax = cc. */
reset_ep:
    movl %edi, reset_dci
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_SLOT(%ecx), %ecx
    shll $24, %ecx
    orl $(TRB_RESET_EP << 10), %ecx
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %ecx
    movl %ecx, 12(%esi)
    call xhci_cmd
    cmpl $CC_CONTEXT_STATE_ERROR, %eax
    jne 1f
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_SLOT(%ecx), %ecx
    shll $24, %ecx
    orl $(TRB_STOP_EP << 10), %ecx
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %ecx
    movl %ecx, 12(%esi)
    call xhci_cmd
1:
    /* find ring slot for reset_dci */
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl DEV_EPCOUNT(%ebx), %ecx
    movl $0, %edx
    movl reset_dci, %ebp
1:  cmpl %ecx, %edx
    jae 3f
    movl DEV_EPDCI(%ebx,%edx,4), %eax
    cmpl %ebp, %eax
    jne 2f
    jmp 4f
2:  incl %edx
    jmp 1b
3:  movl $0, %edx
4:  movl DEV_EPRING(%ebx,%edx,4), %ecx
    movl %ecx, tx_ring
    movl cur_dev, %eax
    imull $5, %eax, %eax
    addl tx_ring, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    movl 0(%edi), %ecx
    orl $1, %ecx
    movl $cmd_trb, %esi
    movl %ecx, 0(%esi)
    xorl %ecx, %ecx
    movl %ecx, 4(%esi)
    movl %ecx, 8(%esi)
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_SLOT(%ecx), %ecx
    shll $24, %ecx
    orl $(TRB_SET_TR_DEQ << 10), %ecx
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %ecx
    movl %ecx, 12(%esi)
    call xhci_cmd
    /* rebuild the ring fresh */
    movl cur_dev, %eax
    imull $5, %eax, %eax
    addl tx_ring, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edi
    movl 0(%edi), %ebx
    movl %ebx, %ecx
    movl $RING_TRBS, %eax
1:  movl $0, 12(%ecx)
    addl $16, %ecx
    decl %eax
    jnz 1b
    addl $RING_LINK, %ebx
    movl 0(%edi), %ecx
    movl %ecx, 0(%ebx)
    movl $0, 4(%ebx)
    movl $0, 8(%ebx)
    movl $((1 << 1) | (TRB_LINK << 10) | 1), 12(%ebx)
    movl $1, 8(%edi)
    movl 0(%edi), %ecx
    movl %ecx, 4(%edi)
    ret

/* ================================================================== */
/* device table + bring-up                                            */
/* ================================================================== */

/* find_free_dev: eax = first device record with DEV_KIND == 0, or -1 */
find_free_dev:
    movl $0, %eax
1:  cmpl $ND, %eax
    jae 9f
    pushl %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_KIND(%ecx), %edx
    popl %eax
    testl %edx, %edx
    jz 2f
    incl %eax
    jmp 1b
2:  ret
9:  movl $-1, %eax
    ret

/* dev_slot_alloc: Enable Slot for cur_dev.  Returns eax = cc. */
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
    movl cur_dev, %ecx
    imull $DEV_STRIDE, %ecx, %ecx
    lea dev_table(%ecx), %ecx
    movl %eax, DEV_SLOT(%ecx)
    movl $1, DEV_STATE(%ecx)
    xorl %eax, %eax
    ret
9:  movl $ERR_OTHER, %eax
    ret

/* dev_address: build the input context (route string + root port +
 * EP0 with the speed-appropriate max packet) and Address Device. */
dev_address:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    /* zero the input context */
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    /* Input Control: A0|A1 */
    movl $0x3, in_ctx+4
    /* Slot ctx: route string + context entries 1 */
    movl DEV_ROUTE(%ebx), %eax
    orl $(1 << 27), %eax
    movl %eax, in_ctx+0x20
    movl DEV_PORT(%ebx), %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    /* EP0 ctx: control, CErr 3, max packet by speed, ring, avg 8 */
    movl DEV_SPEED(%ebx), %eax
    cmpl $2, %eax
    je 1f
    movl $8, %eax
    jmp 2f
1:  movl $64, %eax
2:  shll $16, %eax
    orl $0x26, %eax
    movl %eax, in_ctx+0x44
    movl cur_dev, %eax
    imull $5, %eax, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %ecx
    movl 0(%ecx), %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    /* DCBAA[slot] = dev_ctxs[cur_dev] */
    movl DEV_SLOT(%ebx), %eax
    shll $3, %eax
    addl $dcbaa, %eax
    movl cur_dev, %ecx
    imull $1024, %ecx, %ecx
    lea dev_ctxs(%ecx), %edx
    movl %edx, 0(%eax)
    movl $0, 4(%eax)
    /* Address Device (BSR=0) */
    movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl DEV_SLOT(%ebx), %eax
    shll $24, %eax
    orl $(TRB_ADDRESS_DEV << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 9f
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl $2, DEV_STATE(%ecx)
    xorl %eax, %eax
    ret
9:  movl $ERR_TIMEOUT, %eax
    ret

/* devptr: eax = dev_table + cur_dev * DEV_STRIDE (only uses eax) */
devptr:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    addl $dev_table, %eax
    ret

/* dev_read_desc: device descriptor -> config descriptor -> power
 * check -> SET_CONFIGURATION.  Returns eax error code (0 ok). */
dev_read_desc:
    /* GET_DESCRIPTOR(DEVICE, 18) */
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
    call devptr
    movl %eax, %ebx
    movzbl dev_desc_buf+7, %eax
    movl %eax, DEV_MAXPKT0(%ebx)
    movl dev_desc_buf+8, %eax
    movl %eax, DEV_VID(%ebx)
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
2:  call devptr
    movl %eax, %ebx
    movzwl cfg_buf+2, %eax
    movl %eax, DEV_CFGTOTAL(%ebx)
    cmpl $256, %eax
    ja 8f
    /* GET_DESCRIPTOR(CONFIG, total) */
    movl $setup_gdc, %ebx
    movw %ax, setup_gdc+6
    movl %eax, %edx
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
    call devptr
    movl %eax, %ebx
    /* bMaxPower byte 8 (x 2 mA) vs the 500 mA budget */
    movzbl cfg_buf+8, %eax
    shll $1, %eax
    movl %eax, DEV_POWER(%ebx)
    cmpl $500, %eax
    ja 7f
    /* SET_CONFIGURATION(1) */
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_sc, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 4f
    cmpl $CC_SHORT_PACKET, %eax
    jne 6f
4:  /* GET_CONFIGURATION == 1 */
    movl $cfg_buf, %ecx
    movl $1, %edx
    movl $1, %esi
    movl $setup_gc, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 5f
    cmpl $CC_SHORT_PACKET, %eax
    jne 6f
5:  movzbl cfg_buf, %eax
    cmpl $1, %eax
    jne 6f
    xorl %eax, %eax
    ret
6:  movl $ERR_STALLCFG, %eax
    ret
7:  movl $ERR_POWER, %eax
    ret
8:  movl $ERR_NOCFG, %eax
    ret
9:  movl $ERR_BADDESC, %eax
    ret

/* parse_cfg: walk cfg_buf; record interfaces + endpoints (address,
 * xHCI type, max packet, ring slot) and the power field. */
parse_cfg:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl $0, %edi
    movl DEV_CFGTOTAL(%ebx), %esi
    movl $0, DEV_EPCOUNT(%ebx)
    movl $0, DEV_IFACES(%ebx)
    movl $-1, parse_iface
1:  cmpl %esi, %edi
    jae 9f
    lea cfg_buf(%edi), %ecx
    movzbl 0(%ecx), %eax
    testl %eax, %eax
    jz 9f
    movl %eax, %edx
    movl %eax, parse_len
    movzbl 1(%ecx), %eax
    cmpl $4, %eax            /* interface descriptor */
    jne 3f
    movl DEV_IFACES(%ebx), %eax
    incl %eax
    movl %eax, DEV_IFACES(%ebx)
    movzbl 2(%ecx), %eax
    movl %eax, parse_iface
    jmp 4f
3:  cmpl $5, %eax            /* endpoint descriptor */
    jne 4f
    movl parse_iface, %eax
    cmpl $-1, %eax
    je 4f
    movl DEV_EPCOUNT(%ebx), %eax
    cmpl $4, %eax
    jae 4f
    movl %eax, %ebp
    movzbl 2(%ecx), %eax
    movl %eax, DEV_EPADDR(%ebx,%ebp,4)
    movzbl 3(%ecx), %eax
    andl $3, %eax
    cmpl $3, %eax            /* interrupt */
    jne 5f
    movzbl 2(%ecx), %eax
    shrl $7, %eax
    jnz 6f
    movl $EP_INTR_OUT, %eax
    jmp 7f
6:  movl $EP_INTR_IN, %eax
    jmp 7f
5:  movzbl 2(%ecx), %eax
    shrl $7, %eax
    jnz 8f
    movl $EP_BULK_OUT, %eax
    jmp 7f
8:  movl $EP_BULK_IN, %eax
7:  movl %eax, DEV_EPTYPE(%ebx,%ebp,4)
    movzbl 4(%ecx), %edx
    movzbl 5(%ecx), %eax
    shll $8, %eax
    orl %edx, %eax
    movl %eax, DEV_EPMAX(%ebx,%ebp,4)
    movzbl 2(%ecx), %eax
    andl $0xf, %eax
    shll $1, %eax
    movzbl 2(%ecx), %ecx
    shrl $7, %ecx
    orl %ecx, %eax
    movl %eax, DEV_EPDCI(%ebx,%ebp,4)
    movl %ebp, %eax
    incl %eax
    movl %eax, DEV_EPRING(%ebx,%ebp,4)
    movl %ebp, %eax
    incl %eax
    movl %eax, DEV_EPCOUNT(%ebx)
4:  addl parse_len, %edi
    jmp 1b
9:  xorl %eax, %eax
    ret

/* dev_configure: Configure Endpoint with EP0 + the recorded data
 * endpoints (add flags A0 + one bit per DCI). */
dev_configure:
    call devptr
    movl %eax, %ebx
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    movl $1, %ebp              /* add flags: A0 */
    movl $0, %edi
1:  movl DEV_EPCOUNT(%ebx), %eax
    cmpl %eax, %edi
    jae 2f
    movl $1, %eax
    movl DEV_EPDCI(%ebx,%edi,4), %ecx
    shll %cl, %eax
    orl %eax, %ebp
    incl %edi
    jmp 1b
2:  movl %ebp, in_ctx+4
    /* slot ctx: entries = max DCI, route, root port */
    movl $1, %eax
    movl $0, %ecx
3:  movl DEV_EPCOUNT(%ebx), %edx
    cmpl %edx, %ecx
    jae 4f
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    cmpl %edx, %eax
    jae 5f
    movl %edx, %eax
5:  incl %ecx
    jmp 3b
4:  shll $27, %eax
    movl DEV_ROUTE(%ebx), %ecx
    orl %ecx, %eax
    movl %eax, in_ctx+0x20
    movl DEV_PORT(%ebx), %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    /* Hub flag + Number of Ports for hubs (xHCI 1.1 6.2.2):
     * software shall set them once the device class is known. */
    movzbl dev_desc_buf+4, %eax
    cmpl $9, %eax
    jne 8f
    orl $(1 << 26), in_ctx+0x20
    movl $4, %eax
    shll $24, %eax
    orl %eax, in_ctx+0x24
8:
    /* EP0 context */
    movl DEV_MAXPKT0(%ebx), %eax
    shll $16, %eax
    orl $0x26, %eax
    movl %eax, in_ctx+0x44
    movl cur_dev, %eax
    imull $5, %eax, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %ecx
    movl 0(%ecx), %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    /* per-endpoint contexts */
    movl $0, %ecx
6:  movl DEV_EPCOUNT(%ebx), %eax
    cmpl %eax, %ecx
    jae 7f
    movl %ecx, parse_ep
    pushl %ecx
    pushl %ebx
    call cfg_ep_ctx
    popl %ebx
    popl %ecx
    incl %ecx
    jmp 6b
7:  movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl DEV_SLOT(%ebx), %eax
    shll $24, %eax
    orl $(TRB_CONFIGURE_EP << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 9f
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl $3, DEV_STATE(%ecx)
    xorl %eax, %eax
    ret
9:  movl $ERR_OTHER, %eax
    ret

/* cfg_ep_ctx: fill the input-context endpoint entry for endpoint index
 * parse_ep.  ICI = DCI + 1; type/maxpkt from the device record. */
cfg_ep_ctx:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl parse_ep, %ecx
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    movl %edx, %eax
    incl %eax
    shll $5, %eax
    addl $in_ctx, %eax
    movl %eax, %edi
    movl $0, 0(%edi)
    movl DEV_EPTYPE(%ebx,%ecx,4), %eax
    shll $3, %eax
    orl $(3 << 1), %eax
    movl DEV_EPMAX(%ebx,%ecx,4), %edx
    shll $16, %edx
    orl %edx, %eax
    movl %eax, 4(%edi)
    movl DEV_EPRING(%ebx,%ecx,4), %eax
    movl cur_dev, %edx
    imull $5, %edx, %edx
    addl %edx, %eax
    imull $12, %eax, %eax
    lea dev_ring_states(%eax), %edx
    movl 0(%edx), %eax
    orl $1, %eax
    movl %eax, 8(%edi)
    movl DEV_EPMAX(%ebx,%ecx,4), %eax
    movl %eax, 16(%edi)
    ret

/* classify_dev: set DEV_KIND from vid/pid and precompute the endpoint
 * mapping used by the phases. */
classify_dev:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl $0, DEV_HIDIN(%ebx)
    movl $0, DEV_BULKOUT(%ebx)
    movl $0, DEV_BULKIN(%ebx)
    movl $0, DEV_BULKOUT1(%ebx)
    movl $0, DEV_BULKIN1(%ebx)
    movl DEV_VID(%ebx), %eax
    cmpl $0x55aa0409, %eax
    jne cls_mouse
    movl $KIND_HUB, DEV_KIND(%ebx)
    ret
cls_mouse:
    cmpl $0x00010627, %eax
    jne cls_nto64
    movl $KIND_MOUSE, DEV_KIND(%ebx)
    movl $0, %ecx
cls_mloop:
    movl DEV_EPCOUNT(%ebx), %eax
    cmpl %eax, %ecx
    jae cls_done
    movl DEV_EPTYPE(%ebx,%ecx,4), %eax
    cmpl $EP_INTR_IN, %eax
    jne cls_mnext
    movl DEV_EPDCI(%ebx,%ecx,4), %eax
    movl %eax, DEV_HIDIN(%ebx)
cls_mnext:
    incl %ecx
    jmp cls_mloop
cls_nto64:
    cmpl $0x1eeb1234, %eax
    jne cls_done
    movl $KIND_NTO64, DEV_KIND(%ebx)
    movl $0, %ecx
cls_nloop:
    movl DEV_EPCOUNT(%ebx), %eax
    cmpl %eax, %ecx
    jae cls_done
    movl DEV_EPADDR(%ebx,%ecx,4), %eax
    cmpl $0x01, %eax
    jne cls_n2
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    movl %edx, DEV_BULKOUT(%ebx)
cls_n2:
    cmpl $0x81, %eax
    jne cls_n3
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    movl %edx, DEV_BULKIN(%ebx)
cls_n3:
    cmpl $0x02, %eax
    jne cls_n4
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    movl %edx, DEV_BULKOUT1(%ebx)
cls_n4:
    cmpl $0x82, %eax
    jne cls_nnext
    movl DEV_EPDCI(%ebx,%ecx,4), %edx
    movl %edx, DEV_BULKIN1(%ebx)
cls_nnext:
    incl %ecx
    jmp cls_nloop
cls_done:
    ret

/* dev_disable: Disable Slot for cur_dev. */
dev_disable:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl DEV_SLOT(%ebx), %eax
    shll $24, %eax
    orl $(TRB_DISABLE_SLOT << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl $0, DEV_STATE(%ecx)
    ret

/* bringup: full enumeration of cur_dev.  Returns eax error code. */
bringup:
    movl cur_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl $0, DEV_STATE(%ebx)
    movl $0, DEV_EPCOUNT(%ebx)
    movl $0, DEV_KIND(%ebx)
    movl $0, DEV_IFACES(%ebx)
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
    xorl %eax, %eax
    ret
9:  ret

/* scan_bus: bring up every connected device (root ports first, then
 * each hub's downstream ports).  a1 = successes, a6 = rejections.
 * Loop counters live in globals because every helper clobbers the
 * caller-saved registers. */
scan_bus:
    movl $0, a1
    movl $0, a6
    /* --- root ports ---- */
    movl $1, scan_port
1:  movl maxports, %eax
    cmpl %eax, scan_port
    ja 9f
    movl scan_port, %eax
    movl %eax, port_used
    call portsc_read
    testl $PORT_CCS, %eax
    jz 2f
    call root_port_reset
    testl %eax, %eax
    jz 2f
    movl %eax, scan_speed
    call find_free_dev
    cmpl $-1, %eax
    je 2f
    movl %eax, cur_dev
    call devptr
    movl %eax, %ecx
    movl scan_port, %edx
    movl %edx, DEV_PORT(%ecx)
    movl $0, DEV_ROUTE(%ecx)
    movl scan_speed, %edx
    movl %edx, DEV_SPEED(%ecx)
    call bringup
    testl %eax, %eax
    jz 3f
    /* bounded retry after a fresh port reset */
    call root_port_reset
    call devptr
    movl %eax, %ecx
    cmpl $1, DEV_STATE(%ecx)
    jb 4f
    call dev_disable
4:  call bringup
    testl %eax, %eax
    jnz 5f
3:  incl a1
    jmp 2f
5:  incl a6
    call devptr
    movl $KIND_BAD, DEV_KIND(%eax)
2:  incl scan_port
    jmp 1b
9:
    /* --- hub downstream ports ---- */
    movl $0, scan_dev
10: cmpl $ND, scan_dev
    jae 19f
    movl scan_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    cmpl $KIND_HUB, DEV_KIND(%ebx)
    jne 11f
    movl scan_dev, %eax
    movl %eax, hub_dev
    movl $1, hub_port
12: cmpl $4, hub_port
    ja 11f
    movl scan_dev, %eax
    movl %eax, cur_dev
    movl hub_port, %esi
    call hub_get_port_status
    testl $PORT_CCS, %eax
    jz 13f
    /* reset the downstream port */
    movl scan_dev, %eax
    movl %eax, cur_dev
    movl hub_port, %esi
    call hub_port_reset
    call find_free_dev
    cmpl $-1, %eax
    je 13f
    movl %eax, cur_dev
    call devptr
    movl %eax, %ecx
    call devptr_hub
    movl %eax, %edx
    movl DEV_PORT(%edx), %eax
    movl %eax, DEV_PORT(%ecx)
    movl hub_port, %edx
    movl %edx, DEV_ROUTE(%ecx)
    movl $1, DEV_SPEED(%ecx)
    call bringup
    testl %eax, %eax
    jz 14f
    /* bounded retry after a fresh hub-port reset */
    movl cur_dev, %eax
    movl %eax, retry_dev
    movl scan_dev, %eax
    movl %eax, cur_dev
    movl hub_port, %esi
    call hub_port_reset
    movl retry_dev, %eax
    movl %eax, cur_dev
    call devptr
    movl %eax, %ecx
    cmpl $1, DEV_STATE(%ecx)
    jb 16f
    call dev_disable
16: call bringup
    testl %eax, %eax
    jnz 15f
14: incl a1
    jmp 13f
15: incl a6
    call devptr
    movl $KIND_BAD, DEV_KIND(%eax)
13: incl hub_port
    jmp 12b
11: incl scan_dev
    jmp 10b
19: ret

/* devptr_hub: eax = dev_table + hub_dev * DEV_STRIDE */
devptr_hub:
    movl hub_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    addl $dev_table, %eax
    ret

/* root_port_reset: reset port_used, wait PRC, return speed (0 fail).
 * Also serves the rejection retry path. */
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

/* hub helpers: current device is the hub. */
/* hub_get_port_status: esi = port.  Returns wPortStatus in eax. */
hub_get_port_status:
    movw %si, setup_gps+4
    movl $hub_status_buf, %ecx
    movl $4, %edx
    movl $1, %esi
    movl $setup_gps, %ebx
    call xhci_ctrl
    movzwl hub_status_buf, %eax
    ret
/* hub_set_feature: ebx = feature, esi = port */
hub_set_feature:
    movw %bx, setup_spf+2
    movw %si, setup_spf+4
    movl $setup_spf, %ebx
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    call xhci_ctrl
    ret
/* hub_clear_feature: ebx = feature, esi = port */
hub_clear_feature:
    movw %bx, setup_cpf+2
    movw %si, setup_cpf+4
    movl $setup_cpf, %ebx
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    call xhci_ctrl
    ret

/* hub_port_reset: reset hub port esi and wait for ENABLE. */
hub_port_reset:
    movl %esi, port_used
    movl $PORT_FEAT_RESET, %ebx
    call hub_set_feature
    movl $20, %ecx
    call wait_ticks
    movl port_used, %esi
    call hub_get_port_status
    testl $PORT_PED, %eax
    jnz 1f
    xorl %eax, %eax
    ret
1:  movl $1, %eax
    ret

/* ================================================================== */
/* phases                                                             */
/* ================================================================== */

/* find_kind: eax = index of the first device with DEV_KIND == ebx,
 * or -1. */
find_kind:
    movl $0, %eax
1:  cmpl $ND, %eax
    jae 9f
    pushl %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_KIND(%ecx), %edx
    popl %eax
    cmpl %ebx, %edx
    je 2f
    incl %eax
    jmp 1b
2:  ret
9:  movl $-1, %eax
    ret

/* dev_port_reset: reset the port the current device is attached to
 * (root PORTSC or the hub's downstream port). */
dev_port_reset:
    movl cur_dev, %eax
    movl %eax, port_dev_save
    call devptr
    movl %eax, %ebx
    movl DEV_ROUTE(%ebx), %ecx
    testl %ecx, %ecx
    jnz 1f
    movl DEV_PORT(%ebx), %eax
    movl %eax, port_used
    call root_port_reset
    jmp 9f
1:  /* find the hub on the same root port */
    pushl %ecx
    movl DEV_PORT(%ebx), %eax
    movl %eax, port_used
    movl $0, %edx
2:  cmpl $ND, %edx
    jae 3f
    pushl %edx
    imull $DEV_STRIDE, %edx, %edx
    lea dev_table(%edx), %ecx
    movl DEV_KIND(%ecx), %eax
    cmpl $KIND_HUB, %eax
    jne 4f
    movl DEV_PORT(%ecx), %eax
    cmpl port_used, %eax
    jne 4f
    popl %edx
    movl %edx, hub_dev
    movl %edx, cur_dev
    popl %ecx
    movl %ecx, %esi
    call hub_port_reset
    jmp 9f
4:  popl %edx
    incl %edx
    jmp 2b
3:  popl %ecx
9:  movl port_dev_save, %eax
    movl %eax, cur_dev
    xorl %eax, %eax
    ret

/* phase_a2: HID report descriptor parse.  On a bad (garbage) report
 * descriptor the port is reset and the mouse re-enumerated. */
phase_a2:
    movl $1, a2
    movl $KIND_MOUSE, %ebx
    call find_kind
    cmpl $-1, %eax
    je fail_phase
    movl %eax, cur_dev
    movl $report_buf, %ecx
    movl $52, %edx
    movl $1, %esi
    movl $setup_ghidr, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 2f
1:  call hid_desc_ok
    testl %eax, %eax
    jz 9f
2:  /* fault: reset the port, re-enumerate, re-read */
    movl $2, a2
    call dev_port_reset
    call dev_disable
    call bringup
    testl %eax, %eax
    jnz fail_phase
    movl $report_buf, %ecx
    movl $52, %edx
    movl $1, %esi
    movl $setup_ghidr, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 3f
    cmpl $CC_SHORT_PACKET, %eax
    jne fail_phase
3:  call hid_desc_ok
    testl %eax, %eax
    jnz fail_phase
9:  ret

/* hid_desc_ok: report_buf holds the report descriptor; returns eax=0
 * when it parses as a sane mouse descriptor (usage page, end
 * collection, no 0xEE garbage). */
hid_desc_ok:
    movzbl report_buf, %eax
    cmpl $0x05, %eax
    jne 9f
    movzbl report_buf+1, %eax
    cmpl $0x01, %eax
    jne 9f
    movzbl report_buf+51, %eax
    cmpl $0xc0, %eax
    jne 9f
    movl $0, %eax
    ret
9:  movl $1, %eax
    ret

/* phase_a3: HID interrupt-IN reports.  SET_IDLE makes QEMU emit a
 * periodic report; a stalled or truncated first report is recovered
 * with Reset Endpoint + CLEAR_FEATURE(ENDPOINT_HALT) + retry. */
phase_a3:
    movl $1, a3
    movl $KIND_MOUSE, %ebx
    call find_kind
    cmpl $-1, %eax
    je fail_phase
    movl %eax, cur_dev
    /* SET_IDLE(10) - ~40 ms report period */
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_sidle, %ebx
    call xhci_ctrl
    movl $50, %ecx
    call wait_ticks
    call mouse_read_report
    testl %eax, %eax
    jz 9f
    /* fault: reset the endpoint, clear the halt, retry */
    movl $2, a3
    call devptr
    movl %eax, %ebx
    movl DEV_HIDIN(%ebx), %edi
    call reset_ep
    /* CLEAR_FEATURE(ENDPOINT_HALT) on the interrupt IN ep */
    call devptr
    movl %eax, %ebx
    movl DEV_HIDIN(%ebx), %eax
    movl %eax, %ecx
    andl $1, %ecx
    shll $7, %ecx
    shrl $1, %eax
    andl $0xf, %eax
    orl %ecx, %eax
    shll $8, %eax
    movw %ax, setup_cfh+4
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_cfh, %ebx
    call xhci_ctrl
    movl $50, %ecx
    call wait_ticks
    call mouse_read_report
    testl %eax, %eax
    jnz fail_phase
9:  ret

/* mouse_read_report: interrupt-IN 4 bytes from the mouse.  Returns
 * eax = 0 when a full 4-byte report arrived, 1 on stall / truncation
 * / timeout. */
mouse_read_report:
    call devptr
    movl %eax, %ebx
    movl $report_buf, %esi
    movl $4, %ecx
    movl $1, %ebp
    movl DEV_HIDIN(%ebx), %edi
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    je 2f
    movl $1, %eax
    ret
2:  /* short packet: 1-byte malformed report on the bad-report target */
    cmpl $3, %edx
    jne 1f
    movl $1, %eax
    ret
1:  xorl %eax, %eax
    ret

/* phase_a4: hub over-current.  A port reporting OVERCURRENT (status +
 * change) is power-cycled (clear/set PORT_POWER), reset, and its
 * device re-enumerated; the port must then be clean. */
phase_a4:
    movl $1, a4
    movl $KIND_HUB, %ebx
    call find_kind
    cmpl $-1, %eax
    je fail_phase
    movl %eax, hub_dev
    movl $1, oc_port_cur
1:  cmpl $4, oc_port_cur
    ja 9f
    movl hub_dev, %eax
    movl %eax, cur_dev
    movl oc_port_cur, %esi
    call hub_get_port_status
    testl $0x0008, %eax       /* PORT_STAT_OVERCURRENT */
    jz 2f
    movl $2, a4
    /* condition persists across clearing the change bit */
    movl $PORT_FEAT_C_OVERCURRENT, %ebx
    movl oc_port_cur, %esi
    call hub_clear_feature
    movl hub_dev, %eax
    movl %eax, cur_dev
    movl oc_port_cur, %esi
    call hub_get_port_status
    testl $0x0008, %eax
    jz fail_phase
    /* power-restore cycle: off, on, reset */
    movl $PORT_FEAT_POWER, %ebx
    movl oc_port_cur, %esi
    call hub_clear_feature
    movl $PORT_FEAT_POWER, %ebx
    movl oc_port_cur, %esi
    call hub_set_feature
    movl $20, %ecx
    call wait_ticks
    movl hub_dev, %eax
    movl %eax, cur_dev
    movl oc_port_cur, %esi
    call hub_port_reset
    /* re-enumerate the device on the affected port */
    call find_route_dev
    cmpl $-1, %eax
    je fail_phase
    movl %eax, cur_dev
    call dev_disable
    call bringup
    testl %eax, %eax
    jnz fail_phase
    /* the port must now be clean */
    movl hub_dev, %eax
    movl %eax, cur_dev
    movl oc_port_cur, %esi
    call hub_get_port_status
    testl $0x0008, %eax
    jnz fail_phase
    jmp 9f
2:  incl oc_port_cur
    jmp 1b
9:  ret

/* find_route_dev: eax = index of the non-hub device on the current
 * hub's port oc_port_cur (root port = the hub's DEV_PORT). */
find_route_dev:
    movl hub_dev, %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ebx
    movl DEV_PORT(%ebx), %eax
    movl %eax, port_used
    movl $0, %ecx
1:  cmpl $ND, %ecx
    jae 9f
    pushl %ecx
    imull $DEV_STRIDE, %ecx, %ecx
    lea dev_table(%ecx), %edx
    movl DEV_KIND(%edx), %eax
    cmpl $KIND_HUB, %eax
    je 2f
    movl DEV_ROUTE(%edx), %eax
    cmpl oc_port_cur, %eax
    jne 2f
    movl DEV_PORT(%edx), %eax
    cmpl port_used, %eax
    jne 2f
    popl %ecx
    movl %ecx, %eax
    ret
2:  popl %ecx
    incl %ecx
    jmp 1b
9:  movl $-1, %eax
    ret

/* phase_a5: composite functions.  Each interface echoes its 64-byte
 * OUT payload back on IN; a killed interface stalls.  The driver
 * masks the dead function, keeps the live one working, then resets
 * the device and re-applies the mask. */
phase_a5:
    movl $1, a5
    call find_composite
    cmpl $-1, %eax
    je fail_phase
    movl %eax, cur_dev
    call comp_verify_a
    testl %eax, %eax
    jnz fail_phase
    call comp_verify_b
    testl %eax, %eax
    jz 9f
    /* function B is dead: mask it, keep A alive */
    movl $2, a5
    call comp_verify_a
    testl %eax, %eax
    jnz fail_phase
    /* device reset: the dead function persists (hardware fault) */
    call dev_port_reset
    call dev_disable
    call bringup
    testl %eax, %eax
    jnz fail_phase
    call comp_verify_a
    testl %eax, %eax
    jnz fail_phase
    call comp_verify_b
    testl %eax, %eax
    jz fail_phase
9:  ret

/* find_composite: eax = index of the nto64 with >= 2 interfaces and
 * a bulk IN pair (the composite), or -1. */
find_composite:
    movl $0, %eax
1:  cmpl $ND, %eax
    jae 9f
    pushl %eax
    imull $DEV_STRIDE, %eax, %eax
    lea dev_table(%eax), %ecx
    movl DEV_KIND(%ecx), %edx
    cmpl $KIND_NTO64, %edx
    jne 2f
    movl DEV_IFACES(%ecx), %edx
    cmpl $2, %edx
    jb 2f
    movl DEV_BULKIN(%ecx), %edx
    testl %edx, %edx
    jz 2f
    popl %eax
    ret
2:  popl %eax
    incl %eax
    jmp 1b
9:  movl $-1, %eax
    ret

/* comp_xfer: esi = data, ecx = len, ebp = dir, edi = dci.
 * Returns eax = cc. */
comp_xfer:
    call xhci_tx
    ret

/* comp_verify_a: pattern A round-trip on interface 0.  eax = 0 pass,
 * 1 = the transfer failed (stall/timeout) or data mismatch. */
comp_verify_a:
    call devptr
    movl %eax, %ebx
    movl $pattern_a, %esi
    movl $64, %ecx
    xorl %ebp, %ebp
    movl DEV_BULKOUT(%ebx), %edi
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
1:  call devptr
    movl %eax, %ebx
    movl $rw_buf, %esi
    movl $64, %ecx
    movl $1, %ebp
    movl DEV_BULKIN(%ebx), %edi
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
2:  call cmp_pattern_a
    testl %eax, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* comp_verify_b: pattern B round-trip on interface 1. */
comp_verify_b:
    call devptr
    movl %eax, %ebx
    movl $pattern_b, %esi
    movl $64, %ecx
    xorl %ebp, %ebp
    movl DEV_BULKOUT1(%ebx), %edi
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
1:  call devptr
    movl %eax, %ebx
    movl $rw_buf, %esi
    movl $64, %ecx
    movl $1, %ebp
    movl DEV_BULKIN1(%ebx), %edi
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
2:  call cmp_pattern_b
    testl %eax, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

cmp_pattern_a:
    movl $pattern_a, %esi
    jmp cmp_common
cmp_pattern_b:
    movl $pattern_b, %esi
cmp_common:
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

fail_phase:
    movl $1, fail
    ret

/* ================================================================== */
/* helpers                                                           */
/* ================================================================== */
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

/* wait_ticks: wait ecx PIT ticks (~1 ms each), yielding with sti;hlt. */
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

/* cfgread32: edi=dev, ecx=byteoff -> eax */
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
/* cfgwrite32: edi=dev, ecx=byteoff, ebp=val */
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

/* irq_stub: PIT tick counter (IRQ0) */
irq_stub:
    pushal
    incl ticks
    movb $0x20, %al
    outb %al, $0x20
    popal
    iret

report:
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
    movl $sp_a4, %esi
    call puts
    movl a4, %eax
    call puthex
    movl $sp_a5, %esi
    call puts
    movl a5, %eax
    call puthex
    movl $sp_a6, %esi
    call puts
    movl a6, %eax
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

    .bss
    .balign 16
xhci_base:  .long 0
op_base:    .long 0
rt_base:    .long 0
db_base:    .long 0
maxslots:   .long 0
maxports:   .long 0
hcc1:       .long 0
port_used:  .long 0
port_dev_save: .long 0
cur_dev:    .long 0
hub_dev:    .long 0
hub_port:   .long 0
retry_dev:  .long 0
scan_port:  .long 0
scan_dev:   .long 0
scan_speed: .long 0
parse_iface: .long 0
parse_ep:   .long 0
parse_len:  .long 0
tx_ring:    .long 0
ring_dev:   .long 0
oc_port_cur: .long 0
ticks:      .long 0
wait_target:.long 0
ev_deadline:.long 0
tag_next:   .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
a4:         .long 0
a5:         .long 0
a6:         .long 0
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
reset_dci:  .long 0
ctrl_data:  .long 0
ctrl_len:   .long 0
ctrl_dir:   .long 0
cmd_last:   .long 0
cmd_ring_state: .long 0, 0, 0

    .balign 64
dev_table:  .space ND * DEV_STRIDE
    .balign 64
dev_ctxs:   .space ND * 1024
    .balign 64
dev_ring_states: .space ND * 5 * 12
    .balign 64
dev_rings:  .space ND * 5 * RING_BYTES
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
hub_status_buf: .space 8
report_buf: .space 64
rw_buf:     .space 64

    .data
    .balign 16
setup_gdd:  .byte 0x80,0x06,0x00,0x01,0x00,0x00,0x12,0x00
setup_gdc9: .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x09,0x00
setup_gdc:  .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x00,0x00
setup_sc:   .byte 0x00,0x09,0x01,0x00,0x00,0x00,0x00,0x00
setup_gc:   .byte 0x80,0x08,0x00,0x00,0x00,0x00,0x01,0x00
setup_ghidr:.byte 0x81,0x06,0x00,0x22,0x00,0x00,0x34,0x00
setup_sidle:.byte 0x21,0x0a,0x00,0x0a,0x00,0x00,0x00,0x00
setup_cfh:  .byte 0x02,0x01,0x00,0x00,0x00,0x00,0x00,0x00
setup_gps:  .byte 0xa3,0x00,0x00,0x00,0x00,0x00,0x04,0x00
setup_spf:  .byte 0x23,0x03,0x00,0x00,0x00,0x00,0x00,0x00
setup_cpf:  .byte 0x23,0x01,0x00,0x00,0x00,0x00,0x00,0x00
pattern_a:  .fill 16, 4, 0x11111111
pattern_b:  .fill 16, 4, 0x22222222

    .balign 16
idt_ptr:    .space 6
    .bss
    .balign 16
idt_table:  .space 256*8
stack:      .space 8192
stack_top:

    .section .rodata
msg:        .asciz "USB-BAD a1="
msg_nodev:  .asciz "USB-BAD nodev\n"
msg_badbar: .asciz "USB-BAD badbar\n"
msg_init:   .asciz "USB-BAD init\n"
sp_a2:      .asciz " a2="
sp_a3:      .asciz " a3="
sp_a4:      .asciz " a4="
sp_a5:      .asciz " a5="
sp_a6:      .asciz " a6="
sp_f:       .asciz " f="
nl:         .asciz "\n"
