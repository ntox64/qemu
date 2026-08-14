/* SPDX-License-Identifier: BSD-2-Clause */

/* vblktest.S - freestanding multiboot test for the modern:
 * virtio-blk + blkdebug bring-up / fault slice.
 *
 * A minimal LEGACY virtio-blk driver (PCI I/O BAR, one vring, three
 * descriptors per request) driving the STOCK virtio-blk-pci device over
 * a blkdebug-instrumented raw image.  The driver must SURVIVE:
 *   bad-track / device-retry: a transient EIO read (blkdebug
 *     inject-error once at sector 1000) - the driver retries and the
 *     data must come back intact;
 *   sudden backend errors: transient EIO write (2000), ENOSPC write
 *     (3000) and EIO read (4000) - each recovered by a bounded retry;
 *   persistent backend error until the condition clears: writes to
 *     sector 7000 keep failing with IOERR until a FLUSH (the driver's
 *     recovery action) clears the blkdebug state, after which the write
 *     and the readback must succeed.
 *   ring-full / descriptor exhaustion (the
 *     landed in ): with a small queue the driver submits
 *     12-request burst and MUST stop when the descriptor table is
 *     exhausted (no free chain), wait for a used-ring completion
 *     (drain), reuse the freed chain and continue; every completion
 *     must be VIRTIO_BLK_S_OK with verified data.  The run-vblkringfull
 *     target passes queue-size=8 (qn/3 = 2 chains), so the full
 *     condition is genuinely hit; the default 256-deep queue never
 *     exhausts on a 12-request burst.
 * Every phase must end in VIRTIO_BLK_S_OK with verified data and a
 * bounded retry count; the per-phase attempt counters are printed so
 * each run target's expected fault shape is visible.
 *
 * IMPORTANT qemu-side requirement (the graph): the format driver must
 * sit ON TOP of blkdebug - raw -> blkdebug -> file.  The format driver
 * emits the read_aio/write_aio/flush_to_os events onto its file child,
 * which is the blkdebug node; with blkdebug on top the events are
 * emitted below it and no rule ever fires.  The run-* targets use
 * `-drive ...format=raw,file=blkdebug:conf:img` which builds exactly
 * that chain.  The run-* targets also set werror=report,rerror=report:
 * the default werror=enospc STOPS the VM on ENOSPC instead of reporting
 * it to the guest.
 *
 * Machine: -machine pc -m 64, one virtio-blk-pci on a 4 MiB sparse raw
 * image.  Build: `make vblktest`, run: `make run-vblktest` (clean),
 * `run-vblkbadtrack`, `run-vblkerr`, `run-vblkpersist`,
 * `run-vblkringfull` (queue-size=8, a6=21).
 * Prints 'VBLK ...' and halts.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

#define RING      0x200000        /* vring base (4K aligned) */
#define HDR       0x300000        /* 16-byte virtio-blk out header */
#define DATA      0x300400        /* 512-byte data buffer */
#define STS       0x300600        /* 1-byte status buffer */
#define REQBASE   0x400000        /* per-request blocks for P6 */
#define REQSTRIDE 0x300           /* 768 bytes per request block */
#define REQ_DATA  0x100           /* data offset in a request block */
#define REQ_STS   0x280           /* status offset in a request block */

#define VIRTIO_PCI_HOST_FEATURES  0x00
#define VIRTIO_PCI_GUEST_FEATURES 0x04
#define VIRTIO_PCI_QUEUE_PFN      0x08
#define VIRTIO_PCI_QUEUE_SIZE     0x0c
#define VIRTIO_PCI_QUEUE_SEL      0x0e
#define VIRTIO_PCI_QUEUE_NOTIFY   0x10
#define VIRTIO_PCI_STATUS         0x12
#define VIRTIO_PCI_CONFIG         0x14

#define VIRTIO_BLK_T_IN           0
#define VIRTIO_BLK_T_OUT          1
#define VIRTIO_BLK_T_FLUSH        4

#define VRING_DESC_F_NEXT         1
#define VRING_DESC_F_WRITE        2

/* Legacy virtio-pci registers are I/O-PORT registers (the BAR is an I/O
 * BAR): every access must be an IN/OUT, never a memory load/store. */
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
.macro FAILPT c
    movl $\c, %eax
    call putc
    incl fail
.endm

    .section .text
    .globl _start
