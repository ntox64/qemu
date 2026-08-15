/* SPDX-License-Identifier: BSD-2-Clause */

/* usbfault.S - freestanding multiboot test for: xHCI +
 * USB-UAS/USB-storage fault injection.
 *
 * A minimal xHCI driver (32-bit addressing, polling event ring, no
 * MSI-X) drives the STOCK qemu-xhci (1b36:000d) with one USB mass
 * storage device attached: either usb-storage (Bulk-Only Transport,
 * bInterfaceProtocol 0x50) or usb-uas (USB Attached SCSI, 0x62).  The
 * harness parses the descriptors, configures the device, and runs the
 * storage fault matrix plus USB-protocol fault shapes:
 *   a1 - bring-up: TEST UNIT READY + write/read round-trip on sector 0
 *   a2 - bad-track: a transient EIO read (blkdebug once at sector
 *        1000) fails once and a bounded retry recovers the data
 *   a3 - sudden backend errors: EIO write (2000), ENOSPC write (3000),
 *        EIO read (4000) - each recovered by a bounded retry
 *   a4 - persistent write error until the condition clears: writes to
 *        sector 7000 keep failing until a SYNCHRONIZE CACHE (the
 *        driver's recovery action) clears the blkdebug state
 *   a5 - USB-protocol fault: BOT data-phase STALL (usb-storage
 *        nto64-stall-lba=8000) recovered via BOT reset recovery
 *        (Reset Endpoint or Stop Endpoint + Set TR Dequeue + ring
 *        rebuild + CLEAR_FEATURE + Bulk-Only Mass Storage Reset);
 *        UAS RESPONSE IU with INVALID INFORMATION UNIT (usb-uas
 *        nto64-bad-iu-lba=8000) recovered by a retry
 *   a6 - dropped completion: BOT CSW never sent (nto64-drop-lba=7500)
 *        timed out and recovered via the same BOT reset recovery; UAS
 *        COMMAND IU never answered (nto64-drop-tag=0x1234) timed out
 *        and recovered via a TMF ABORT_TASK (whose RESPONSE drains the
 *        pending status read) and a retry with the same tag.
 *
 * Specs verified against (local corpus): xHCI 1.1
 * (extensible-host-controler-interface-usb-xhci.pdf) and UAS-3
 * (uas3r02.pdf).  QEMU simplifications the harness tolerates but real
 * hardware requires are called out in HANDOVER (e.g. no USBLEGSUP
 * BIOS-ownership capability, no event-ring Link TRB needed, 32-byte
 * contexts with CSZ=0).
 *
 * Per-attempt counters: a1=1 (clean), a2=2 on the bad-track target,
 * a3=6 on the error target, a4=2 on the persist target (one failed
 * write, one after the flush), a5=2 on the stall/bad-iu targets,
 * a6=2 on the drop targets - and 1 on the clean targets.
 *
 * Machine: -machine pc -m 64, -device qemu-xhci,p3=0 + one storage
 * device on a blkdebug-instrumented 4M raw image.  Build: `make
 * usbfault`, run: one of the `make run-usbstorage*` / `make run-ua*`
 * targets.  Prints 'USB-FAULT t=... a1=... a2=... a3=... a4=... a5=...
 * a6=... f=00000000' and halts.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

/* --- xHCI register / TRB constants (from the xHCI 1.1 spec) ---- */
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
#define PORT_SPEED_SUPER 0x1000
#define PORT_CSC        0x20000
#define PORT_PEC        0x40000
#define PORT_PRC        0x200000

#define TRB_NORMAL      1
#define TRB_ISOCH       1
#define TRB_SETUP       2
#define TRB_DATA        3
#define TRB_STATUS      4
#define TRB_LINK        6
#define TRB_ENABLE_SLOT 9
#define TRB_ADDRESS_DEV 11
#define TRB_CONFIGURE_EP 12
#define TRB_RESET_EP    14
#define TRB_SET_TR_DEQ  16
#define TRB_DISABLE_SLOT 10
#define TRB_EV_TRANSFER 32
#define TRB_EV_CMD_COMP 33

#define CC_SUCCESS      1
#define CC_SHORT_PACKET 13
#define CC_STALL_ERROR  6
#define CC_USB_TRANSACTION_ERROR 4
#define CC_CONTEXT_STATE_ERROR 19

#define TRB_TR_IOC      (1 << 5)
#define TRB_TR_SIA      (1 << 31)

/* ring geometry: 64 TRB slots + a Link TRB, 64-byte aligned base.
 * The harness never writes more than ~40 TRBs per endpoint across all
 * phases, so the rings never wrap and the producer cycle state stays
 * stable (no crossing-time toggles to get wrong). */
#define RING_TRBS       64
#define RING_BYTES      0x410          /* 65 * 16 */
#define RING_LINK       0x400

/* event ring: 64 TRBs, single segment */
#define EV_TRBS         64
#define EV_BYTES        (64 * 16)

/* UAS IU ids */
#define IU_COMMAND      0x01
#define IU_SENSE        0x03
#define IU_RESPONSE     0x04
#define IU_TASK         0x05
#define IU_READ_READY   0x06
#define IU_WRITE_READY  0x07

    .section .text
    .globl _start
_start:
    movl $stack_top, %esp
    andl $-16, %esp

    /* --- IDT + PIT: every poll yields with sti;hlt so the PIT
     * (IRQ0, ~1 ms) wakes the guest and QEMU's main loop runs async
     * SCSI completions. ---- */
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
    call xhci_port_setup
    testl %eax, %eax
    jz 3f
    movl $msg_port, %esi
    call puts
    jmp halt
3:
    movl port_used, %eax
    movl %eax, storage_port
    call xhci_slot_address
    testl %eax, %eax
    jz 4f
    movl $msg_addr, %esi
    call puts
    jmp halt
4:
    call xhci_descriptors
    testl %eax, %eax
    jz 5f
    movl $msg_desc, %esi
    call puts
    jmp halt
5:
    call xhci_configure
    testl %eax, %eax
    jz 6f
    movl $msg_cfg, %esi
    call puts
    jmp halt
6:
    /* if the first device is the isoc test device (no mass-storage
     * interface), skip the storage phases and run the isoc phase
     * directly on slot 1 */
    cmpl $0, proto
    jne 7f
    call phase_a10
    call report
    jmp halt
7:
    call run_phases
    call report
    jmp halt

/* ================================================================== */
/* xHCI controller init (spec 4.2: program everything before R/S=1)   */
/* returns eax: 0 ok, 1 fail                                          */
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
    /* command ring: CRCR low (ptr|RCS) then high */
    call ring_init_all
    movl cmd_ring_state+0, %eax
    orl $1, %eax
    movl $OP_CRCR, %ecx
    call op_write
    movl $0, %eax
    movl $(OP_CRCR + 4), %ecx
    call op_write
    /* DCBAAP */
    movl $dcbaa, %eax
    movl $OP_DCBAAP, %ecx
    call op_write
    movl $0, %eax
    movl $(OP_DCBAAP + 4), %ecx
    call op_write
    /* CONFIG: MaxSlotsEn */
    movl maxslots, %eax
    movl $OP_CONFIG, %ecx
    call op_write
    /* event ring: ERST entry, ERSTSZ, ERDP, then ERSTBA (write enables) */
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
    /* R/S = 1 */
    movl $USBCMD_RS, %eax
    movl $OP_USBCMD, %ecx
    call op_write
    /* wait HCH = 0 */
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

