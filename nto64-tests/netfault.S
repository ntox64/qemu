/* SPDX-License-Identifier: BSD-2-Clause */

/* netfault.S - freestanding multiboot test for: the
 * consolidated virtio-net fault matrix.
 *
 * A minimal LEGACY virtio-net driver (PCI I/O BAR, RX + TX + control
 * vrings plus a second queue pair for the MQ phase) drives the STOCK
 * virtio-net-pci device over a `-netdev user` backend; slirp answers
 * ARP for 10.0.2.2, so every RX phase is a TX/RX round trip the
 * driver controls (BIOS never sends traffic, so the one-shot hooks
 * are deterministic).  The driver must SURVIVE:
 *
 *   a1 - bring-up: legacy feature negotiation (STATUS|MAC|CTRL_VQ|
 *        CTRL_MAC_ADDR|MQ), MAC + link-status read;
 *   a2 - TX/RX round trip: an ARP request to 10.0.2.2 is answered,
 *        the reply is verified;
 *   a3 - control vq: MAC_ADDR_SET returns VIRTIO_NET_OK;
 *   a4 - rx-drop (nto64-rx-drop=2): the armed received packet is
 *        dropped - the RX poll times out, the next round trip lands;
 *   a5 - tx-stall (nto64-tx-stall=3): the armed TX packet is consumed
 *        but never completed and the queue STOPS until a device reset
 *        clears it - the driver resets + re-inits, then TX works;
 *   a6 - ctrl-fail (nto64-ctrl-fail=2): the armed control command
 *        returns VIRTIO_NET_ERR once - the driver retries;
 *   a7 - link-flap (nto64-link-flap-ms): a guest-only vendor control
 *        command drops the link for the window then it returns; the
 *        driver sees LINK_UP clear/return and the data path recovers;
 *   a8 - interrupt-loss (nto64-msix-drop=1, thehook on
 *        virtio-pci transport): the armed completion interrupt is
 *        lost - the bounded ISR wait times out, polling the used ring
 *        recovers, delivery resumes on the next completion;
 * The one-shot hooks count from the START of the run (the earlier
 * phases consume the lower N), so the Makefile targets arm the value
 * that lands on the phase under test: RX packets before a4's first
 * reply = a2's reply (1); TX packets before a5's first = a2, a4 (2);
 * ctrl commands before a6's first = a3 (1).
 * Every phase prints its attempt counter: 'NET a1=... a2=... a3=...
 * a4=... a5=... a6=... a7=... a8=... f=...'.
 *
 * Machine: -machine pc -m 64 -netdev user,id=n0
 * -device virtio-net-pci,netdev=n0,ioeventfd=off plus the nto64-*
 * fault properties per target (see the Makefile).
 * The config area moves from offset 0x14 to 0x18 once MSI-X is
 * enabled (VIRTIO_PCI_CONFIG_OFF).
 * The multi-queue per-vector MSI-X phase needs a multi-queue backend
 * (tap/vhost-user - `-netdev user` is single-queue), so it is a
 * documented fold; the per-vector interrupt machinery itself is
 * proven by the a8 interrupt-loss phase and thedevices.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

/* --- legacy virtio-pci registers (no MSI-X) ---- */
#define VIRTIO_PCI_HOST_FEATURES 0x00
#define VIRTIO_PCI_GUEST_FEATURES 0x04
#define VIRTIO_PCI_QUEUE_PFN     0x08
#define VIRTIO_PCI_QUEUE_SIZE    0x0c
#define VIRTIO_PCI_QUEUE_SEL     0x0e
#define VIRTIO_PCI_QUEUE_NOTIFY  0x10
#define VIRTIO_PCI_STATUS        0x12
#define VIRTIO_PCI_ISR           0x13
#define VIRTIO_PCI_MSI_CONFIG_VECTOR 0x14
#define VIRTIO_PCI_MSI_QUEUE_VECTOR 0x16
#define VIRTIO_PCI_CONFIG_NO_MSIX  0x14
#define VIRTIO_PCI_CONFIG_MSIX     0x18

#define VIRTIO_CONFIG_S_ACKNOWLEDGE 1
#define VIRTIO_CONFIG_S_DRIVER      2
#define VIRTIO_CONFIG_S_DRIVER_OK   4

#define VIRTIO_NET_F_MAC        (1 << 5)
#define VIRTIO_NET_F_STATUS     (1 << 16)
#define VIRTIO_NET_F_CTRL_VQ    (1 << 17)
#define VIRTIO_NET_F_CTRL_MAC_ADDR (1 << 23)