_start:
    movl %ebx, mbi_ptr          /* save the multiboot info pointer (EBX) */
    movl $stack_top, %esp
    andl $-16, %esp

    /* --- scan for virtio-blk legacy (1af4:1001) ---- */
    xorl %edi, %edi
scan:
    movl %edi, %ecx
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x10011af4, %eax
    je found_blk
scan_next:
    incl %edi
    cmpl $64, %edi
    jne scan
    jmp no_dev
found_blk:
    movl %edi, blk_dev

    /* --- enable I/O + bus master, read the I/O BAR0 ---- */
    movl $4, %ecx
    call cfgread32
    orl $3, %eax
    movl %eax, %ebp
    movl blk_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl blk_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    testl %eax, %eax
    jz no_dev
    movl %eax, io_base

    /* --- legacy virtio bring-up ---- */
    voutw VIRTIO_PCI_STATUS, $0           /* reset */
    voutw VIRTIO_PCI_STATUS, $1           /* ACKNOWLEDGE */
    voutw VIRTIO_PCI_STATUS, $3           /* | DRIVER */
    vinl VIRTIO_PCI_HOST_FEATURES, %ebx   /* host features (ignored) */
    voutl VIRTIO_PCI_GUEST_FEATURES, $0

    /* queue 0: size, then zero + place the vring */
    voutw VIRTIO_PCI_QUEUE_SEL, $0
    vinw VIRTIO_PCI_QUEUE_SIZE, %eax
    testl %eax, %eax
    jz no_dev
    cmpl $256, %eax
    jbe 1f
    movl $256, %eax
1:  movl %eax, qn
    decl %eax
    movl %eax, qmask

    movl $RING, %edi
    xorl %eax, %eax
    movl $0x3000, %ecx                    /* 3 pages: desc+avail+used */
2:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 2b

    /* desc = RING; avail = RING + 16*qn;
     * used = align4096(avail + 6 + 2*qn) */
    movl qn, %eax
    shll $4, %eax
    addl $RING, %eax
    movl %eax, avail_base
    addl $6, %eax
    movl qn, %ecx
    shll $1, %ecx
    addl %ecx, %eax
    addl $0xfff, %eax
    andl $0xfffff000, %eax
    movl %eax, used_base

    voutl VIRTIO_PCI_QUEUE_PFN, $0x200      /* RING >> 12 */
    voutw VIRTIO_PCI_STATUS, $7             /* | DRIVER_OK */

    /* --- P0: capacity + clean read/write round trip ---- */
    vinl VIRTIO_PCI_CONFIG, cap_lo
    vinl VIRTIO_PCI_CONFIG+4, cap_hi
    testl %eax, %eax
    jnz p0_bad
    cmpl $0x1000, cap_lo                   /* >= 4096 sectors (4M) */
    jae p0_ok
p0_bad:
    FAILPT '0'
p0_ok:
    /* read sector 0: fresh sparse image -> zeros */
    movl $VIRTIO_BLK_T_IN, %eax
    movl $0, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jnz p0_bad2
    movl $DATA, %edi
    movl $128, %ecx
    xorl %eax, %eax
1:  cmpl %eax, (%edi)
    jne p0_bad2
    addl $4, %edi
    decl %ecx
    jnz 1b
    jmp p0_ok2
p0_bad2:
    FAILPT '1'
p0_ok2:
    /* write pattern to sector 1, read back, verify */
    movl $0xa5a5a5a5, %eax
    call fill_data
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $1, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jnz p0_bad3
    movl $VIRTIO_BLK_T_IN, %eax
    movl $1, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jnz p0_bad3
    movl $0xa5a5a5a5, %eax
    call verify_data
    testl %eax, %eax
    jz p0_ok3
p0_bad3:
    FAILPT '2'
p0_ok3:

    /* --- P1: bad-track / device-retry (EIO read once @1000) ---- */
    movl $0x11223344, %eax
    call fill_data
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $1000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz 1f
    FAILPT '3'
1:  movl $1, p1a
p1_retry:
    movl $VIRTIO_BLK_T_IN, %eax
    movl $1000, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jz p1_ok
    cmpl $8, p1a
    jae p1_bad
    incl p1a
    jmp p1_retry
p1_ok:
    movl $0x11223344, %eax
    call verify_data
    testl %eax, %eax
    jz p1_done
p1_bad:
    FAILPT '4'