/* ring_init_all: builds the command ring, the EP0 ring and the DCI 2..9
 * endpoint rings; each ring gets base/enq/pcs and its Link TRB. */
ring_init_all:
    movl $cmd_ring_state, %edi
    movl $cmd_ring, %eax
    call ring_init
    movl $ep0_ring_state, %edi
    movl $ep0_ring, %eax
    call ring_init
    movl $0, ring_idx
1:  movl $rings, %eax
    movl ring_idx, %ebx
    imull $12, %ebx, %edx
    addl %edx, %eax
    movl %eax, %edi
    movl $ring_trbs, %eax
    movl ring_idx, %ebx
    imull $RING_BYTES, %ebx, %edx
    addl %edx, %eax
    call ring_init
    incl ring_idx
    cmpl $8, ring_idx
    jb 1b
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
    movl $((1 << 1) | (TRB_LINK << 10) | 1), 12(%eax)  /* TC | type | cycle=1 */
    ret

/* enq_trb: esi = 16-byte TRB template (cycle bit 0), edi = ring state.
 * Writes it at the enqueue slot with the ring's cycle, advances the
 * enqueue (crossing the Link TRB toggles the link cycle and the PCS).
 * Returns eax = address of the written TRB. */
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
    /* crossing: link cycle = current pcs, then pcs ^= 1 */
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

/* ev_get: non-blocking event ring read.  Returns CF=0 with the event
 * fields in ev_ptr/ev_stat/ev_ctrl, or CF=1 if the ring is empty.
 * Always keeps ERDP up to date. */
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

/* ev_wait: waits up to ecx ticks for an event matching
 * ev_expect_type/ev_expect_ptr.  Returns eax = completion code
 * (0xffffffff on timeout); edx = ev_ctrl (slot/epid/type). */
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

/* xhci_cmd: esi = 16-byte command TRB template.  Rings the command
 * doorbell and waits for the matching Command Completion Event.
 * Returns eax = cc (0xffffffff timeout); edx = slot id. */
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

/* xhci_ctrl: control transfer on EP0.
 * ebx = 8-byte setup, ecx = data ptr (0 = none), edx = data length,
 * esi = data direction (1 = IN, 0 = OUT/none).
 * Returns eax = cc (0xffffffff timeout), edx = residual. */
xhci_ctrl:
    movl %ebx, %ebp          /* setup */
    movl %ecx, ctrl_data
    movl %edx, ctrl_len
    movl %esi, ctrl_dir
    /* setup TRB */
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
    movl $3, %eax            /* TRT: IN data stage */
    jmp 2f
1:  movl ctrl_len, %edx
    testl %edx, %edx
    jz 2f
    movl $2, %eax            /* TRT: OUT data stage */
2:  shll $16, %eax
    orl $(TRB_SETUP << 10), %eax
    orl $(1 << 6), %eax      /* IDT */
    movl %eax, 12(%esi)
    movl $ep0_ring_state, %edi
    call enq_trb
    movl %eax, status_addr
    /* data TRB */
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
    shll $16, %edx           /* DIR bit 16 */
    orl $(TRB_DATA << 10), %edx
    movl %edx, 12(%esi)
    movl $ep0_ring_state, %edi
    call enq_trb
    /* status TRB: DIR opposite of the data direction */
4:  movl $ctrl_trb3, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl $0, %eax
    movl ctrl_dir, %edx
    testl %edx, %edx
    jnz 5f
    movl $1, %eax            /* no data / OUT data -> status IN */
5:  shll $16, %eax
    orl $(TRB_STATUS << 10), %eax
    orl $(1 << 5), %eax       /* IOC */
    movl %eax, 12(%esi)
    movl $ep0_ring_state, %edi
    call enq_trb
    movl %eax, status_addr
    /* ring doorbell: target 1 (EP0) */
    movl slot_id, %eax
    shll $2, %eax
    addl db_base, %eax
    movl $1, (%eax)
    /* wait for the status TRB event */
    movl $1000, %ecx
    movl $TRB_EV_TRANSFER, ev_expect_type
    movl status_addr, %eax
    movl %eax, ev_expect_ptr
    call ev_wait
    jc 9f
    movl ev_stat, %edx
    andl $0xffffff, %edx      /* residual */
    ret
9:  movl $0xffffffff, %eax
    movl $0xffffffff, %edx
    ret

/* xhci_tx: bulk/transfer TRB.
 * esi = data ptr, ecx = length, edi = DCI (2..9), ebp = 1 for IN.
 * Returns eax = cc (0xffffffff timeout), edx = residual. */
xhci_tx:
    movl %ecx, tx_len
    movl %ebp, tx_dir
    movl %edi, tx_dci
    movl $tx_trb, %ebx
    movl %esi, 0(%ebx)
    movl $0, 4(%ebx)
    movl %ecx, 8(%ebx)
    movl $(TRB_NORMAL << 10), %eax
    orl $(1 << 5), %eax       /* IOC */
    movl %eax, 12(%ebx)
    /* ring state for this DCI */
    movl $rings, %eax
    movl tx_dci, %ecx
    subl $2, %ecx
    imull $12, %ecx, %edx
    addl %edx, %eax
    movl %eax, %edi
    movl $tx_trb, %esi
    call enq_trb
    movl %eax, tx_addr
    /* doorbell: db[slot] = DCI (the DB Target) */
    movl slot_id, %eax
    shll $2, %eax
    addl db_base, %eax
    movl tx_dci, %ecx
    movl %ecx, (%eax)
    /* wait for the transfer event */
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

/* reset_ep: Reset Endpoint (14) + Set TR Dequeue Pointer (16) for DCI
 * edi (2..9), re-arming the ring at its base with the current PCS and
 * resetting the software enqueue to the base.  Returns eax = cc. */
reset_ep:
    movl %edi, reset_dci
    /* Reset Endpoint command */
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl slot_id, %eax
    shll $24, %eax
    orl $(TRB_RESET_EP << 10), %eax
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %eax            /* Endpoint ID 20:16 = DCI */
    movl %eax, 12(%esi)
    call xhci_cmd
    /* If the endpoint is not halted (e.g. a dropped completion left it
     * Running), Reset Endpoint fails with Context State Error - fall
     * back to Stop Endpoint, which cancels the pending transfer. */
    cmpl $CC_CONTEXT_STATE_ERROR, %eax
    jne 1f
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl slot_id, %eax
    shll $24, %eax
    orl $(15 << 10), %eax    /* Stop Endpoint */
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %eax
    movl %eax, 12(%esi)
    call xhci_cmd
1:
    /* Set TR Dequeue Pointer: dequeue = ring base | pcs */
    movl $rings, %eax
    movl reset_dci, %ecx
    subl $2, %ecx
    imull $12, %ecx, %ecx
    addl %ecx, %eax
    movl %eax, %edi
    /* Force the ring to a fresh cycle: Set TR Dequeue with DCS=1. */
    movl 0(%edi), %ecx
    orl $1, %ecx
    movl $cmd_trb, %esi
    movl %ecx, 0(%esi)
    xorl %ecx, %ecx
    movl %ecx, 4(%esi)
    movl %ecx, 8(%esi)
    movl slot_id, %ecx
    shll $24, %ecx
    orl $(TRB_SET_TR_DEQ << 10), %ecx
    movl reset_dci, %ebx
    shll $16, %ebx
    orl %ebx, %ecx            /* Endpoint ID 20:16 = DCI */
    movl %ecx, 12(%esi)
    call xhci_cmd
    /* xhci_cmd clobbers edi (it sets the command-ring state); re-arm
     * the endpoint ring state pointer before the rebuild. */
    movl $rings, %eax
    movl reset_dci, %ecx
    subl $2, %ecx
    imull $12, %ecx, %ecx
    addl %ecx, %eax
    movl %eax, %edi
    /* Rebuild the ring: zero all slot control dwords (cycle 0), re-init
     * the Link TRB (TC=1, cycle 1), pcs=1, enq=base.  No stale TRB can
     * match the fresh cycle, so the retry starts clean. */
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
/* port / slot / descriptor / configuration                           */
/* ================================================================== */
xhci_port_setup:
    movl $1, %edi
    movl maxports, %esi