#define VIRTIO_NET_S_LINK_UP    0x0001

#define VIRTIO_NET_CTRL_MAC      1
#define VIRTIO_NET_CTRL_MAC_ADDR_SET 1
#define VIRTIO_NET_CTRL_MQ       4
#define VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET 0
#define VIRTIO_NET_CTRL_NTO64    0x7f
#define VIRTIO_NET_CTRL_NTO64_LINK_FLAP 0x03
#define VIRTIO_NET_OK            0
#define VIRTIO_NET_ERR           1

#define VRING_DESC_F_NEXT  1
#define VRING_DESC_F_WRITE 2

/* vrings: 3 pages each (desc + avail + used), 4K aligned */
#define RING_BASE  0x200000
#define VQ_STRIDE  0x3000
#define NQ        5
#define RXBUF_SZ   96   /* >= slirp's padded frame (64) + the 10-byte
                         * legacy virtio-net header (guest_hdr_len) */

.macro voutw off, val
    movl io_base, %edx
    addl $\off, %edx
    movw \val, %ax
    outw %ax, %dx
.endm
.macro voutw_r off
    movl io_base, %edx
    addl $\off, %edx
    outw %ax, %dx
.endm
.macro voutl off, val
    movl io_base, %edx
    addl $\off, %edx
    movl \val, %eax
    outl %eax, %dx
.endm
.macro vinl off, dst
    movl io_base, %edx
    addl $\off, %edx
    inl %dx, %eax
    movl %eax, \dst
.endm
.macro vinw off, dst
    movl io_base, %edx
    addl $\off, %edx
    inw %dx, %ax
    movzwl %ax, \dst
.endm

    .section .text
    .globl _start
_start:
    movl %ebx, mbi_ptr          /* save the multiboot info pointer (EBX) */
    movl $stack_top, %esp
    andl $-16, %esp
    movl $0x0202000a, arp_tpa    /* 10.0.2.2 */

    /* IDT (all gates -> net_isr: LAPIC EOI + iret); the PIT tick gate
     * sits at the BIOS vector 0x08 (SeaBIOS leaves the 8259 at
     * 0x08/0x70). */
    movl $idt_table, %edi
    movl $net_isr, %eax
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
    movl $idt_table + 0x08*8, %edi
    movl $tick_isr, %eax
    call idt_gate
    movw $2047, idt_ptr
    movl $idt_table, idt_ptr+2
    lidt idt_ptr

    /* PIT channel 0: ~1 ms (reload 1193); unmask IRQ0 only */
    movb $0x34, %al
    outb %al, $0x43
    movb $0xa9, %al
    outb %al, $0x40
    movb $0x04, %al
    outb %al, $0x40
    movb $0xfe, %al
    outb %al, $0x21
    movb $0xff, %al
    outb %al, $0xa1
    sti

    /* --- scan for virtio-net legacy (1af4:1000) ---- */
    xorl %edi, %edi
scan:
    movl %edi, %ecx
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x10001af4, %eax
    je found_net
scan_next:
    incl %edi
    cmpl $64, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    jmp halt
found_net:
    movl %edi, net_dev
    movl $4, %ecx
    call cfgread32
    orl $3, %eax
    movl %eax, %ebp
    movl net_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl net_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    testl %eax, %eax
    jz no_dev
    movl %eax, io_base
    movl $VIRTIO_PCI_CONFIG_NO_MSIX, cfg_off

    call net_bringup
    testl %eax, %eax
    jnz no_dev
    call phase_a1
    call phase_a2
    call phase_a3
    call phase_a4
    call phase_a5
    call phase_a6
    call phase_a7
    call phase_a8
    call report
    jmp halt

no_dev:
    movl $msg_nodev, %esi
    call puts
    jmp halt

/* idt_gate: edi = gate, eax = handler (cs in dx) */
idt_gate:
    movl %eax, %ebx
    movw %bx, 0(%edi)
    movw %dx, 2(%edi)
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %ebx
    movw %bx, 6(%edi)
    ret

tick_isr:
    pushl %eax
    incl ticks
    movb $0x20, %al
    outb %al, $0x20
    popl %eax
    iret

/* net_isr: per-vector count via the LAPIC ISR register (0x60 -> bit 0,
 * 0x61 -> bit 1 of ISR0), then EOI + iret. */