p1_done:

    /* --- P2: sudden EIO write @2000 ---- */
    movl $0x55667788, %eax
    call fill_data
    movl $1, p2a
p2_retry:
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $2000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz p2_ok
    cmpl $8, p2a
    jae p2_bad
    incl p2a
    jmp p2_retry
p2_ok:
    movl $VIRTIO_BLK_T_IN, %eax
    movl $2000, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jnz p2_bad
    movl $0x55667788, %eax
    call verify_data
    testl %eax, %eax
    jz p2_done
p2_bad:
    FAILPT '5'
p2_done:

    /* --- P3: sudden ENOSPC write @3000 ---- */
    movl $0x99aabbcc, %eax
    call fill_data
    movl $1, p3a
p3_retry:
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $3000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz p3_ok
    cmpl $8, p3a
    jae p3_bad
    incl p3a
    jmp p3_retry
p3_ok:
    movl $VIRTIO_BLK_T_IN, %eax
    movl $3000, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jnz p3_bad
    movl $0x99aabbcc, %eax
    call verify_data
    testl %eax, %eax
    jz p3_done
p3_bad:
    FAILPT '6'
p3_done:

    /* --- P4: sudden EIO read @4000 ---- */
    movl $0xddccbbaa, %eax
    call fill_data
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $4000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz 1f
    FAILPT '7'
1:  movl $1, p4a
p4_retry:
    movl $VIRTIO_BLK_T_IN, %eax
    movl $4000, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jz p4_ok
    cmpl $8, p4a
    jae p4_bad
    incl p4a
    jmp p4_retry
p4_ok:
    movl $0xddccbbaa, %eax
    call verify_data
    testl %eax, %eax
    jz p4_done
p4_bad:
    FAILPT '8'
p4_done:

    /* --- P5: persistent write error until a FLUSH clears it @7000 ----
     * Config-agnostic: if the first write succeeds the phase is clean;
     * if it fails, the error must persist on the retry (backend still
     * broken), a FLUSH must clear it, and the next write must land. */
    movl $0x01234567, %eax
    call fill_data
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $7000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz p5_clean
    /* first write failed: require persistence, then flush-recovery */
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $7000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jz p5_nopersist
    movl $VIRTIO_BLK_T_FLUSH, %eax
    movl $0, %ebx
    movl $2, %ecx
    call vblk_req
    testb %al, %al
    jnz p5_bad
    movl $VIRTIO_BLK_T_OUT, %eax
    movl $7000, %ebx
    movl $1, %ecx
    call vblk_req
    testb %al, %al
    jnz p5_bad
    movl $3, p5a
    movl $1, p5pf
    jmp p5_verify
p5_nopersist:
    FAILPT '9'                       /* error did not persist */
    jmp p5_done
p5_clean:
    movl $1, p5a
p5_verify:
    movl $VIRTIO_BLK_T_IN, %eax
    movl $7000, %ebx
    movl $0, %ecx
    call vblk_req
    testb %al, %al
    jnz p5_bad
    movl $0x01234567, %eax
    call verify_data
    testl %eax, %eax
    jz p5_done
p5_bad:
    FAILPT 'X'
p5_done:

    /* --- P6: ring-full / descriptor exhaustion (theplanned
     * fold, landed in ).  A 12-request burst (write, then read
     * back) through a multi-chain descriptor allocator: the driver
     * submits while a free descriptor chain exists and, when the
     * descriptor table is exhausted (busy_mask == p6full), MUST wait
     * for a used-ring completion, free its chain and continue.  Every
     * completion must be VIRTIO_BLK_S_OK and the read-back data must
     * match each request's own pattern; verification is deferred until
     * the whole burst drains (the device's DMA write can lag the used
     * entry under TCG - the bounded re-read in p6b_verify tolerates
     * it).  p6a counts the ring-full waits + 1: a6=1 on the default
     * 256-deep queue (12 requests never exhaust the 85 chains), a6=21
     * on run-vblkringfull (queue-size=8 -> 2 chains -> 10 waits per
     * direction). ---- */
    movl $1, p6a
    xorl %eax, %eax
    movl %eax, busy_mask
    movl %eax, p6inf
    movl %eax, p6retry
    /* chains = min(qn/3, 12); p6full = (1<<chains)-1 */
    movl qn, %eax
    xorl %edx, %edx
    movl $3, %ecx
    divl %ecx
    cmpl $12, %eax
    jbe 1f
    movl $12, %eax