1:  cmpl %esi, %edi
    ja 9f
    movl %edi, %ebx
    movl %ebx, port_used
    call portsc_read
    testl $PORT_CCS, %eax
    jnz 2f
    movl $2, %ecx
    call wait_ticks
    incl %ebx
    movl %ebx, %edi
    jmp 1b
2:  movl %ebx, port_used
    /* reset the port.  USB2: PR -> PRC.  SuperSpeed root ports are
     * already enabled after the link trains (PED set by the
     * controller) - issuing PR would hang waiting for PRC, so skip
     * the reset when PORTSC shows the SS speed bits. */
    movl %ebx, %edi
    call portsc_read
    andl $PORT_SPEED_MASK, %eax
    cmpl $PORT_SPEED_SUPER, %eax
    je 3f
    movl %ebx, %edi
    movl $PORT_PR, %eax
    call portsc_write
    movl $500, %ecx
4:  call portsc_read
    testl $PORT_PRC, %eax
    jnz 4f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 4b
    movl $1, %eax
    ret
4:  /* clear CSC/PEC/PRC */
    movl $(PORT_CSC | PORT_PEC | PORT_PRC), %eax
    call portsc_write
3:  /* read the speed from PORTSC (SS skips the reset path) */
    call portsc_read
    testl $PORT_PED, %eax
    jz 9f
    movl %eax, %ecx
    andl $PORT_SPEED_MASK, %ecx
    cmpl $PORT_SPEED_FULL, %ecx
    je 5f
    cmpl $PORT_SPEED_HIGH, %ecx
    je 5f
    cmpl $PORT_SPEED_SUPER, %ecx
    jne 9f
5:
    shrl $10, %eax
    andl $0xf, %eax
    movl %eax, port_speed
    xorl %eax, %eax
    ret
9:  movl $1, %eax
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