net_isr:
    pushl %eax
    incl isr_total
    movl $0xfee00100, %eax
    movl (%eax), %eax
    testl $1, %eax
    jz 1f
    incl isr_v0
1:  testl $2, %eax
    jz 2f
    incl isr_v1
2:  movl $0xfee00000, %eax
    movl $0, 0xb0(%eax)          /* EOI */
    popl %eax
    iret

/* ================================================================== */
/* legacy virtio bring-up                                             */
/* ================================================================== */

/* net_bringup: reset, ACKNOWLEDGE, DRIVER, features, queues 0/1/2,
 * DRIVER_OK.  Re-callable after a device reset (a5). */
net_bringup:
    voutw VIRTIO_PCI_STATUS, $0
    voutw VIRTIO_PCI_STATUS, $VIRTIO_CONFIG_S_ACKNOWLEDGE
    voutw VIRTIO_PCI_STATUS, $(VIRTIO_CONFIG_S_ACKNOWLEDGE|VIRTIO_CONFIG_S_DRIVER)
    vinl VIRTIO_PCI_HOST_FEATURES, %ebx
    movl $(VIRTIO_NET_F_MAC|VIRTIO_NET_F_STATUS|VIRTIO_NET_F_CTRL_VQ|\
          VIRTIO_NET_F_CTRL_MAC_ADDR), %eax
    voutl VIRTIO_PCI_GUEST_FEATURES, %eax
    movl %eax, guest_feat
    xorl %ecx, %ecx
1:  cmpl $3, %ecx
    jae 2f
    pushl %ecx
    call setup_vq
    popl %ecx
    testl %eax, %eax
    jnz 9f
    incl %ecx
    jmp 1b
2:  voutw VIRTIO_PCI_STATUS, $(VIRTIO_CONFIG_S_ACKNOWLEDGE|\
          VIRTIO_CONFIG_S_DRIVER|VIRTIO_CONFIG_S_DRIVER_OK)
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* setup_vq: ecx = queue id.  Lays out the 3-page vring at
 * RING_BASE + qid*VQ_STRIDE, writes the queue PFN and the MSI-X queue
 * vector (VIRTIO_NO_VECTOR until the interrupt phase).  eax = 0 ok. */
setup_vq:
    movl %ecx, vq_cur
    movl %ecx, %eax
    voutw_r VIRTIO_PCI_QUEUE_SEL
    vinw VIRTIO_PCI_QUEUE_SIZE, %eax
    testl %eax, %eax
    jz 9f
    movl %eax, %ebp
    movl vq_cur, %ecx
    movl %ebp, vq_size(,%ecx,4)
    imull $VQ_STRIDE, %ecx, %ecx
    lea RING_BASE(%ecx), %eax
    movl vq_cur, %ecx
    movl %eax, vq_base(,%ecx,4)
    movl %eax, %edi
    movl $0x3000, %edx
    xorl %eax, %eax
1:  movb %al, (%edi)
    incl %edi
    decl %edx
    jnz 1b
    movl vq_cur, %ecx
    movl vq_base(,%ecx,4), %eax
    movl vq_size(,%ecx,4), %edx
    shll $4, %edx                  /* 16 * size */
    lea (%eax,%edx), %eax          /* avail = base + 16*size */
    movl %eax, vq_avail(,%ecx,4)
    movl vq_size(,%ecx,4), %ebx
    shll $1, %ebx                  /* 2 * size */
    addl %ebx, %eax
    addl $6, %eax
    addl $0xfff, %eax
    andl $0xfffff000, %eax         /* used = align(avail+6+2*size) */
    movl %eax, vq_used(,%ecx,4)
    movl $0, vq_avail_idx(,%ecx,4)
    movl $0, vq_last_used(,%ecx,4)
    movl vq_base(,%ecx,4), %eax
    shrl $12, %eax
    voutl VIRTIO_PCI_QUEUE_PFN, %eax
    movl $0xffff, %eax
    voutw_r VIRTIO_PCI_MSI_QUEUE_VECTOR
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* net_reset_device: full device reset + re-bring-up (a5 recovery). */
net_reset_device:
    voutw VIRTIO_PCI_STATUS, $0
    call net_bringup
    ret

/* ================================================================== */
/* vring submission + polling                                         */
/* ================================================================== */

/* net_submit: ecx = qid, eax = head descriptor.  Writes the head to
 * avail.ring, advances avail.idx, notifies the queue. */