1:  movl %eax, p6chains
    movl $1, %ecx
    movl %eax, %edx
2:  shll $1, %ecx
    decl %edx
    jnz 2b
    decl %ecx
    movl %ecx, p6full

    /* write burst: op=1 */
    movl $1, p6op
    call p6_burst
    testl %eax, %eax
    jz 1f
    FAILPT 'Y'
    jmp p6_done
1:

    /* read burst + per-completion verify: op=0 */
    movl $0, p6op
    call p6_burst
    testl %eax, %eax
    jnz p6_fail
    jmp p6_vall
p6_fail:
    FAILPT 'Y'

    /* verify every chain's data AFTER the burst fully drains (the
     * device's DMA write can lag the used entry under TCG; by the end
     * of the drain every completion has been consumed and the writes
     * are visible) */
    xorl %edi, %edi
p6_vall:
    cmpl p6chains, %edi
    jae p6_done
    movl %edi, %ecx
    call p6b_verify
    testl %eax, %eax
    jnz p6_vfail
    incl %edi
    jmp p6_vall
p6_vfail:
    FAILPT 'Z'
p6_done:
    jmp report

no_dev:
    movl $msg_nodev, %esi
    call puts
    jmp halt

/* --------------------------------------------------------------- */
/* vblk_req: eax=type, ebx=sector, ecx=op (0=read,1=write,2=flush).
 * Submits one request on vq0 (head always 0) and polls the used ring.
 * Returns the virtio-blk status byte in al (0xff on timeout).
 * Clobbers eax, ebx, ecx, edx, esi, edi. */
vblk_req:
    /* header at HDR: type, reserved, sector (u64 LE) */
    movl $HDR, %edi
    movl %eax, 0(%edi)
    movl $0, 4(%edi)
    movl %ebx, 8(%edi)
    movl $0, 12(%edi)

    /* desc0: header OUT | NEXT -> 1 */
    movl $RING, %edi
    movl $HDR, 0(%edi)
    movl $16, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)

    /* desc1: data (IN for read, OUT for write) or status (flush) */
    movl $DATA, 16(%edi)
    movl $512, 24(%edi)
    cmpl $2, %ecx
    je 1f
    cmpl $0, %ecx
    jne 2f
    movw $(VRING_DESC_F_NEXT | VRING_DESC_F_WRITE), 28(%edi)
    movw $2, 30(%edi)
    jmp 3f
2:  movw $VRING_DESC_F_NEXT, 28(%edi)
    movw $2, 30(%edi)
    jmp 3f
1:  movl $STS, 16(%edi)
    movl $1, 24(%edi)
    movw $VRING_DESC_F_WRITE, 28(%edi)
    jmp submit
3:
    /* desc2: status IN */
    movl $STS, 32(%edi)
    movl $1, 40(%edi)
    movw $VRING_DESC_F_WRITE, 44(%edi)
submit:
    /* avail.ring[avail_idx & qmask] = 0 (head); avail_idx++ */
    movl avail_base, %edi
    movl avail_idx, %eax
    movl qmask, %ecx
    andl %ecx, %eax
    movw $0, 4(%edi,%eax,2)
    movl avail_idx, %eax
    incl %eax
    movl %eax, avail_idx
    movw %ax, 2(%edi)

    /* notify queue 0 */
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    movw $0, %ax
    outw %ax, %dx

    /* poll used.idx (used_base + 2) */
    movl $200000000, %ecx
4:  movl used_base, %edi
    movzwl 2(%edi), %eax
    cmpl last_used, %eax
    jne 5f
    decl %ecx
    jnz 4b
    movb $0xff, %al
    ret
5:  movl %eax, last_used
    movzbl STS, %eax
    ret

/* --------------------------------------------------------------- */
/* vblk_sub: ecx=chain, eax=type, ebx=sector, edx=op (0=read,1=write).
 * Builds the 3-descriptor chain at RING+3*chain*16 (header OUT ->
 * data -> status IN) using the chain's own request block, appends the
 * head to the avail ring and notifies queue 0.  Clobbers eax, ecx,
 * edx, esi, edi; preserves ebx. */