xhci_slot_address:
    /* Enable Slot */
    movl $cmd_trb, %esi
    movl $0, %eax
    movl %eax, 0(%esi)
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl $(TRB_ENABLE_SLOT << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 8f
    movl %edx, %eax
    shrl $24, %eax
    movl %eax, slot_id
    /* zero the input context and device context */
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    movl $dev_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    /* Input Control: A0|A1 */
    movl $0x3, in_ctx+4
    /* Slot ctx: context entries 1, root hub port */
    movl $(1 << 27), in_ctx+0x20
    movl port_used, %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    /* EP0 ctx: control, CErr 3 / 0, max packet by speed, ring, avg 8.
     * SuperSpeed EP0 MPS is the 2^N encoding (9 -> 512) and CErr is
     * 0 for the SS protocol. */
    movl $0x400026, %eax
    cmpl $4, port_speed
    jne 1f
    movl $0x200020, %eax          /* CErr 0, MPS 9<<16 */
1:  movl %eax, in_ctx+0x44
    movl $ep0_ring, %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    /* DCBAA[slot] = dev_ctx */
    movl slot_id, %eax
    shll $3, %eax
    addl $dcbaa, %eax
    movl $dev_ctx, %ecx
    movl %ecx, 0(%eax)
    movl $0, 4(%eax)
    /* Address Device (BSR=0) */
    movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl slot_id, %eax
    shll $24, %eax
    orl $(TRB_ADDRESS_DEV << 10), %eax
    movl %eax, 12(%esi)
    call xhci_cmd
    cmpl $CC_SUCCESS, %eax
    jne 7f
    xorl %eax, %eax
    ret
7:
    movl $1, %eax
    ret
8:
    movl $1, %eax
    ret
9:  movl $1, %eax
    ret

xhci_descriptors:
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
    movzbl dev_desc_buf+7, %eax
    movl %eax, maxpkt0
    /* GET_DESCRIPTOR(CONFIG, 9) for wTotalLength */
    movl $cfg_buf, %ecx
    movl $9, %edx
    movl $1, %esi
    movl $setup_gdc9, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
2:  movzwl cfg_buf+2, %eax
    movl %eax, cfg_total
    cmpl $256, %eax
    ja 9f
    /* GET_DESCRIPTOR(CONFIG, total) */
    movl $setup_gdc, %ebx
    movl cfg_total, %edx
    movw %dx, setup_gdc+6
    movl $cfg_buf, %ecx
    movl $1, %esi
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 3f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
3:
    call parse_cfg
    testl %eax, %eax
    jnz 7f
    /* SET_CONFIGURATION(1) */
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_sc, %ebx
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 4f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
4:  xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret
7:
    movl $1, %eax
    ret

/* parse_cfg: walk the configuration descriptor, record every data
 * endpoint (address, transfer type, max packet, DCI) and classify the
 * device: mass-storage (proto 0x50/0x62, bulk endpoints) or the isoc
 * test device (an isoc IN endpoint, type 1). */
parse_cfg:
    movl $0, %edi            /* offset */
    movl cfg_total, %esi
    movl $0, ep_count
    movl $0, proto
    movl $0, isoc_dci
    movl $0, isoc_max
1:  cmpl %esi, %edi
    jae 9f
    lea cfg_buf(%edi), %ebx
    movzbl 0(%ebx), %eax     /* bLength */
    testl %eax, %eax
    jz 9f
    movl %eax, %edx          /* save bLength */
    movzbl 1(%ebx), %ecx     /* bDescriptorType */
    cmpl $4, %ecx            /* interface descriptor */
    jne 3f
    /* interface descriptor: remember the mass-storage protocol */
    cmpb $0x08, 5(%ebx)      /* bInterfaceClass: mass storage */
    jne 2f
    cmpb $0x06, 6(%ebx)      /* bInterfaceSubClass: SCSI */
    jne 2f
    movzbl 7(%ebx), %eax
    movl %eax, proto
2:  jmp 4f
3:  cmpl $5, %ecx
    jne 4f
    /* endpoint descriptor: record bulk and isoc endpoints */
    movzbl 3(%ebx), %eax
    andl $3, %eax
    testl %eax, %eax
    jz 4f                     /* control endpoints are not data EPs */
    movzbl 2(%ebx), %eax
    movl ep_count, %ecx
    cmpl $4, %ecx
    jae 4f
    movl %eax, ep_addrs(,%ecx,4)
    movl %eax, %ebp
    /* record the transfer type (2 = bulk, 1 = isoc) and max packet */
    movzbl 3(%ebx), %eax
    andl $3, %eax
    movl %eax, ep_types(,%ecx,4)
    movzwl 4(%ebx), %eax
    movl %eax, ep_maxs(,%ecx,4)
    /* DCI = num*2 + dir (OUT=0, IN=1) */
    movl ep_addrs(,%ecx,4), %eax
    andl $0xf, %eax
    shll $1, %eax
    shrl $7, %ebp
    orl %ebp, %eax
    movl %eax, ep_dcis(,%ecx,4)
    incl ep_count
    movl ep_types(,%ecx,4), %eax
    cmpl $1, %eax
    jne 4f
    /* isoc endpoint: remember its DCI and max packet */
    movl ep_dcis(,%ecx,4), %eax
    movl %eax, isoc_dci
    movl ep_maxs(,%ecx,4), %eax
    movl %eax, isoc_max
4:  addl %edx, %edi
    jmp 1b
9:  movl ep_count, %eax
    testl %eax, %eax
    jz parse_cfg_fail
    /* the isoc test device: no mass-storage interface */
    movl proto, %eax
    testl %eax, %eax
    jnz 5f
    movl isoc_dci, %eax
    testl %eax, %eax
    jz parse_cfg_fail
    movl $1, isoc_present
    xorl %eax, %eax
    ret
5:
    /* map endpoints per transport */
    movl proto, %eax
    cmpl $0x50, %eax
    je 6f
    cmpl $0x62, %eax
    jne parse_cfg_fail
    /* UAS: ep[0]=OUT cmd, ep[1]=IN status, ep[2]=IN data-in,
     * ep[3]=OUT data-out */
    movl ep_dcis+0, %eax
    movl %eax, uas_cmd_ep
    movl ep_dcis+4, %eax
    movl %eax, uas_sts_ep
    movl ep_dcis+8, %eax
    movl %eax, uas_din_ep
    movl ep_dcis+12, %eax
    movl %eax, uas_dout_ep
    xorl %eax, %eax
    ret
6:  /* BOT: first bulk IN = data/CSW, first bulk OUT = CBW */
    movl $0, %ecx
7:  cmpl ep_count, %ecx
    jae parse_bot_done
    movl ep_dcis(,%ecx,4), %edx
    testl $1, %edx
    jz 8f
    movl %edx, bin_ep
    movl ep_addrs(,%ecx,4), %edx
    movl %edx, bin_addr
    jmp 9f
8:  movl %edx, bout_ep
    movl ep_addrs(,%ecx,4), %edx
    movl %edx, bout_addr
9:  incl %ecx
    jmp 7b
parse_bot_done:
    xorl %eax, %eax
    ret
parse_cfg_fail:
    movl $1, %eax
    ret

xhci_configure:
    /* zero the input context */
    movl $in_ctx, %edi
    movl $1088, %ecx
    xorl %eax, %eax
    rep stosb
    /* add flags: A0 (slot ctx) + one bit per endpoint DCI.  Per xHCI
     * 4.6.6, A1 (EP0) shall be cleared for Configure Endpoint. */
    movl $1, %ebx
    movl $0, %edi
1:  movl ep_count, %eax
    cmpl %eax, %edi
    jae 2f
    movl $1, %eax
    movl ep_dcis(,%edi,4), %ecx
    shll %cl, %eax
    orl %eax, %ebx
    incl %edi
    jmp 1b
2:  movl %ebx, in_ctx+4
    /* slot ctx: context entries = max DCI, root hub port */
    movl $1, %eax
    movl $0, %ecx
3:  cmpl ep_count, %ecx
    jae 4f
    movl ep_dcis(,%ecx,4), %edx
    cmpl %edx, %eax
    jae 5f
    movl %edx, %eax
5:  incl %ecx
    jmp 3b
4:  shll $27, %eax
    orl %eax, in_ctx+0x20
    movl port_used, %eax
    shll $16, %eax
    movl %eax, in_ctx+0x24
    /* EP0 context (control), MPS by speed */
    movl $0x400026, %eax
    cmpl $4, port_speed
    jne 1f
    movl $0x200020, %eax
1:  movl %eax, in_ctx+0x44
    movl $ep0_ring, %eax
    orl $1, %eax
    movl %eax, in_ctx+0x48
    movl $8, in_ctx+0x50
    /* per-endpoint contexts */
    movl $0, %ecx
6:  cmpl ep_count, %ecx
    jae 7f
    movl ep_dcis(,%ecx,4), %ebx
    pushl %ecx
    call cfg_ep_ctx
    popl %ecx
    incl %ecx
    jmp 6b
7:  /* Configure Endpoint command */
    movl $cmd_trb, %esi
    movl $in_ctx, %eax
    movl %eax, 0(%esi)
    movl $0, %eax
    movl %eax, 4(%esi)
    movl %eax, 8(%esi)
    movl slot_id, %eax
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

/* cfg_ep_ctx: fill the input-context endpoint entry for DCI ebx.
 * ICI = DCI + 1; type/max packet from the parsed descriptor (bulk
 * IN -> 6, bulk OUT -> 2, isoc IN -> 5); TR dequeue = ring base |
 * DCS; avg TRB length = the endpoint's max packet. */
cfg_ep_ctx:
    movl %ebx, %eax
    incl %eax
    shll $5, %eax
    addl $in_ctx, %eax
    movl %eax, %edi
    movl $0, 0(%edi)
    /* find this DCI in the parsed endpoint table */
    movl $0, %ecx
1:  cmpl ep_count, %ecx
    jae 9f
    movl ep_dcis(,%ecx,4), %edx
    cmpl %ebx, %edx
    je 2f
    incl %ecx
    jmp 1b
2:  /* map the descriptor transfer type to the xHCI endpoint type:
     * bulk IN -> 6, bulk OUT -> 2, isoc IN -> 5, isoc OUT -> 1 */
    movl ep_types(,%ecx,4), %eax
    cmpl $1, %eax
    jne 4f
    movl ep_dcis(,%ecx,4), %eax
    andl $1, %eax
    jz 5f
    movl $5, %eax
    jmp 6f
5:  movl $1, %eax
    jmp 6f
4:  movl ep_dcis(,%ecx,4), %eax
    andl $1, %eax
    jz 7f
    movl $6, %eax
    jmp 6f
7:  movl $2, %eax
6:  shll $3, %eax
    orl $(3 << 1), %eax
    movl ep_maxs(,%ecx,4), %edx
    shll $16, %edx
    orl %edx, %eax
    movl %eax, 4(%edi)
    /* preserve the parse-loop index for the avg-TRB-length field */
    movl %ecx, %esi
    /* ring base for this DCI */
    movl %ebx, %eax
    subl $2, %eax
    movl %eax, %ecx
    imull $RING_BYTES, %ecx, %ecx
    addl $ring_trbs, %ecx
    orl $1, %ecx
    movl %ecx, 8(%edi)
    /* avg TRB length: the max packet of this endpoint (esi holds the
     * parse-loop index, preserved across the ring math) */
    movl ep_maxs(,%esi,4), %eax
    movl %eax, 16(%edi)
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* ================================================================== */
/* BOT (Bulk-Only Transport) layer                                    */
/* ================================================================== */
/* bot_cmd: esi = data buf, ecx = data len, ebx = tag, ebp = dir
 * (1=IN), edi = 16-byte CDB.  Runs CBW -> data -> CSW.
 * Returns eax: 0 pass, 1 command failed, 2 stall, 3 timeout. */
bot_cmd:
    movl %esi, cmd_data
    movl %ecx, cmd_len
    movl %ebx, cmd_tag
    movl %ebp, cmd_dir
    movl %edi, cmd_cdb
    /* CBW */
    movl $cbw_buf, %edi
    movl $0x43425355, %eax
    movl %eax, 0(%edi)
    movl cmd_tag, %eax
    movl %eax, 4(%edi)
    movl cmd_len, %eax
    movl %eax, 8(%edi)
    movl $0, %eax
    movl cmd_dir, %eax
    shll $7, %eax
    movl %eax, 12(%edi)
    movl $0, 16(%edi)
    movb $10, 14(%edi)       /* cmd_len 10 (READ/WRITE 10) */
    movl cmd_cdb, %esi
    movl $16, %ecx
    lea 15(%edi), %edi       /* CDB starts at byte 15 */
    rep movsb
    movl $cbw_buf, %esi
    movl $31, %ecx
    movl bout_ep, %edi
    xorl %ebp, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 5f
1:  /* data phase */
    movl cmd_len, %eax
    testl %eax, %eax
    jz 3f
    movl cmd_data, %esi
    movl cmd_len, %ecx
    movl cmd_dir, %ebp
    movl bin_ep, %edi
    testl %ebp, %ebp
    jnz bot_data_tx
    movl bout_ep, %edi
bot_data_tx:
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 3f
    cmpl $CC_SHORT_PACKET, %eax
    je 3f
    cmpl $CC_STALL_ERROR, %eax
    je 6f
    jmp 5f
3:  /* CSW */
    movl $csw_buf, %esi
    movl $16, %ecx
    movl bin_ep, %edi
    movl $1, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 4f
    cmpl $CC_SHORT_PACKET, %eax
    je 4f
    cmpl $CC_STALL_ERROR, %eax
    je 6f
    jmp 5f
4:  /* validate CSW */
    movl csw_buf, %eax
    cmpl $0x53425355, %eax
    jne csw_bad
    movl csw_buf+4, %eax
    cmpl cmd_tag, %eax
    jne csw_bad
    movzbl csw_buf+12, %eax
    testl %eax, %eax
    jnz 2f
    xorl %eax, %eax
    ret
2:  movl $1, %eax
    ret
csw_bad:
5:  movl $3, %eax
    ret
6:  movl $2, %eax
    ret

/* bot_recover: xHCI Reset Endpoint + Set TR Dequeue on the BOT data
 * endpoint, then CLEAR_FEATURE(ENDPOINT_HALT) on both bulk endpoints
 * and a Bulk-Only Mass Storage Reset. */
bot_recover:
    movl bin_ep, %edi
    call reset_ep
    /* CLEAR_FEATURE(ENDPOINT_HALT) on bin */
    movl bin_addr, %eax
    shll $8, %eax
    movw %ax, setup_cfh+4
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_cfh, %ebx
    call xhci_ctrl
    /* on bout */
    movl bout_addr, %eax
    shll $8, %eax
    movw %ax, setup_cfh+4
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_cfh, %ebx
    call xhci_ctrl
    /* Bulk-Only Mass Storage Reset */
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    movl $setup_bmsr, %ebx
    call xhci_ctrl
    ret

/* bot_rw: esi = buf, ebx = lba, ecx = dir (1=read), ebp = tag.
 * Builds a READ/WRITE(10) CDB and runs bot_cmd.  Returns bot status. */
bot_rw:
    movl %esi, cmd_data
    movl %ebx, cmd_lba
    movl %ebp, cmd_tag
    movl $512, cmd_len
    movl %ecx, cmd_dir
    movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movl cmd_dir, %eax
    testl %eax, %eax
    jz 1f
    movb $0x28, 0(%edi)      /* READ(10) */
    jmp 2f
1:  movb $0x2a, 0(%edi)      /* WRITE(10) */
2:  movl cmd_lba, %eax
    movb %al, 5(%edi)
    shrl $8, %eax
    movb %al, 4(%edi)
    shrl $8, %eax
    movb %al, 3(%edi)
    shrl $8, %eax
    movb %al, 2(%edi)
    movb $0, 6(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movb $0, 9(%edi)
    movl cmd_data, %esi
    movl $512, %ecx
    movl cmd_dir, %ebp
    movl $cdb_buf, %edi
    movl cmd_tag, %ebx
    call bot_cmd
    ret

/* bot_tur / bot_sync: TEST UNIT READY / SYNCHRONIZE CACHE(10). */
bot_tur:
    movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movl $0, %esi
    movl $0, %ecx
    movl $1, %ebp
    movl $1, %ebx
    movl $cdb_buf, %edi
    call bot_cmd
    ret
bot_sync:
    movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movb $0x35, 0(%edi)
    movl $0, %esi
    movl $0, %ecx
    movl $0, %ebp
    movl $2, %ebx
    movl $cdb_buf, %edi
    call bot_cmd
    ret

/* ================================================================== */
/* UAS layer                                                         */
/* ================================================================== */
/* uas_cmd: esi = data buf, ecx = data len, ebx = tag, ebp = dir
 * (1=IN), edi = 16-byte CDB.  Runs COMMAND IU -> status/ready ->
 * data -> SENSE IU.  Returns eax: 0 pass, 1 cmd failed, 2 response,
 * 3 timeout. */
uas_cmd:
    movl %esi, cmd_data
    movl %ecx, cmd_len
    movl %ebx, cmd_tag
    movl %ebp, cmd_dir
    movl %edi, cmd_cdb
    /* COMMAND IU (32 bytes) */
    movl $iu_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movl %eax, 16(%edi)
    movl %eax, 20(%edi)
    movl %eax, 24(%edi)
    movl %eax, 28(%edi)
    movb $IU_COMMAND, 0(%edi)
    movl cmd_tag, %eax
    movb %ah, 2(%edi)
    movb %al, 3(%edi)
    movl cmd_cdb, %esi
    movl $16, %ecx
    addl $16, %edi
    rep movsb
    movl $iu_buf, %esi
    movl $32, %ecx
    movl uas_cmd_ep, %edi
    xorl %ebp, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 5f
1:  /* status IN */
    movl $iu_buf, %esi
    movl $64, %ecx
    movl uas_sts_ep, %edi
    movl $1, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 2f
    cmpl $CC_SHORT_PACKET, %eax
    je 2f
    jmp 5f
2:  movzbl iu_buf, %eax
    cmpl $IU_READ_READY, %eax
    je 3f
    cmpl $IU_WRITE_READY, %eax
    je 4f
    cmpl $IU_SENSE, %eax
    je 7f
    cmpl $IU_RESPONSE, %eax
    je 8f
    jmp 5f
3:  /* READ READY: data-in, then status -> SENSE */
    movl cmd_data, %esi
    movl cmd_len, %ecx
    movl uas_din_ep, %edi
    movl $1, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je uas_rd_sts
    cmpl $CC_SHORT_PACKET, %eax
    jne 5f
uas_rd_sts:
    movl $iu_buf, %esi
    movl $64, %ecx
    movl uas_sts_ep, %edi
    movl $1, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 7f
    cmpl $CC_SHORT_PACKET, %eax
    je 7f
    jmp 5f
4:  /* WRITE READY: data-out, then status -> SENSE */
    movl cmd_data, %esi
    movl cmd_len, %ecx
    movl uas_dout_ep, %edi
    xorl %ebp, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je uas_wr_sts
    cmpl $CC_SHORT_PACKET, %eax
    jne 5f
uas_wr_sts:
    movl $iu_buf, %esi
    movl $64, %ecx
    movl uas_sts_ep, %edi
    movl $1, %ebp
    call xhci_tx
    cmpl $CC_SUCCESS, %eax
    je 7f
    cmpl $CC_SHORT_PACKET, %eax
    je 7f
    jmp 5f
7:  /* SENSE IU: status at byte 6 */
    movzbl iu_buf+6, %eax
    testl %eax, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret
8:  movzbl iu_buf+7, %eax     /* RESPONSE code */
    movl $2, %eax
    ret
5:  movl $3, %eax
    ret

/* uas_rw: esi = buf, ebx = lba, ecx = dir (1=read), ebp = tag.
 * Builds a READ/WRITE(10) CDB and runs uas_cmd. */
uas_rw:
    movl %esi, cmd_data
    movl %ebx, cmd_lba
    movl %ebp, cmd_tag
    movl $512, cmd_len
    movl %ecx, cmd_dir
    movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movl cmd_dir, %eax
    testl %eax, %eax
    jz 1f
    movb $0x28, 0(%edi)
    jmp 2f
1:  movb $0x2a, 0(%edi)
2:  movl cmd_lba, %eax
    movb %al, 5(%edi)
    shrl $8, %eax
    movb %al, 4(%edi)
    shrl $8, %eax
    movb %al, 3(%edi)
    shrl $8, %eax
    movb %al, 2(%edi)
    movb $0, 6(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movb $0, 9(%edi)
    movl cmd_data, %esi
    movl $512, %ecx
    movl cmd_dir, %ebp
    movl $cdb_buf, %edi
    movl cmd_tag, %ebx
    call uas_cmd
    ret

/* uas_tmf_abort: TMF ABORT_TASK for the dropped tag.  The RESPONSE IU
 * completes the dropped command's pending status IN, freeing the single
 * USB2 status slot for the retry; no separate status read is needed. */
uas_tmf_abort:
    movl $iu_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movb $IU_TASK, 0(%edi)
    movl cmd_tag, %eax        /* TMF's own tag */
    movb %ah, 2(%edi)
    movb %al, 3(%edi)
    movb $0x01, 4(%edi)       /* ABORT TASK */
    movl cmd_tag, %eax        /* tag of task to be managed */
    movb %ah, 6(%edi)
    movb %al, 7(%edi)
    movl $iu_buf, %esi
    movl $16, %ecx
    movl uas_cmd_ep, %edi
    xorl %ebp, %ebp
    call xhci_tx
    xorl %eax, %eax
    ret

/* ================================================================== */
/* phases                                                            */
/* ================================================================== */
run_phases:
    call phase_a1
    call phase_a2
    call phase_a3
    call phase_a4
    call phase_a5
    call phase_a6
    ret

/* phase_a1: TUR + write/read round-trip on sector 0. */
phase_a1:
    movl $0, %ecx
1:  incl %ecx
    movl %ecx, a1
    call transport_tur
    call pattern_write          /* write sector 0 */
    call pattern_read
    testl %eax, %eax
    jz 2f
    movl $50, %ecx
    call wait_ticks
    movl a1, %ecx
    cmpl $3, %ecx
    jb 1b
    movl $1, fail
2:  ret

/* phase_a2: bad-track read at sector 1000, bounded retry. */
phase_a2:
    call pattern_write_lba1000
    movl $0, %ecx
1:  incl %ecx
    movl %ecx, a2
    call pattern_read_lba1000
    cmpl $0, %eax
    je 2f
    movl $30, %ecx
    call wait_ticks
    movl a2, %ecx
    cmpl $4, %ecx
    jb 1b
    movl $1, fail
2:  ret

/* phase_a3: sudden backend errors: EIO write 2000, ENOSPC write 3000,
 * EIO read 4000 - each recovered by a bounded retry. */
phase_a3:
    /* write 2000 */
    movl $2000, %ebx
    call rw_retry_write
    addl %eax, a3
    /* write 3000 */
    movl $3000, %ebx
    call rw_retry_write
    addl %eax, a3
    /* read 4000 */
    call pattern_write_lba4000
    movl $4000, %ebx
    call rw_retry_read
    addl %eax, a3
    ret

/* phase_a4: persistent write at 7000 until SYNCHRONIZE CACHE clears. */
phase_a4:
    movl $0, %ecx
1:  incl %ecx
    movl %ecx, a4
    movl $7000, %ebx
    call transport_write
    cmpl $0, %eax
    je 2f
    call transport_sync
    movl $30, %ecx
    call wait_ticks
    movl a4, %ecx
    cmpl $4, %ecx
    jb 1b
    movl $1, fail
    ret
2:  /* verify readback */
    movl $7000, %ebx
    call transport_read
    cmpl $0, %eax
    je 3f
    movl $1, fail
3:  ret

/* phase_a5: USB-protocol fault at sector 8000.
 * BOT: data-phase STALL -> BOT reset recovery + retry.
 * UAS: RESPONSE IU (INVALID INFORMATION UNIT) -> retry. */
phase_a5:
    call pattern_write_lba8000
    movl $0, %ecx
1:  incl %ecx
    movl %ecx, a5
    movl $8000, %ebx
    call transport_read
    cmpl $0, %eax
    je 2f
    cmpl $2, %eax
    jne 3f
    /* protocol fault: recover */
    call proto_recover
    movl $30, %ecx
    call wait_ticks
3:  movl a5, %ecx
    cmpl $4, %ecx
    jb 1b
    movl $1, fail
2:  ret

/* phase_a6: dropped completion at sector 7500.
 * BOT: CSW never sent -> timeout -> BOT reset recovery + retry.
 * UAS: COMMAND IU dropped -> timeout -> TMF ABORT_TASK + retry. */
phase_a6:
    call pattern_write_lba9000
    movl $0, %ecx
1:  incl %ecx
    movl %ecx, a6
    movl $7500, %ebx
    call transport_read_drop
    cmpl $0, %eax
    je 2f
    call proto_recover
    movl $30, %ecx
    call wait_ticks
    movl a6, %ecx
    cmpl $4, %ecx
    jb 1b
    movl $1, fail
2:  ret

/* ================================================================== */
/* SuperSpeed + isoc missed-microframe             */
/* ================================================================== */

/* arm_vendor: send a no-data vendor-device-out request (setup in
 * ebx) via EP0.  Returns eax = cc (0xffffffff on timeout); a STALL
 * means the hook is absent on this target (clean phase expected),
 * which arm_ok records as 0 so the caller can branch cleanly. */
arm_vendor:
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    call xhci_ctrl
    cmpl $CC_STALL_ERROR, %eax
    jne 1f
    movl $0, arm_ok
    jmp 2f
1:  movl $1, arm_ok
2:  ret

/* find_isoc_dev: eax = 1 if a SECOND device is present on a root port
 * other than the storage device (the isoc test device). */
find_isoc_dev:
    movl $1, %edi
    movl maxports, %esi
1:  cmpl %esi, %edi
    ja 9f
    movl %edi, %eax
    cmpl storage_port, %eax
    je 2f
    movl %edi, port_used
    call portsc_read
    testl $PORT_CCS, %eax
    jnz 8f
2:  incl %edi
    jmp 1b
8:  movl $1, %eax
    ret
9:  xorl %eax, %eax
    ret

/* xhci_tx_isoc: submit ONE isochronous IN TRB on DCI edi.
 * esi = data buffer, ecx = length.  Returns eax = cc (0xffffffff
 * timeout), edx = residual.  The TRB uses SIA (schedule asap) so the
 * controller services it at the next service interval. */
xhci_tx_isoc:
    movl %ecx, tx_len
    movl %edi, tx_dci
    movl $tx_trb, %ebx
    movl %esi, 0(%ebx)
    movl $0, 4(%ebx)
    movl %ecx, 8(%ebx)
    movl $(TRB_ISOCH << 10), %eax
    orl $TRB_TR_IOC, %eax
    orl $TRB_TR_SIA, %eax
    movl %eax, 12(%ebx)
    movl $rings, %eax
    movl tx_dci, %ecx
    subl $2, %ecx
    imull $12, %ecx, %edx
    addl %edx, %eax
    movl %eax, %edi
    movl $tx_trb, %esi
    call enq_trb
    movl %eax, tx_addr
    movl slot_id, %eax
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

/* get_drop_status: vendor READ (0x58) of the isoc drop-armed flag
 * into drop_status (1 = the missed-microframe is armed on this
 * target, 0 = clean stream).  Returns eax = cc. */
get_drop_status:
    movl $setup_getdrop, %ebx
    movl $drop_armed_buf, %ecx
    movl $1, %edx
    movl $1, %esi
    call xhci_ctrl
    cmpl $CC_SUCCESS, %eax
    je 1f
    cmpl $CC_SHORT_PACKET, %eax
    jne 9f
1:  movzbl drop_armed_buf, %eax
    movl %eax, drop_status
    xorl %eax, %eax
    ret
9:  movl $0xffffffff, %eax
    ret

/* phase_a10: isoc stream + missed-microframe recovery.  Eight isoc IN
 * transfers at 1 ms intervals; the controller services one per
 * interval.  On the drop target (nto64-drop-microframe=1 + vendor
 * 0x57 arm) the armed isoc IN completes SHORT with 0 bytes (the
 * device models the missed service interval as an empty packet), so
 * the driver sees the anomaly as a 0-length completion and must keep
 * the stream going.  The phase counts 0-length completions and fails
 * unless the count matches what the drop-armed status promised
 * (exactly 1 on the drop target, 0 on a clean stream). */
phase_a10:
    movl $1, a10
    /* if the current device is already the isoc device (slot 1,
     * no mass-storage interface), skip the second-device bring-up */
    cmpl $0, proto
    jne 10f
    movl isoc_dci, %edi
    testl %edi, %edi
    jz 8f
    jmp 11f
10:
    call find_isoc_dev
    testl %eax, %eax
    jz 8f                    /* no isoc device: clean target, skip */
    /* drain stale events (port-status changes, storage-phase
     * leftovers) so the control-transfer event ring state matches
     * what the xHCI is writing */
1:  call ev_get
    jc 2f
    jmp 1b
2:
    /* bring up the isoc device on its own root port (the storage
     * device keeps the first connected port) */
    movl $1, %edi
    movl maxports, %esi
1:  cmpl %esi, %edi
    ja 9f
    movl %edi, %eax
    cmpl storage_port, %eax
    je 2f
    movl %edi, port_used
    call portsc_read
    testl $PORT_CCS, %eax
    jnz 3f
2:  incl %edi
    jmp 1b
3:  movl %edi, port_used
    call portsc_read
    testl $PORT_PED, %eax
    jnz 4f
    movl $PORT_PR, %eax
    call portsc_write
    movl $500, %ecx
5:  call portsc_read
    testl $PORT_PRC, %eax
    jnz 4f
    movl $1, %ecx
    call wait_ticks
    decl %ecx
    jnz 5b
    jmp 9f
4:  movl $(PORT_CSC | PORT_PEC | PORT_PRC), %eax
    call portsc_write
    /* the isoc device gets its OWN slot (the storage slot stays
     * enabled); the EP0 ring state is re-initialized so the fresh
     * slot's EP0 starts at the base */
    movl $ep0_ring_state, %edi
    movl $ep0_ring, %eax
    call ring_init
    call xhci_slot_address
    testl %eax, %eax
    jnz 9f
    call xhci_descriptors
    testl %eax, %eax
    jnz 9f
    call xhci_configure
    testl %eax, %eax
    jnz 9f
    movl isoc_dci, %edi
    testl %edi, %edi
    jz 9f
11:
    /* arm the missed-microframe (vendor 0x57; no-op on clean) */
    movl $setup_arm57, %ebx
    call arm_vendor
    /* the drop-armed status right after the arm is the expectation
     * for this target (the flag clears once the drop fires) */
    call get_drop_status
    testl %eax, %eax
    jnz 8f
    movl drop_status, %eax
    movl %eax, isoc_gaps_save
    movl $0, isoc_gaps
    movl $0, isoc_idx
    movl ticks, %eax
    movl %eax, isoc_last
10: movl $isoc_buf, %esi
    movl $64, %ecx
    movl isoc_dci, %edi
    call xhci_tx_isoc
    cmpl $0xffffffff, %eax
    je 8f
    cmpl $CC_SUCCESS, %eax
    je 3f
    cmpl $CC_SHORT_PACKET, %eax
    jne 8f
3:  /* the event length is the RESIDUAL (TRB length - transferred):
     * a full 64-byte completion reports 0, the missed microframe (0
     * bytes transferred) reports the full TRB length */
    testl %edx, %edx
    jz 5f
    incl isoc_gaps
5:  incl isoc_idx
    cmpl $8, isoc_idx
    jb 10b
    /* assert the drop was observed exactly as armed */
    movl isoc_gaps, %eax
    cmpl isoc_gaps_save, %eax
    je 6f
    movl $1, fail
    ret
6:
    movl $2, a10
8:  ret

/* transport dispatch: read/write/tur/sync via BOT or UAS */
transport_write:
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    movl $buf_data, %esi
    xorl %ecx, %ecx
    movl $3, %ebp
    call bot_rw
    ret
1:  movl $buf_data, %esi
    xorl %ecx, %ecx
    movl $5, %ebp
    call uas_rw
    ret
transport_read:
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    movl $buf_data, %esi
    movl $1, %ecx
    movl $4, %ebp
    call bot_rw
    ret
1:  movl $buf_data, %esi
    movl $1, %ecx
    movl $6, %ebp
    call uas_rw
    ret
transport_tur:
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    call bot_tur
    ret
1:  movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movl $0, %esi
    movl $0, %ecx
    movl $0, %ebp
    movl $7, %ebx
    call uas_cmd
    ret
transport_sync:
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    call bot_sync
    ret
1:  movl $cdb_buf, %edi
    movl $0, %eax
    movl %eax, 0(%edi)
    movl %eax, 4(%edi)
    movl %eax, 8(%edi)
    movl %eax, 12(%edi)
    movb $0x35, 0(%edi)
    movl $0, %esi
    movl $0, %ecx
    movl $0, %ebp
    movl $8, %ebx
    call uas_cmd
    ret

/* proto_recover: transport-specific fault recovery. */
proto_recover:
    /* eax holds the transport result: BOT always runs the reset
     * recovery; UAS only aborts a dropped (timed-out) command - a
     * RESPONSE IU means the command never ran, so a plain retry is
     * enough and a TMF would only leave a stale RESPONSE behind. */
    pushl %eax
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    popl %eax
    call bot_recover
    ret
1:  popl %eax
    cmpl $3, %eax
    jne 2f
    movl cmd_tag, %eax
    movl %eax, cmd_tag_save
    call uas_tmf_abort
    /* next tag for the retry */
    incl tag_next
2:  ret

/* transport_read_drop: the a6 read uses a transport-specific tag so
 * the one-shot drop hook can target it (UAS: tag 0x1234). */
transport_read_drop:
    movl proto, %eax
    cmpl $0x50, %eax
    jne 1f
    movl $buf_data, %esi
    movl $1, %ecx
    movl $4, %ebp
    call bot_rw
    ret
1:  movl $buf_data, %esi
    movl $1, %ecx
    movl $0x1234, %ebp
    call uas_rw
    ret

/* rw_retry_write: write lba ebx with pattern + readback verify, retry
 * up to 4 times; returns attempts in eax. */
rw_retry_write:
    movl %ebx, lba_save
    movl $0, retry_cnt
1:  incl retry_cnt
    call pattern_fill
    movl lba_save, %ebx
    call transport_write
    cmpl $0, %eax
    jne 3f
    movl lba_save, %ebx
    call transport_read
    testl %eax, %eax
    jnz 3f
    call verify_pattern
    testl %eax, %eax
    jz 2f
3:  movl $30, %ecx
    call wait_ticks
    cmpl $4, retry_cnt
    jb 1b
    movl $1, fail
2:  movl retry_cnt, %eax
    ret
rw_retry_read:
    movl %ebx, lba_save
    movl $0, retry_cnt
1:  incl retry_cnt
    movl lba_save, %ebx
    call transport_read
    testl %eax, %eax
    jnz 3f
    call verify_pattern
    testl %eax, %eax
    jz 2f
3:  movl $30, %ecx
    call wait_ticks
    cmpl $4, retry_cnt
    jb 1b
    movl $1, fail
2:  movl retry_cnt, %eax
    ret

/* pattern fill helpers */
pattern_write:
    call pattern_fill
    xorl %ebx, %ebx
    call transport_write
    ret
pattern_read:
    xorl %ebx, %ebx
    call transport_read
    testl %eax, %eax
    jnz 9f
    call verify_pattern
9:  ret
pattern_write_lba1000:
    call pattern_fill
    movl $1000, %ebx
    call transport_write
    ret
pattern_write_lba4000:
    call pattern_fill
    movl $4000, %ebx
    call transport_write
    ret
pattern_write_lba8000:
    call pattern_fill
    movl $8000, %ebx
    call transport_write
    ret
pattern_write_lba9000:
    call pattern_fill
    movl $7500, %ebx
    call transport_write
    ret
pattern_fill:
    movl $buf_data, %edi
    movl $128, %ecx
    movl $0x55667788, %eax
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    ret
pattern_read_lba1000:
    movl $1000, %ebx
    call transport_read
    testl %eax, %eax
    jnz 9f
    call verify_pattern
9:  ret
verify_pattern:
    movl $buf_data, %edi
    movl $128, %ecx
    movl $0x55667788, %eax
1:  cmpl %eax, (%edi)
    jne 9f
    addl $4, %edi
    decl %ecx
    jnz 1b
    xorl %eax, %eax
    ret
9:  movl $1, %eax
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
    movl proto, %eax
    call puthex
    movl $sp_a1, %esi
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
    movl $sp_a10, %esi
    call puts
    movl a10, %eax
    call puthex
    movl $msg_evg, %esi
    call puts
    movl isoc_gaps, %eax
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
storage_port: .long 0
port_speed: .long 0
slot_id:    .long 0
proto:      .long 0
maxpkt0:    .long 0
cfg_total:  .long 0
ep_count:   .long 0
iface_off:  .long 0
ep_dcis:    .space 16
ep_addrs:   .space 16
ep_types:   .space 16
ep_maxs:    .space 16
isoc_dci:   .long 0
isoc_max:   .long 0
isoc_present: .long 0
bin_ep:     .long 0
bout_ep:    .long 0
bin_addr:   .long 0
bout_addr:  .long 0
uas_cmd_ep: .long 0
uas_sts_ep: .long 0
uas_din_ep: .long 0
uas_dout_ep:.long 0
tag_next:   .long 0
ticks:      .long 0
wait_base:  .long 0
wait_target:.long 0
ev_deadline:.long 0
tx_dci:     .long 0
fail:       .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
a4:         .long 0
a5:         .long 0
a6:         .long 0
a10:        .long 0
isoc_idx:   .long 0
isoc_gap:   .long 0
isoc_gaps:  .long 0
isoc_gaps_save: .long 0
isoc_last:  .long 0
drop_status: .long 0
arm_ok:     .long 0
wait_cnt:   .long 0
cmd_last:   .long 0
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
ctrl_data:  .long 0
ctrl_len:   .long 0
ctrl_dir:   .long 0
cmd_data:   .long 0
cmd_len:    .long 0
cmd_tag:    .long 0
cmd_dir:    .long 0
cmd_cdb:    .long 0
cmd_lba:    .long 0
cmd_tag_save: .long 0
lba_save:   .long 0
ring_idx:   .long 0
reset_dci:  .long 0
retry_cnt:  .long 0
cmd_ring_state: .long 0, 0, 0
ep0_ring_state: .long 0, 0, 0
rings:          .space 8 * 12     /* DCI 2..9: base/enq/pcs */

    .balign 64
cmd_ring:   .space RING_BYTES
    .balign 64
ep0_ring:   .space RING_BYTES
    .balign 64
ring_trbs:  .space 8 * RING_BYTES

    .balign 64
ev_ring_storage: .space EV_BYTES
    .balign 64
erst:       .space 16
    .balign 64
dcbaa:      .space 65 * 8
    .balign 64
dev_ctx:    .space 32 * 32
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
cbw_buf:    .space 32
csw_buf:    .space 16
iu_buf:     .space 64
cdb_buf:    .space 16
buf_data:   .space 512
isoc_buf:   .space 64
drop_armed_buf: .space 4

    .data
    .balign 16
setup_gdd:  .byte 0x80,0x06,0x00,0x01,0x00,0x00,0x12,0x00
setup_gdc9: .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x09,0x00
setup_gdc:  .byte 0x80,0x06,0x00,0x02,0x00,0x00,0x00,0x00
setup_sc:   .byte 0x00,0x09,0x01,0x00,0x00,0x00,0x00,0x00
setup_cfh:  .byte 0x02,0x01,0x00,0x00,0x00,0x00,0x00,0x00
setup_bmsr: .byte 0x21,0xff,0x00,0x00,0x00,0x00,0x00,0x00
/* vendor arm for the isoc missed-microframe */
setup_arm57: .byte 0x40,0x57,0x00,0x00,0x00,0x00,0x00,0x00
/* vendor READ of the isoc drop-armed flag */
setup_getdrop: .byte 0xc0,0x58,0x00,0x00,0x00,0x00,0x01,0x00

    .balign 16
idt_ptr:    .space 6
    .bss
    .balign 16
idt_table:  .space 256*8
stack:      .space 4096
stack_top:

    .section .rodata
msg:        .asciz "USB-FAULT t="
msg_nodev:  .asciz "USB-FAULT nodev\n"
msg_badbar: .asciz "USB-FAULT badbar\n"
msg_init:   .asciz "USB-FAULT init\n"
msg_port:   .asciz "USB-FAULT port\n"
msg_addr:   .asciz "USB-FAULT addr\n"
msg_desc:   .asciz "USB-FAULT desc\n"
msg_cfg:    .asciz "USB-FAULT cfg\n"
msg_evg:    .asciz " EVG="
sp_a1:      .asciz " a1="
sp_a2:      .asciz " a2="
sp_a3:      .asciz " a3="
sp_a4:      .asciz " a4="
sp_a5:      .asciz " a5="
sp_a6:      .asciz " a6="
sp_a10:     .asciz " a10="
sp_f:       .asciz " f="
nl:         .asciz "\n"