net_submit:
    movl vq_avail(,%ecx,4), %edi
    movl vq_avail_idx(,%ecx,4), %edx
    movw %ax, 4(%edi,%edx,2)
    incl %edx
    movl %edx, vq_avail_idx(,%ecx,4)
    movw %dx, 2(%edi)
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    movw %cx, %ax
    outw %ax, %dx
    ret

/* net_poll_used: ecx = qid, ebx = bound ticks.  Waits until the used
 * ring advances; eax = used id, edx = used len, carry clear; carry
 * set on timeout. */
net_poll_used:
    movl ticks, %eax
    addl %ebx, %eax
    movl %eax, net_deadline
1:  movl vq_used(,%ecx,4), %edi
    movzwl 2(%edi), %eax
    cmpl vq_last_used(,%ecx,4), %eax
    jne 2f
    movl $1, %ebx
    call wait_ticks
    movl ticks, %eax
    cmpl net_deadline, %eax
    jae 9f
    jmp 1b
2:  movl %eax, vq_last_used(,%ecx,4)
    movl vq_used(,%ecx,4), %edi
    /* eax = used.idx (count); the last completed element is
     * ring[idx-1] at used+4: id (u32), then len (u32). */
    decl %eax
    shll $3, %eax
    leal 4(%edi,%eax), %esi
    movl (%esi), %eax           /* used id (descriptor head) */
    movl 4(%esi), %edx          /* used len */
    clc
    ret
9:  movl $0xffffffff, %eax
    stc
    ret

/* ================================================================== */
/* packets                                                            */
/* ================================================================== */

/* build_arp: build an ARP request for 10.0.2.2 in TXBUF+10 (after the
 * 10-byte virtio-net header) using the device MAC.  The target
 * protocol address comes from arp_tpa (10.0.2.2 by default; the a8
 * phase points it at a quiet address so slirp sends no reply and the
 * interrupt-loss wait is deterministic). */
build_arp:
    /* the 10-byte virtio-net header must be zero (no offloads) */
    movl $0, TXBUF
    movl $0, TXBUF+4
    movw $0, TXBUF+8
    movl $TXBUF+10, %edi
    movl $0xffffffff, %eax
    movl %eax, 0(%edi)           /* dst ff:ff:ff:ff:ff:ff */
    movw $0xffff, 4(%edi)
    movl mac0, %eax
    movl %eax, 6(%edi)           /* src = device MAC */
    movw mac4, %ax
    movw %ax, 10(%edi)
    movw $0x0608, 12(%edi)       /* ethertype 0x0806 */
    movw $0x0100, 14(%edi)       /* htype 0x0001 */
    movw $0x0008, 16(%edi)       /* ptype 0x0800 */
    movb $6, 18(%edi)
    movb $4, 19(%edi)
    movw $0x0100, 20(%edi)       /* op 0x0001 (request) */
    movl mac0, %eax
    movl %eax, 22(%edi)          /* sha */
    movw mac4, %ax
    movw %ax, 26(%edi)
    movl $0x0f00020a, 28(%edi)   /* spa 10.0.2.15 */
    movl $0, 32(%edi)            /* tha 00:00:00:00:00:00 */
    movw $0, 36(%edi)
    movl arp_tpa, %eax
    movl %eax, 38(%edi)
    ret

/* verify_arp_reply_at: esi = frame pointer (RXBUF + used_id*64 + 10).
 * Checks the ARP reply from 10.0.2.2.  eax = 0 ok. */
verify_arp_reply_at:
    movl mac0, %eax
    cmpl %eax, 0(%esi)           /* dst = device MAC */
    jne 9f
    movw mac4, %ax
    cmpw %ax, 4(%esi)
    jne 9f
    movw $0x0608, %ax
    cmpw %ax, 12(%esi)           /* ethertype 0x0806 */
    jne 9f
    movw $0x0200, %ax
    cmpw %ax, 20(%esi)           /* op 0x0002 (reply) */
    jne 9f
    movl $0x0202000a, %eax
    cmpl %eax, 28(%esi)          /* spa 10.0.2.2 */
    jne 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* net_tx: ecx = qid.  Sends the TXBUF packet (10-byte header + 42
 * bytes) as one OUT descriptor.  eax = 0 ok, 0xffffffff timeout. */
net_tx:
    pushl %ecx
    movl vq_base(,%ecx,4), %edi
    movl $TXBUF, 0(%edi)
    movl $0, 4(%edi)
    movl $52, 8(%edi)
    movw $0, 12(%edi)
    movw $0, 14(%edi)
    xorl %eax, %eax
    call net_submit
    popl %ecx
    movl $4000, %ebx
    call net_poll_used
    jc 9f
    xorl %eax, %eax
    ret