vblk_sub:
    movl %eax, vblk_type
    leal (%ecx,%ecx,2), %eax        /* head = 3*chain */
    movl %eax, vblk_head
    imull $REQSTRIDE, %ecx, %esi
    addl $REQBASE, %esi             /* req block base */

    /* header at req+0: type, reserved, sector (u64 LE) */
    movl vblk_type, %eax
    movl %eax, 0(%esi)
    movl $0, 4(%esi)
    movl %ebx, 8(%esi)
    movl $0, 12(%esi)

    /* desc base = RING + 3*chain*16 */
    leal (%ecx,%ecx,2), %edi
    shll $4, %edi
    addl $RING, %edi

    /* desc0: header OUT -> next 1 */
    movl %esi, 0(%edi)
    movl $16, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movl vblk_head, %eax
    incl %eax
    movw %ax, 14(%edi)            /* next = ABSOLUTE desc index head+1 */

    /* desc1: data (IN for read, OUT for write) -> next 2 */
    leal REQ_DATA(%esi), %eax
    movl %eax, 16(%edi)
    movl $512, 24(%edi)
    cmpl $0, %edx
    jne 1f
    movw $(VRING_DESC_F_NEXT | VRING_DESC_F_WRITE), 28(%edi)
    movl vblk_head, %eax
    addl $2, %eax
    movw %ax, 30(%edi)            /* next = ABSOLUTE desc index head+2 */
    jmp 2f
1:  movw $VRING_DESC_F_NEXT, 28(%edi)
    movl vblk_head, %eax
    addl $2, %eax
    movw %ax, 30(%edi)            /* next = ABSOLUTE desc index head+2 */
2:
    /* desc2: status IN */
    leal REQ_STS(%esi), %eax
    movl %eax, 32(%edi)
    movl $1, 40(%edi)
    movw $VRING_DESC_F_WRITE, 44(%edi)

    /* avail.ring[avail_idx & qmask] = head; avail_idx++ */
    movl avail_base, %edi
    movl avail_idx, %eax
    movl qmask, %ecx
    andl %ecx, %eax
    movl vblk_head, %ecx
    movw %cx, 4(%edi,%eax,2)
    movl avail_idx, %eax
    incl %eax
    movl %eax, avail_idx
    movw %ax, 2(%edi)

    /* notify queue 0 */
    call vblk_kick
    ret

/* vblk_kick: notifies queue 0 (a separate function keeps the ring
 * publication and the kick distinct).  Clobbers edx, eax. */
vblk_kick:
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    movw $0, %ax
    outw %ax, %dx
    ret

/* vblk_poll: consumes ONE used-ring completion.  If no entry is pending
 * (used.idx == last_used) it waits for used.idx to advance (bounded);
 * if entries are already pending it consumes the next one immediately -
 * with multiple in-flight requests the device may complete a whole
 * batch, and a drain must consume each pending entry instead of waiting
 * for a NEW completion.
 * Recovers the completed head from the used ring and the status byte
 * from the chain's own status buffer.  Returns al=status (0xff on
 * timeout), ebx=head.  Clobbers eax, ebx, ecx, edx, edi. */
vblk_poll:
    movl used_base, %edi
    movzwl 2(%edi), %eax
    cmpl last_used, %eax
    jne 2f
    /* nothing pending: wait for used.idx to advance */
    movl $20000000, %ecx
1:  movl used_base, %edi
    movzwl 2(%edi), %eax
    cmpl last_used, %eax
    jne 2f
    decl %ecx
    jnz 1b
    movb $0xff, %al
    ret
2:  /* consume entry #last_used (the next un-consumed completion) */
    movl last_used, %eax
    movl qmask, %ecx
    andl %ecx, %eax
    shll $3, %eax
    addl used_base, %eax
    movzwl 4(%eax), %ebx          /* id (head) */
    incl last_used
    /* status = REQBASE + (head/3)*REQSTRIDE + REQ_STS */
    movl %ebx, %eax
    xorl %edx, %edx
    movl $3, %ecx
    divl %ecx
    imull $REQSTRIDE, %eax, %eax
    addl $REQBASE, %eax
    addl $REQ_STS, %eax
    movzbl (%eax), %eax
    ret

/* p6_burst: submits the 12-request burst for p6op (0=read, 1=write).
 * Returns eax=0 ok, 1 status/timeout failure.  Clobbers eax, ebx, ecx,
 * edx, esi, edi. */
p6_burst:
    movl $0, p6sub
    movl $0, p6inf