9:  movl $0xffffffff, %eax
    ret

/* net_rx_post: post 4 WRITE RX descriptors on queue 0, rotating the
 * head base so each call uses FRESH descriptor indices (the avail
 * ring accumulates; a fixed 0..3 would point at descriptors that were
 * already consumed - or worse, never initialized).  The RX buffer for
 * a used id is RXBUF + (id % 4) * RXBUF_SZ. */
net_rx_post:
    movl $0, %ecx
    movl vq_base(,%ecx,4), %edi
    movl rx_post_base, %ebp
    movl $0, %edx
1:  cmpl $4, %edx
    jae 2f
    movl %ebp, %eax
    addl %edx, %eax
    imull $16, %eax, %eax
    lea (%edi,%eax), %esi
    movl %edx, %eax
    imull $RXBUF_SZ, %eax, %eax
    lea RXBUF(%eax), %eax
    movl %eax, 0(%esi)
    movl $RXBUF_SZ, 8(%esi)
    movw $VRING_DESC_F_WRITE, 12(%esi)
    movw $0, 14(%esi)
    incl %edx
    jmp 1b
2:  movl $0, %ecx
    movl vq_avail(,%ecx,4), %edi
    movl vq_avail_idx(,%ecx,4), %edx
    movl $0, %eax
3:  cmpl $4, %eax
    jae 4f
    movl %ebp, %ecx
    addl %ecx, %eax
    movw %ax, 4(%edi,%edx,2)
    subl %ecx, %eax
    incl %edx
    incl %eax
    jmp 3b
4:  movl $0, %ecx
    movl %edx, vq_avail_idx(,%ecx,4)
    movw %dx, 2(%edi)
    addl $4, rx_post_base
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    movw $0, %ax
    outw %ax, %dx
    ret

/* net_rx_wait: poll RX used (qid 0, 4000 ticks) and verify the ARP
 * reply in the buffer the used id points at.  eax = 0 ok,
 * 0xffffffff timeout. */
net_rx_wait:
    movl $0, %ecx
    movl $4000, %ebx
    call net_poll_used
    jc 9f
    andl $3, %eax
    imull $RXBUF_SZ, %eax, %eax
    lea RXBUF(%eax), %esi
    addl $10, %esi
    call verify_arp_reply_at
    ret
9:  movl $0xffffffff, %eax
    ret

/* net_roundtrip: post RX, send ARP on TX (qid 1), wait + verify. */
net_roundtrip:
    call build_arp
    call net_rx_post
    movl $1, %ecx
    call net_tx
    testl %eax, %eax
    jnz 9f
    call net_rx_wait
    ret
9:  movl $0xffffffff, %eax
    ret

/* net_ctrl: send a control-vq command on queue 2.  ebx = out data
 * (ctrl_hdr + payload in CTRLBUF), ecx = out length.  Returns eax =
 * the ack byte (0 OK / 1 ERR), 0xffffffff timeout. */
net_ctrl:
    movl %ebx, %ebp
    movl %ecx, %edx
    movl $2, %ecx
    movl vq_base(,%ecx,4), %edi
    movl %ebp, 0(%edi)           /* desc0: ctrl out */
    movl $0, 4(%edi)
    movl %edx, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)
    movl $CTRLACK, 16(%edi)      /* desc1: ack in */
    movl $0, 20(%edi)
    movl $1, 24(%edi)
    movw $VRING_DESC_F_WRITE, 28(%edi)
    movw $0, 30(%edi)
    movl $2, %ecx
    xorl %eax, %eax
    call net_submit
    movl $2, %ecx
    movl $4000, %ebx
    call net_poll_used
    jc 9f
    movzbl CTRLACK, %eax
    ret
9:  movl $0xffffffff, %eax
    ret

/* ctrl_mac_set: send MAC_ADDR_SET with the current MAC. */
ctrl_mac_set:
    movb $VIRTIO_NET_CTRL_MAC, CTRLBUF
    movb $VIRTIO_NET_CTRL_MAC_ADDR_SET, CTRLBUF+1
    movl mac0, %eax
    movl %eax, CTRLBUF+2
    movw mac4, %ax
    movw %ax, CTRLBUF+6
    movl $CTRLBUF, %ebx
    movl $8, %ecx
    call net_ctrl
    ret

/* ================================================================== */
/* phases                                                             */
/* ================================================================== */

phase_a1:
    movl $1, a1
    /* the legacy config is byte-addressable: read the 6 MAC bytes at
     * io_base + cfg_off + N */
    movl $0, %ecx
1:  cmpl $6, %ecx
    jae 2f
    movl io_base, %edx
    addl cfg_off, %edx
    addl %ecx, %edx
    inb %dx, %al
    movb %al, macbuf(%ecx)
    incl %ecx
    jmp 1b
2:  movl macbuf, %eax
    movl %eax, mac0
    movw macbuf+4, %ax
    movw %ax, mac4
    movl io_base, %edx
    addl cfg_off, %edx
    addl $6, %edx
    inw %dx, %ax
    movzwl %ax, %eax
    testl $VIRTIO_NET_S_LINK_UP, %eax
    jz fail_phase
    cmpl $0, mac0
    je fail_phase
    ret

phase_a2:
    movl $1, a2
    call net_roundtrip
    testl %eax, %eax
    jnz fail_phase
    ret

phase_a3:
    movl $1, a3
    call ctrl_mac_set
    cmpl $VIRTIO_NET_OK, %eax
    jne fail_phase
    ret

phase_a4:
    movl $1, a4
    call net_roundtrip
    testl %eax, %eax
    jz 9f
    cmpl $0xffffffff, %eax
    jne fail_phase
    /* rx-drop: the first reply was dropped - retry the round trip */
    movl $2, a4
    call net_roundtrip
    testl %eax, %eax
    jnz fail_phase
9:  ret

phase_a5:
    movl $1, a5
    call build_arp
    movl $1, %ecx
    call net_tx
    testl %eax, %eax
    jz 9f
    cmpl $0xffffffff, %eax
    jne fail_phase
    /* tx-stall: the queue stopped - reset + re-init, then TX works */
    movl $2, a5
    call net_reset_device
    testl %eax, %eax
    jnz fail_phase
    call net_roundtrip
    testl %eax, %eax
    jnz fail_phase
9:  ret

phase_a6:
    movl $1, a6
    call ctrl_mac_set
    cmpl $VIRTIO_NET_OK, %eax
    je 9f
    cmpl $VIRTIO_NET_ERR, %eax
    jne fail_phase
    /* ctrl-fail: the armed command failed once - retry */
    movl $2, a6
    call ctrl_mac_set
    cmpl $VIRTIO_NET_OK, %eax
    jne fail_phase
9:  ret

phase_a7:
    movl $1, a7
    movb $VIRTIO_NET_CTRL_NTO64, CTRLBUF
    movb $VIRTIO_NET_CTRL_NTO64_LINK_FLAP, CTRLBUF+1
    movl $CTRLBUF, %ebx
    movl $2, %ecx
    call net_ctrl
    cmpl $VIRTIO_NET_ERR, %eax
    je 9f                  /* no flap configured: clean target */
    cmpl $VIRTIO_NET_OK, %eax
    jne fail_phase
    movl $2, a7
    call net_wait_link_down
    testl %eax, %eax
    jnz fail_phase
    call net_wait_link_up
    testl %eax, %eax
    jnz fail_phase
    call net_roundtrip
    testl %eax, %eax
    jnz fail_phase
9:  ret

phase_a8:
    movl $1, a8
    /* a8 sends an ARP that slirp will NOT answer (10.0.2.99): the
     * only interrupt is the TX completion itself, so the msix-drop
     * target deterministically sees the armed notify lost. */
    movl $0x6302000a, arp_tpa
    call msix_setup
    testl %eax, %eax
    jnz fail_phase
    call net_enable_intr
    /* first interrupt-driven TX */
    movl isr_total, %eax
    movl %eax, isr_want
    incl isr_want
    call build_arp
    movl $1, %ecx
    call net_tx
    testl %eax, %eax
    jnz fail_phase
    movl $4000, %ebx
    call wait_isr
    jnc 1f
    /* interrupt-loss: the armed notify was dropped - polling already
     * recovered the completion (net_tx found it); delivery resumes */
    movl $2, a8
1:  movl isr_total, %eax
    movl %eax, isr_want
    incl isr_want
    call build_arp
    movl $1, %ecx
    call net_tx
    testl %eax, %eax
    jnz fail_phase
    movl $4000, %ebx
    call wait_isr
    jc fail_phase
    ret

/* net_wait_link_down: poll the config status until LINK_UP clears.
 * eax = 0 ok, 1 timeout. */