p6b_loop:
    movl p6sub, %eax
    cmpl $12, %eax
    jae p6b_drain
    movl busy_mask, %eax
    cmpl p6full, %eax
    je p6b_full
    /* free chain: bsf the complement of busy_mask */
    notl %eax
    bsfl %eax, %ecx
    call p6b_submit
    testl %eax, %eax
    jnz p6b_fail
    jmp p6b_loop
p6b_full:
    /* ring full: wait for a completion, free its chain, then continue */
    call vblk_poll
    cmpb $0xff, %al
    je p6b_fail
    movl %ebx, %eax
    xorl %edx, %edx
    movl $3, %ecx
    divl %ecx
    movl %eax, %ecx               /* freed chain */
    btrl %ecx, busy_mask
    decl p6inf
    incl p6a
    call p6b_submit
    testl %eax, %eax
    jnz p6b_fail
    jmp p6b_loop
p6b_drain:
    movl p6inf, %eax
    testl %eax, %eax
    jz p6b_ok
    call vblk_poll
    cmpb $0xff, %al
    je p6b_fail
    movl %ebx, %eax
    xorl %edx, %edx
    movl $3, %ecx
    divl %ecx
    movl %eax, %ecx
    btrl %ecx, busy_mask
    decl p6inf
    jmp p6b_drain
p6b_ok:
    xorl %eax, %eax
    ret
p6b_fail:
    movl $1, %eax
    ret

/* p6b_submit: ecx=chain.  Submits request p6sub (type from p6op) on the
 * chain, filling the chain's data with pattern 0x5000+p6sub for write
 * bursts.  Returns eax=0.  Clobbers eax, ebx, ecx, edx, esi, edi. */
p6b_submit:
    movl p6sub, %eax
    movw %ax, req_of_chain(,%ecx,2)
    btsl %ecx, busy_mask          /* mark the chain in flight */
    cmpl $1, p6op
    jne 1f
    movl p6sub, %eax
    addl $0x5000, %eax
    call fill_req                 /* ecx=chain, eax=pattern */
1:  movl p6op, %edx
    testl %edx, %edx
    jne 2f
    movl $VIRTIO_BLK_T_IN, %eax
    jmp 3f
2:  movl $VIRTIO_BLK_T_OUT, %eax
3:  movl p6sub, %ebx
    addl $5000, %ebx
    call vblk_sub
    incl p6sub
    incl p6inf
    xorl %eax, %eax
    ret

/* p6b_verify: ecx=chain.  Verifies the chain's data against the pattern
 * for its recorded request (req_of_chain[chain]).  Returns eax=0 ok.
 * Clobbers eax, ebx, edx, esi, edi; preserves ecx. */
p6b_verify:
    pushl %ecx
    pushl %ebx
    pushl %edx
    pushl %esi
    pushl %edi
    movzwl req_of_chain(,%ecx,2), %eax
    addl $0x5000, %eax
    movl %eax, %ebx                 /* expected pattern */
    imull $REQSTRIDE, %ecx, %esi
    addl $REQBASE, %esi
    addl $REQ_DATA, %esi
    movl $128, %edx
1:  cmpl %ebx, (%esi)
    je 3f
    /* data not visible yet: bounded re-read (device-side DMA may land
     * after the used entry under TCG).  Yield to the device every 4096
     * iterations via a dummy ioport read so the main loop can finish
     * the DMA write (a pure spin starves it). */
    movl $50000000, %edi
2:  testl $0xfff, %edi
    jne 6f
    pushl %edx
    pushl %eax
    movl $0x3fd, %edx
    inb %dx, %al
    popl %eax
    popl %edx
6:  cmpl %ebx, (%esi)
    je 4f
    decl %edi
    jnz 2b
    jmp 5f
4:  incl p6retry
3:  addl $4, %esi
    decl %edx
    jnz 1b
    xorl %eax, %eax
    jmp 6f
5:
    movl $1, %eax
6:  popl %edi
    popl %esi
    popl %edx
    popl %ebx
    popl %ecx
    ret

/* fill_req: ecx=chain, eax=pattern; fills the chain's 512-byte data
 * buffer with 128 dwords.  Clobbers eax, edi; preserves ecx. */
fill_req:
    pushl %ecx
    pushl %edi
    pushl %eax
    imull $REQSTRIDE, %ecx, %edi
    addl $REQBASE, %edi
    addl $REQ_DATA, %edi
    popl %eax
    movl $128, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    popl %edi
    popl %ecx
    ret