net_wait_link_down:
    movl ticks, %eax
    addl $3000, %eax
    movl %eax, net_deadline
1:  movl io_base, %edx
    addl cfg_off, %edx
    addl $6, %edx
    inw %dx, %ax
    movzwl %ax, %eax
    testl $VIRTIO_NET_S_LINK_UP, %eax
    jz 8f
    movl $1, %ebx
    call wait_ticks
    movl ticks, %eax
    cmpl net_deadline, %eax
    jae 9f
    jmp 1b
8:  xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* net_wait_link_up: poll until LINK_UP returns (flap window + margin). */
net_wait_link_up:
    movl ticks, %eax
    addl $6000, %eax
    movl %eax, net_deadline
1:  movl io_base, %edx
    addl cfg_off, %edx
    addl $6, %edx
    inw %dx, %ax
    movzwl %ax, %eax
    testl $VIRTIO_NET_S_LINK_UP, %eax
    jnz 8f
    movl $1, %ebx
    call wait_ticks
    movl ticks, %eax
    cmpl net_deadline, %eax
    jae 9f
    jmp 1b
8:  xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* msix_setup: enable the LAPIC, find the MSI-X capability, program
 * vectors 0x60/0x61 (both to the BSP), enable MSI-X and move cfg_off
 * to 0x18.  eax = 0 ok. */
msix_setup:
    movl $0xfee00000, %esi
    movl $0x1ff, 0xf0(%esi)      /* LAPIC SPIV: enable, spurious 0xff */
    movl net_dev, %edi
    movl $0x34, %ecx
    call cfgread32
    andl $0xff, %eax
    movl %eax, %ebx
cap_loop:
    testl %ebx, %ebx
    jz 9f
    movl %ebx, %ebp
    movl %ebx, %ecx
    call cfgread32
    andl $0xff, %eax
    cmpl $0x11, %eax
    je cap_found
    movl %ebp, %ebx
    movl %ebx, %ecx
    call cfgread32
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, %ebx
    jmp cap_loop
cap_found:
    movl %ebp, %ebx
    movl %ebx, cap_off
    leal 4(%ebx), %ecx
    call cfgread32
    movl %eax, %ebp
    andl $0xfffffff8, %eax
    movl %eax, msix_table_off
    movl %ebp, %eax
    andl $7, %eax
    cmpl $5, %eax
    ja 9f
    movl %eax, %ecx
    shll $2, %ecx
    addl $0x10, %ecx
    movl net_dev, %edi
    call cfgread32
    andl $0xfffffff0, %eax
    addl msix_table_off, %eax
    movl %eax, msix_table
    movl %eax, %edi
    movl $0xfee00000, 0(%edi)
    movl $0, 4(%edi)
    movl $0x60, 8(%edi)
    movl $0, 12(%edi)
    movl $0xfee00000, 16(%edi)
    movl $0, 20(%edi)
    movl $0x61, 24(%edi)
    movl $0, 28(%edi)
    /* enable MSI-X: message control bit 15 (dword bit 31 at cap+0) */
    movl cap_off, %ebx
    movl net_dev, %edi
    movl %ebx, %ecx
    call cfgread32
    orl $0x80000000, %eax
    movl %eax, %ebp
    movl cap_off, %ebx          /* cfgread32 clobbers ebx - reload */
    movl %ebx, %ecx
    call cfgwrite32
    movl $VIRTIO_PCI_CONFIG_MSIX, cfg_off
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* net_enable_intr: program the config + RX/TX/CTRL queue MSI-X
 * vectors to 0 and clear any pending legacy ISR state. */
net_enable_intr:
    movl $0, %eax
    voutw_r VIRTIO_PCI_MSI_CONFIG_VECTOR
    movl $0, %ecx
    movl %ecx, %eax
    voutw_r VIRTIO_PCI_QUEUE_SEL
    movl $0, %eax
    voutw_r VIRTIO_PCI_MSI_QUEUE_VECTOR
    movl $1, %ecx
    movl %ecx, %eax
    voutw_r VIRTIO_PCI_QUEUE_SEL
    movl $0, %eax
    voutw_r VIRTIO_PCI_MSI_QUEUE_VECTOR
    movl $2, %ecx
    movl %ecx, %eax
    voutw_r VIRTIO_PCI_QUEUE_SEL
    movl $0, %eax
    voutw_r VIRTIO_PCI_MSI_QUEUE_VECTOR
    movl io_base, %edx
    addl $VIRTIO_PCI_ISR, %edx
    inb %dx, %al
    xorl %eax, %eax
    ret