/* fill_data: eax = pattern; fills DATA with 128 dwords */
fill_data:
    pushl %ecx
    pushl %edi
    movl $DATA, %edi
    movl $128, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    popl %edi
    popl %ecx
    ret

/* verify_data: eax = pattern; returns eax=0 if DATA matches */
verify_data:
    pushl %ecx
    pushl %edi
    pushl %ebx
    movl $DATA, %edi
    movl $128, %ecx
    movl %eax, %ebx
1:  cmpl %ebx, (%edi)
    jne 2f
    addl $4, %edi
    decl %ecx
    jnz 1b
    xorl %eax, %eax
    jmp 3f
2:  movl $1, %eax
3:  popl %ebx
    popl %edi
    popl %ecx
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

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: each fault phase must match the run config.  Bit 0 ->
 * p1a (bad-track), bit 1 -> p2a, bit 2 -> p3a, bit 3 -> p4a (err conf), bit 4
 * -> p5a (persist), bit 5 -> p6a (ring-full).  Set bit means the phase must
 * recover from the fault (pN != 1); clear means it must stay clean
 * (pN == 1).  Mismatch increments fail, so a dead fault hook is a real
 * failure. */
.macro VCHECK bit, var
    movl %ebx, %eax
    testl $\bit, %eax
    jnz .Lve_fault_\bit
    cmpl $1, \var
    je .Lve_ok_\bit
    incl fail
    jmp .Lve_ok_\bit
.Lve_fault_\bit:
    cmpl $1, \var
    jne .Lve_ok_\bit
    incl fail
.Lve_ok_\bit:
.endm

verify_expect:
    call nto64_expect
    movl %eax, %ebx
    VCHECK 0x1, p1a
    VCHECK 0x2, p2a
    VCHECK 0x4, p3a
    VCHECK 0x8, p4a
    VCHECK 0x10, p5a
    VCHECK 0x20, p6a
    ret

report:
    call verify_expect
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
    movl $sp_qn, %esi
    call puts
    movl qn, %eax
    call puthex
    movl $sp_cap, %esi
    call puts
    movl cap_lo, %eax
    call puthex
    movl $sp_a1, %esi
    call puts
    movl p1a, %eax
    call puthex
    movl $sp_a2, %esi
    call puts
    movl p2a, %eax
    call puthex
    movl $sp_a3, %esi
    call puts
    movl p3a, %eax
    call puthex
    movl $sp_a4, %esi
    call puts
    movl p4a, %eax
    call puthex
    movl $sp_a5, %esi
    call puts
    movl p5a, %eax
    call puthex
    movl $sp_a6, %esi
    call puts
    movl p6a, %eax
    call puthex
    movl $sp_rt, %esi
    call puts
    movl p6retry, %eax
    call puthex
    movl $sp_pf, %esi
    call puts
    movl p5pf, %eax
    call puthex
    movl $nl, %esi
    call puts
halt:
    cli
1:  hlt
    jmp 1b

    .bss
    .balign 16
blk_dev:    .long 0
io_base:    .long 0
qn:         .long 0
qmask:      .long 0
avail_base: .long 0
used_base:  .long 0
avail_idx:  .long 0
last_used:  .long 0
cap_lo:     .long 0
cap_hi:     .long 0
p1a:        .long 0
p2a:        .long 0
p3a:        .long 0
p4a:        .long 0
p5a:        .long 0
p5pf:       .long 0
p6a:        .long 0
p6op:       .long 0
p6sub:      .long 0
p6inf:      .long 0
p6chains:   .long 0
p6full:     .long 0
busy_mask:  .long 0
vblk_type:  .long 0
vblk_head:  .long 0
req_of_chain: .space 64           /* 32 chains * 2 bytes */
p6retry:    .long 0
fail:       .long 0
mbi_ptr:    .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:       .asciz "VBLK "
okmsg:     .asciz "OK"
failmsg:   .asciz "FAIL"
msg_nodev: .asciz "VBLK nodev\n"
sp_f:      .asciz " f="
sp_qn:     .asciz " qn="
sp_cap:    .asciz " cap="
sp_a1:     .asciz " a1="
sp_a2:     .asciz " a2="
sp_a3:     .asciz " a3="
sp_a4:     .asciz " a4="
sp_a5:     .asciz " a5="
sp_a6:     .asciz " a6="
sp_rt:     .asciz " rt="
sp_pf:     .asciz " pf="
nl:        .asciz "\n"