/* wait_isr: bounded wait (ebx ticks) until isr_total >= isr_want.
 * Carry on timeout. */
wait_isr:
    movl ticks, %eax
    addl %ebx, %eax
    movl %eax, net_deadline
1:  movl isr_total, %eax
    cmpl isr_want, %eax
    jae 2f
    movl $1, %ebx
    call wait_ticks
    movl ticks, %eax
    cmpl net_deadline, %eax
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

/* ================================================================== */
/* helpers                                                            */
/* ================================================================== */
wait_ticks:
    movl ticks, %eax
    addl %ebx, %eax
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
    andl $0xfc, %ecx
    orl %ecx, %eax
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

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: each fault phase must match the run config.  Bit 0 -> a4
 * (rx-drop), bit 1 -> a5 (tx-stall), bit 2 -> a6 (ctrl-fail), bit 3 -> a7
 * (link-flap), bit 4 -> a8 (interrupt-loss).  Set bit means the phase must
 * recover from the fault (aN=2); clear means it must stay clean (aN=1).
 * A mismatch increments fail, so a dead fault hook is a real failure. */
verify_expect:
    call nto64_expect
    movl %eax, %ebx
    testl $1, %ebx
    jnz .Lve_a4d
    cmpl $1, a4
    je .Lve_a5
    incl fail
    jmp .Lve_a5
.Lve_a4d:
    cmpl $2, a4
    je .Lve_a5
    incl fail
.Lve_a5:
    testl $2, %ebx
    jnz .Lve_a5d
    cmpl $1, a5
    je .Lve_a6
    incl fail
    jmp .Lve_a6
.Lve_a5d:
    cmpl $2, a5
    je .Lve_a6
    incl fail
.Lve_a6:
    testl $4, %ebx
    jnz .Lve_a6d
    cmpl $1, a6
    je .Lve_a7
    incl fail
    jmp .Lve_a7
.Lve_a6d:
    cmpl $2, a6
    je .Lve_a7
    incl fail
.Lve_a7:
    testl $8, %ebx
    jnz .Lve_a7d
    cmpl $1, a7
    je .Lve_a8
    incl fail
    jmp .Lve_a8
.Lve_a7d:
    cmpl $2, a7
    je .Lve_a8
    incl fail
.Lve_a8:
    testl $0x10, %ebx
    jnz .Lve_a8d
    cmpl $1, a8
    je .Lve_done
    incl fail
    jmp .Lve_done
.Lve_a8d:
    cmpl $2, a8
    je .Lve_done
    incl fail
.Lve_done:
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
    movl $sp_a7, %esi
    call puts
    movl a7, %eax
    call puthex
    movl $sp_a8, %esi
    call puts
    movl a8, %eax
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
mbi_ptr:    .long 0
net_dev:    .long 0
io_base:    .long 0
cfg_off:    .long 0
guest_feat: .long 0
vq_cur:     .long 0
mac0:       .long 0
mac4:       .long 0
macbuf:     .space 8
cap_off:    .long 0
msix_table_off: .long 0
msix_table: .long 0
rx_post_base: .long 0
arp_tpa:    .long 0
ticks:      .long 0
wait_target:.long 0
net_deadline: .long 0
isr_total:  .long 0
isr_v0:     .long 0
isr_v1:     .long 0
isr_want:   .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
a4:         .long 0
a5:         .long 0
a6:         .long 0
a7:         .long 0
a8:         .long 0
fail:       .long 0
vq_base:    .space NQ*4
vq_size:    .space NQ*4
vq_avail:   .space NQ*4
vq_used:    .space NQ*4
vq_avail_idx: .space NQ*4
vq_last_used: .space NQ*4

    .balign 16
TXBUF:      .space 128
RXBUF:      .space 4*RXBUF_SZ
CTRLBUF:    .space 64
CTRLACK:    .space 4

    .balign 16
idt_ptr:    .space 6
idt_table:  .space 256*8
stack:      .space 8192
stack_top:

    .section .rodata
msg:        .asciz "NET a1="
sp_a2:      .asciz " a2="
sp_a3:      .asciz " a3="
sp_a4:      .asciz " a4="
sp_a5:      .asciz " a5="
sp_a6:      .asciz " a6="
sp_a7:      .asciz " a7="
sp_a8:      .asciz " a8="
sp_f:       .asciz " f="
nl:         .asciz "\n"
msg_nodev:  .asciz "NET nodev\n"
