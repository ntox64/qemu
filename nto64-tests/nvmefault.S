/* SPDX-License-Identifier: BSD-2-Clause */

/* nvmefault.S - freestanding multiboot NVMe fault slice.
 *
 * Extends theNVMe bring-up into the fault matrix:
 *   cold-data/wear: blkdebug [latency] + [inject-error] rules on the
 *     namespace drive make a cold LBA read pay ~25 ms (measured with
 *     rdtsc) and a wear LBA fail once (NVME_UNRECOVERED_READ) before a
 *     bounded driver retry recovers it with the data intact;
 *   surprise unplug with outstanding queues: 8 reads are held in
 *     flight by a 50 ms blkdebug latency, then the guest writes the
 *     NTOU magic to the reserved BAR0 offset 0x5c; the stock nvme
 *     drops every completion from then on, MMIO reads 0xffffffff and
 *     config reads 0xff, so the driver sees the card vanish with its
 *     commands outstanding;
 *   PCIe link downgrade/mismatch: with nto64-link-gen=3 the device
 *     advertises gen3 in LNKCAP while the negotiated LNKSTA stays
 *     gen1; the guest parses the capability and reports the mismatch.
 *   spec-breaking state machines:
 *     nto64-rdy-lie-start=N (the Nth CC.EN start never asserts
 *     CSTS.RDY and does not set FAILED either - the driver's bounded
 *     start wait times out and it resets + retries, run-nvmerdylie);
 *     nto64-stall-lba=X (a transfer over X stalls the controller with
 *     MMIO/CSTS alive - "MMIO alive, DMA dead" - and a controller
 *     reset REVIVES it, run-nvmedmarev); nto64-dead-cq=N (completions
 *     for CQ N are dropped while the rest of the controller works -
 *     delete/recreate the queue pair recovers, run-nvmedeadq).
 *   AER + namespace edge-state shapes.  The
 *     SMART async-event cycle (Set Features AEC, Async Event Request,
 *     the NTAS trigger, Get Log Page SMART with RAE=0) runs on every
 *     target (phase 4a, ae=2); the NS-not-ready / Format-NVM-stall /
 *     write-protect windows are guest-armed via the NTNR/NTFS/NTWP
 *     reserved-BAR magics and only engage when the corresponding
 *     nto64-* property is set (run-nvmenotready / run-nvmeformatstall
 *     / run-nvmewp).  The queue depth is 32 so the CQ never wraps
 *     mid-run; the pollers still track the CQ phase (cq_phase toggles
 *     at the wrap) so a future queue-depth change cannot re-open the
 *     stale-phase-bit class of bugs.
 *   Reservation Conflict on a multi-controller
 *     subsystem.  The run-nvmeresv target places two controllers on
 *     one nvme-subsys sharing a namespace; the guest arms the NTRC
 *     reserved-BAR magic and the sibling controller's reservation
 *     makes every I/O here fail with NVME_NS_RESV_CONFLICT (0x0083,
 *     DNR=0) until the window expires (phase 4e, rc=2 on that target,
 *     rc=1 everywhere else; mc counts the controllers found: 2 on the
 *     subsystem target, 1 otherwise).
 *
 * Polling-only (no MSI-X/IDT/AP needed): CQ1 is created with IEN=0.
 *
 * Run (make run-nvmefault): -machine q35 -smp 1 -m 128
 *   -device nvme,serial=nvme0,max_ioqpairs=4,msix_qsize=6,nto64-link-gen=3
 *   -drive file=blkdebug:nvme-cold.conf:64M.img,if=none,id=drv0,format=raw
 *   -device nvme-ns,drive=drv0,nsid=1,bus=nvme0
 *
 * Expected: 'NVME-FAULT c=00000003 s=00000001 d=00000001
 * ho=... co=... ws=00000081 wr=00000001 ud=00000001 p=00000008
 * rc=00000001 mc=00000001 f=00000000'
 */

/* NVMe register offsets in BAR0 */
.equ NVME_CC,    0x14
.equ NVME_CSTS,  0x1c
.equ NVME_AQA,   0x24
.equ NVME_ASQ,   0x28
.equ NVME_ACQ,   0x30
.equ NVME_SQTDBL, 0x1000      /* SQ0TDBL; stride 8 per queue pair */
.equ NVME_CQHDBL, 0x1004      /* CQ0HDBL */
.equ SQ1TDBL,    0x1008       /* SQ1TDBL */
.equ CQ1HDBL,    0x100c       /* CQ1HDBL */
.equ SQ2TDBL,    0x1010       /* SQ2TDBL */
.equ CQ2HDBL,    0x1014       /* CQ2HDBL */

.equ QSIZE,       32           /* entries per queue (never wraps) */
.equ ASQ_ADDR,    0x13000      /* admin SQ (16 x 64B) */
.equ ACQ_ADDR,    0x14000      /* admin CQ (16 x 16B) */
.equ IDNS,        0x15000      /* identify namespace buffer */
.equ CMD_TMPL,    0x17000      /* 64-byte command template */
.equ CQ1,         0x200000     /* I/O CQ1 (16 x 16B) */
.equ SQ1,         0x201000     /* I/O SQ1 (16 x 64B) */
.equ WB_HOT,      0x202000     /* 4 KiB buffers */
.equ WB_COLD,     0x203000
.equ WB_WEAR,     0x204000
.equ WB_UNP,      0x205000
.equ CQ2,         0x206000     /* I/O CQ2 */
.equ SQ2,         0x207000
.equ WB_Q2,       0x208000
.equ WB_NR,       0x209000     /* buffers */
.equ WB_FMT,      0x20a000
.equ SMART_LOG,   0x20b000     /* 512-byte SMART log buffer */
.equ WB_RV,       0x20c000     /* buffer */

.equ HOT_LBA,     0
.equ WEAR_LBA,    0x4000
.equ COLD_LBA,    0x8000
.equ UNP_LBA,     0xa000
.equ STUCK_LBA,   0xb000
.equ STALL_LBA,   0xc000
.equ STALL_REC_LBA, 0xd000
.equ RPL_LBA,     0xe000
.equ DEADQ_LBA,   0xf000
.equ NR_LBA,      0x10000   /* NS-not-ready phase (64M image) */
.equ FMT_LBA,     0x11000   /* format-in-progress phase */
.equ WP_LBA,      0x12000   /* write-protect phase */
.equ RESV_LBA,    0x13000   /* reservation-conflict phase */

.equ NTO64_UNPLUG_REG,   0x5c
.equ NTO64_UNPLUG_MAGIC, 0x4e544f55 /* "NTOU" */
.equ NTO64_RDYLIE_REG,   0x60
.equ NTO64_RDYLIE_MAGIC, 0x4e54524c /* "NTRL" */
.equ NTO64_SMART_REG,    0x64
.equ NTO64_SMART_MAGIC,  0x4e544153 /* "NTAS" */
.equ NTO64_NSNR_REG,     0x68
.equ NTO64_NSNR_MAGIC,   0x4e544e52 /* "NTNR" */
.equ NTO64_FMTS_REG,     0x6c
.equ NTO64_FMTS_MAGIC,   0x4e544653 /* "NTFS" */
.equ NTO64_WP_REG,       0x70
.equ NTO64_WP_MAGIC,     0x4e545750 /* "NTWP" */
.equ NTO64_RESV_REG,     0x74
.equ NTO64_RESV_MAGIC,   0x4e545243 /* "NTRC" */

.equ NVME_NS_NOT_READY,      0x0082
.equ NVME_FORMAT_IN_PROGRESS, 0x0084
.equ NVME_NS_WRITE_PROTECTED, 0x0020
.equ NVME_NS_RESV_CONFLICT,   0x0083
.equ NVME_AER_TYPE_SMART,    1
.equ NVME_AER_INFO_RELIABILITY, 0
.equ NVME_AER_INFO_SPARE,    2
.equ NVME_LOG_SMART,         0x02

/*
 * The completion queues live in guest RAM, so a poll loop that never
 * leaves the vCPU can spin past a completion the device's bottom half
 * has not been able to run yet (single-threaded TCG runs BHs when the
 * vCPU yields).  Every blocking completion poll does this first: one
 * device-register read is enough to hand the main loop its turn.
 * Preserves the loop's accumulator.
 */
.macro cq_yield
    pushl %eax
    movl bar0, %eax
    movl NVME_CSTS(%eax), %eax
    popl %eax
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
    movl $0, fail
    /* The CQ phase starts at 1 on a fresh controller and toggles every
     * QSIZE (32) completions; the pollers below compare against these
     * instead of the raw bit, so a ring wrap can never read a stale
     * phase-1 slot.  admin_phase tracks the same thing for queue 0:
     * every poll of the admin CQ compares its phase against this
     * variable, and every path that re-arms the queues after a
     * controller reset sets it back to 1 (the device restarts the
     * admin CQ phase at 1 when CC.EN goes 0 -> 1). */
    movl $1, admin_phase
    movl $1, cq_phase
    movl $1, cq2_phase

    /* mask the legacy PICs: this test installs no IDT, so keep IRQ0
     * from spraying SeaBIOS's handlers while we poll CQs */
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    /* --- find the NVMe device (class 0x010802 or 8086:5845) ----
     * with nto64-late-attach-ms the device starts ABSENT and hot-plugs
     * in later: the driver keeps rescanning until it appears. */
    movl $0, la
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
    incl la
    movl $10000000, %ecx
1:  decl %ecx
    jnz 1b
    cmpl $60, la
    jae scan_fail
    xorl %edi, %edi
    jmp scan
scan_fail:
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

nvme_found:
    movl %edi, nvme_dev

    /* enable memory space, read BAR0 low dword */
    movl $4, %ecx
    call pcicfg
    orl $2, %eax
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    movl nvme_dev, %edi
    movl $0x10, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    testl %eax, %eax
    jnz bar_ok
    /* a late-attached (hot-plug) device was never assigned a BAR by
     * firmware: the driver programs one itself (hot-plug semantics) */
    movl nvme_dev, %edi
    movl $0x10, %ecx
    movl $0xd0000000, %eax
    movl %edi, %esi
    movl $0x10, %ecx
    call pcicfg_write
    movl nvme_dev, %edi
    movl $4, %ecx
    call pcicfg
    orl $6, %eax               /* memory space + bus master */
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    movl $0xd0000000, %eax
bar_ok:
    movl %eax, bar0
    movl %eax, bar0_save

    /* --- count the remaining NVMe controllers ----
     * the reservation-conflict target runs two controllers on one
     * subsystem sharing a namespace; mc proves the shape is present
     * (2 there, 1 everywhere else). */
    movl $1, mc
    movl nvme_dev, %edi
    incl %edi
mc_scan:
    cmpl $32, %edi
    jae mc_done
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je mc_next
    cmpl $0x58458086, %eax
    je mc_found
    movl $0x08, %ecx
    call pcicfg
    andl $0xffffff00, %eax
    cmpl $0x01080200, %eax
    jne mc_next
mc_found:
    incl mc
mc_next:
    incl %edi
    jmp mc_scan
mc_done:

    /* --- PCIe link: walk the capability list for id 0x10 ---- */
    movl nvme_dev, %edi
    movl $0x34, %ecx
    call pcicfg
    andl $0xff, %eax
    movl %eax, exp_cap
cap_loop:
    movl exp_cap, %ebx
    testl %ebx, %ebx
    jz cap_bad
    movl %ebx, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xff, %edx           /* cap id */
    cmpl $0x10, %edx           /* PCIe */
    je cap_found
    shrl $8, %eax
    andl $0xff, %eax           /* next cap pointer */
    movl %eax, exp_cap
    jmp cap_loop
cap_bad:
    movl $msg_cap, %esi
    call puts
    incl fail
    jmp report
cap_found:
    /* LNKCAP at cap+0x0c (dword): MLS = bits 3:0 */
    movl nvme_dev, %edi
    movl exp_cap, %ebx
    leal 0x0c(%ebx), %ecx
    call pcicfg
    andl $0xf, %eax
    movl %eax, lnk_cap_gen
    /* LNKSTA at cap+0x12 (word): CLS = bits 3:0 of the word, i.e.
     * bits 19:16 of the dword at cap+0x10 (CF8/CFC dword access) */
    movl nvme_dev, %edi
    movl exp_cap, %ebx
    leal 0x10(%ebx), %ecx
    call pcicfg
    shrl $16, %eax
    andl $0xf, %eax
    movl %eax, lnk_sta_gen
    /* d = mismatch flag: supported max speed > negotiated speed */
    movl lnk_cap_gen, %eax
    cmpl lnk_sta_gen, %eax
    jbe 1f
    movl $1, lnk_dwng
    jmp 2f
1:  movl $0, lnk_dwng
2:
    /* assert the downgraded/mismatched link: negotiated gen1, cap
     * gen3 (nto64-link-gen=3), mismatch set */
    movl lnk_sta_gen, %eax
    cmpl $1, %eax
    jne link_bad
    movl lnk_cap_gen, %eax
    cmpl $3, %eax
    jne link_bad
    movl lnk_dwng, %eax
    cmpl $1, %eax
    je link_ok
link_bad:
    movl $msg_link, %esi
    call puts
    incl fail
link_ok:

    /* --- controller enable with the attach/reset storm ladder ----
     * CC.EN=1 normally -> CSTS.RDY=1; with nto64-start-fail=N the
     * first N starts fail (CSTS.FAILED, run-nvmeattach/run-nvmedead).
     * The driver retries the reset ladder up to 5 times; success
     * continues, exhausting the bound is a clean "device failed"
     * outcome (the driver must not hang). */
    movl $0, sf
    movl $0, gv
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
    /* arm the RDY-lie for the next controller start (guest-only
     * magic, BIOS-proof: SeaBIOS's own NVMe probe would consume the
     * start count otherwise) */
    movl bar0, %ebp
    movl $NTO64_RDYLIE_MAGIC, %eax
    movl %eax, NTO64_RDYLIE_REG(%ebp)
    movl $0, storm_try
storm_loop:
    movl $0x001f001f, NVME_AQA(%ebp)   /* admin queues: 32 entries */
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)    /* EN, IOCQES=4, IOSQES=6 */
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
storm_wait:
    movl NVME_CSTS(%ebp), %eax
    cmpl $0xffffffff, %eax
    je storm_hung
    testl $1, %eax
    jnz storm_ok
    testl $2, %eax              /* CSTS.FAILED */
    jnz storm_fail
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae storm_timeout
    cmpl $1000000000, %eax
    jb storm_wait
storm_timeout:
    /* CSTS stayed 0 (no RDY, no FAILED, not all-ones): with
     * nto64-rdy-lie-start the Nth start lied - the driver treats the
     * bounded-wait timeout as a start failure and resets + retries. */
    movl $1, lie
    jmp storm_retry
storm_fail:
    incl sf
storm_retry:
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)    /* reset and retry */
    movl $10000000, %ecx
1:  movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jz 2f
    decl %ecx
    jnz 1b
    movl $msg_rdy, %esi
    call puts
    incl fail
    jmp report
2:  movl storm_try, %eax
    incl %eax
    movl %eax, storm_try
    cmpl $5, %eax
    jae storm_giveup
    jmp storm_loop
storm_giveup:
    movl $1, gv
    jmp report
storm_hung:
    /* the controller hangs after the start-fail storm: CSTS reads
     * all-ones, and CC.EN=0 is ignored (a hung controller cannot
     * process register writes) - only a PCIe function reset revives */
    movl $1, hg
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)    /* controller reset: expected no-op */
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    movl NVME_CSTS(%ebp), %eax
    cmpl $0xffffffff, %eax
    jne storm_bad
    /* FLR: PCIe Device Control (exp_cap + 8), bit 15 */
    movl nvme_dev, %edi
    movl exp_cap, %ebx
    addl $8, %ebx
    movl %ebx, %ecx
    call pcicfg
    orl $0x8000, %eax
    movl nvme_dev, %edi
    movl exp_cap, %ebx
    addl $8, %ebx
    movl %ebx, %ecx
    call pcicfg_write
    movl $1, fl
    /* wait for the reset, then re-init the BAR (FLR resets config) */
    movl $1000000, %ecx
1:  decl %ecx
    jnz 1b
    /* FLR unmaps the BARs: a driver re-writes the assigned base */
    movl nvme_dev, %edi
    movl $0x10, %ecx
    movl bar0_save, %eax
    movl %edi, %esi
    movl $0x10, %ecx
    call pcicfg_write
    movl nvme_dev, %edi
    movl $4, %ecx
    call pcicfg
    orl $6, %eax               /* memory space + bus master */
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    movl bar0_save, %eax
    movl %eax, bar0
    movl bar0, %ebp
    jmp storm_loop
storm_bad:
    movl $msg_storm, %esi
    call puts
    incl fail
    jmp report
storm_ok:

    /* --- admin: identify namespace 1 (sanity: NSZE >= 64M) ---- */
    call clr_cmd
    movb $6, CMD_TMPL            /* Identify */
    movl $1, CMD_TMPL+4          /* nsid */
    movl $IDNS, CMD_TMPL+24      /* PRP1 */
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40         /* CNS = 0 (namespace) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz adm_bad
    movl IDNS, %eax
    cmpl $0x20000, %eax          /* 131072 sectors = 64 MiB */
    jae ns_ok
adm_bad:
    movl $msg_adm, %esi
    call puts
    incl fail
    jmp report
ns_ok:

    /* --- create CQ1 (qid 1, qsize 16, vector 0, PC, no IEN) ---- */
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl $CQ1, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40       /* qid | (qsize-1)<<16 */
    movl $1, CMD_TMPL+44         /* PC (polling: no IEN) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    /* --- create SQ1 (qid 1, cqid 1, PC, QPRIO 2) ---- */
    call clr_cmd
    movb $1, CMD_TMPL            /* Create I/O SQ */
    movl $SQ1, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $1, %eax
    shll $16, %eax
    orl $((2 << 2) | 1), %eax    /* CQID=1 | QPRIO=2 | PC */
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    /* --- create CQ2/SQ2 (qid 2; the dead-CQ
     * phase drives a second queue pair, other targets leave it idle)
     * ---- */
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl $CQ2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $2, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40       /* qid | (qsize-1)<<16 */
    movl $1, CMD_TMPL+44         /* PC (polling: no IEN) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    call clr_cmd
    movb $1, CMD_TMPL            /* Create I/O SQ */
    movl $SQ2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $2, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $2, %eax
    shll $16, %eax
    orl $((2 << 2) | 1), %eax    /* CQID=2 | QPRIO=2 | PC */
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    jmp queues_ok
q_bad:
    movl $msg_q, %esi
    call puts
    incl fail
    jmp report
queues_ok:

    /* --- Phase 1: cold-data/wear ----
     * Write the 0x55667788 pattern to the four LBAs first (writes are
     * not throttled by the read-only rules), then read them back. */
    movl $WB_HOT, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_HOT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $HOT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad

    movl $WB_COLD, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $COLD_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad

    movl $WB_WEAR, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_WEAR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $WEAR_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad

    movl $WB_UNP, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_UNP, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $UNP_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad

    /* hot read (timed) */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_HOT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $HOT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    movl %eax, hot_delta
    movl $WB_HOT, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* cold read (timed): must be clearly slower than the hot read */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $COLD_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    movl %eax, cold_delta
    movl $WB_COLD, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    /* assert cold > 2*hot and cold > 10M ticks */
    movl hot_delta, %eax
    shll $1, %eax
    cmpl cold_delta, %eax
    ja cold_bad
    movl $10000000, %eax
    cmpl cold_delta, %eax
    ja cold_bad
    jmp cold_ok
cold_bad:
    movl $msg_cold, %esi
    call puts
    incl fail
cold_ok:

    /* wear read: first attempt must fail (NVME_UNRECOVERED_READ),
     * the retry recovers with the data intact */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_WEAR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $WEAR_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    movl %eax, wear_status
    testl %eax, %eax
    jnz wear_retry
    movl $msg_wear, %esi
    call puts
    incl fail
    jmp wear_done
wear_retry:
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_WEAR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $WEAR_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl $WB_WEAR, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl $1, wear_retries
wear_done:
    /* the AER + namespace edge-state phases run
     * HERE (before any phase that can kill or reset the controller),
     * so the controller is alive on every target. */
    call step33_phases

    /* --- Phase 2a: MMIO-alive/DMA-dead stall (run-nvmedmarev) ----
     * A read at STALL_LBA never completes (nvme nto64-stall-lba) but
     * MMIO/CSTS stay alive, and a controller reset REVIVES the
     * controller (unlike the stuck-lba wedge, which dies on the
     * reset).  The driver bounds the wait, checks MMIO is still live,
     * resets, re-initializes (identify + queues) and proves the data
     * path.  Without the property the read completes fast and the
     * phase is skipped. */
    movl $0, sw
    movl $0, sr
    movl $WB_COLD, %edi
    call fill_pattern
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $STALL_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call sq_post
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  cq_yield
    movl cq_head1, %ecx
    shll $4, %ecx
    movl $CQ1, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    andl $1, %edx
    movl cq_phase, %eax
    andl $1, %eax
    cmpl %eax, %edx
    je sw_skip           /* completed: no stall configured */
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae sw_wait_done
    cmpl $1000000000, %eax
    jb 1b
sw_wait_done:
    movl $1, sw
    /* MMIO must still be alive: CSTS readable, not all-ones, RDY set */
    movl bar0, %ebp
    movl NVME_CSTS(%ebp), %eax
    cmpl $0xffffffff, %eax
    je sw_bad
    testl $1, %eax
    jz sw_bad
    /* controller reset: CC.EN=0 - this one REVIVES (no all-ones) */
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)
    movl $10000000, %ecx
1:  movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jz 2f
    decl %ecx
    jnz 1b
    jmp sw_bad
2:  /* Re-enable and re-initialize (admin + queues).  The rings are wiped
     * and the guest pointers/phases re-armed while the controller is
     * still disabled: after CC.EN it may complete the first command at
     * any time, and a wipe afterwards would eat a live completion. */
    movl $0, admin_tail
    movl $0, admin_head
    movl $0, sq_tail1
    movl $0, cq_head1
    movl $0, sq_tail2
    movl $0, cq_head2
    movl $1, admin_phase
    movl $1, cq_phase
    movl $1, cq2_phase
    call zero_rings
    /*
     * Probe for the identity check: plant exactly what an un-wiped ring
     * would still hold at the head of the admin CQ after the controller
     * came back - a phase-1 entry whose CID belongs to no live command -
     * and ask the same check admin_cmd() polls with whether it is a
     * completion.  It has to say no; the real completion is written over
     * this slot (the device's CQ tail starts at 0) with our CID.  A poll
     * that trusts the phase bit alone accepts this entry here and returns
     * its 0x0001 status instead of the command's, so the check cannot rot
     * silently.
     */
    movzwl admin_cid, %edx
    addl $0x8000, %edx              /* a CID no live command carries */
    orl $0x00030000, %edx           /* DW3 high half: phase 1 |
                                     * (NVME_INVALID_OPCODE << 1) */
    movl $0, ACQ_ADDR
    movl $0, ACQ_ADDR+4
    movl $0, ACQ_ADDR+8
    movl %edx, ACQ_ADDR+12
    call adm_ready
    jnc 8f                          /* accepted a stranger's completion */
    jmp 9f
8:  movl $msg_stale, %esi
    call puts
    incl fail
9:
    movl $0x001f001f, NVME_AQA(%ebp)
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)
    movl $10000000, %ecx
1:  movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jnz 2f
    decl %ecx
    jnz 1b
    jmp sw_bad
2:
    call clr_cmd
    movb $6, CMD_TMPL            /* Identify namespace (sanity) */
    movl $1, CMD_TMPL+4
    movl $IDNS, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz sw_bad
    call recreate_queues
    testl %eax, %eax
    jnz sw_bad
    /* round-trip at a fresh LBA proves the revived data path */
    movl $WB_COLD, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $STALL_REC_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz sw_bad
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $STALL_REC_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz sw_bad
    movl $WB_COLD, %esi
    call verify_pattern
    testl %eax, %eax
    jnz sw_bad
    movl $1, sr
    jmp sw_done
sw_skip:
    /* consume the completed read so the next phase starts clean */
    movl cq_head1, %ecx
    incl %ecx
    cmpl $32, %ecx
    jne 3f
    xorl %ecx, %ecx
    xorl $1, cq_phase
3:  movl %ecx, cq_head1
    movl bar0, %eax
    movl %ecx, CQ1HDBL(%eax)
    jmp sw_done
sw_bad:
    movl $msg_dmar, %esi
    call puts
    incl fail
sw_done:

    /* --- Phase 2b: one dead queue (run-nvmedeadq) ----
     * With nto64-dead-cq=2 the completions for CQ2 are dropped (SQ2
     * commands are consumed, MMIO and CQ1 stay alive).  The driver's
     * bounded CQ2 poll times out, it proves q1 still works, deletes +
     * recreates the queue pair (the delete clears the fault) and
     * proves the data path on q2.  Without the property the q2 read
     * completes fast and the phase is skipped. */
    movl $0, dq
    movl $WB_Q2, %edi
    call fill_pattern
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_Q2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $DEADQ_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call sq_post2
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  cq_yield
    movl cq_head2, %ecx
    shll $4, %ecx
    movl $CQ2, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    andl $1, %edx
    movl cq2_phase, %eax
    andl $1, %eax
    cmpl %eax, %edx
    je dq_skip           /* completed: no dead-CQ configured */
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae dq_wait_done
    cmpl $1000000000, %eax
    jb 1b
dq_wait_done:
    movl $1, dq
    /* q1 must still work while q2 is dead */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0x9000, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz dq_bad
    /* delete SQ2 + CQ2 (the delete clears the dead-CQ fault) */
    call clr_cmd
    movb $0, CMD_TMPL            /* Delete I/O SQ */
    movl $2, CMD_TMPL+40         /* cdw10 = qid */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz dq_bad
    call clr_cmd
    movb $4, CMD_TMPL            /* Delete I/O CQ */
    movl $2, CMD_TMPL+40
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz dq_bad
    movl $0, sq_tail2
    movl $0, cq_head2
    movl $1, cq2_phase
    call recreate_q2
    testl %eax, %eax
    jnz dq_bad
    call zero_rings
    /* round-trip on q2 proves the recreated queue */
    movl $WB_Q2, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_Q2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $DEADQ_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call io_cmd2
    testl %eax, %eax
    jnz dq_bad
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_Q2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $DEADQ_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call io_cmd2
    testl %eax, %eax
    jnz dq_bad
    movl $WB_Q2, %esi
    call verify_pattern
    testl %eax, %eax
    jnz dq_bad
    jmp dq_done
dq_skip:
    /* consume the completed read so the next phase starts clean */
    movl cq_head2, %ecx
    incl %ecx
    cmpl $32, %ecx
    jne 3f
    xorl %ecx, %ecx
    xorl $1, cq2_phase
3:  movl %ecx, cq_head2
    movl bar0, %eax
    movl %ecx, CQ2HDBL(%eax)
    jmp dq_done
dq_bad:
    movl $msg_dq, %esi
    call puts
    incl fail
dq_done:

    /* --- Phase 2b: media-recovery wedge (run-nvmestuck) ----
     * A read at STUCK_LBA never completes (nvme nto64-stuck-lba): the
     * controller is alive (CSTS stays RDY) but not servicing.  The
     * driver times out, tries an Abort (also swallowed), then resets
     * the controller - and the reset KILLS the link: CSTS and config
     * read all-ones, the SSD-disappearance scenario.  Without the
     * property the read completes fast and the phase is skipped. */
    movl $0, st
    movl $0, ab
    movl $0, go
    movl $WB_COLD, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $STUCK_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    /* the wedging read: post without waiting, bounded poll */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $STUCK_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call sq_post
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  cq_yield
    movl cq_head1, %ecx
    shll $4, %ecx
    movl $CQ1, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    andl $1, %edx
    movl cq_phase, %eax
    andl $1, %eax
    cmpl %eax, %edx
    je st_skip           /* completed: no wedge configured */
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae st_wait_done
    cmpl $1000000000, %eax
    jb 1b
st_wait_done:
    movl $1, st
    /* Abort the wedged command (opcode 8, SQID 1/CID 0): its
     * completion is also swallowed, so the bounded wait sees nothing */
    call clr_cmd
    movb $8, CMD_TMPL
    movl $1, CMD_TMPL+40          /* cdw10 = (cid 0 << 16) | sqid 1 */
    movl admin_tail, %ecx
    shll $6, %ecx
    addl $ASQ_ADDR, %ecx
    movl $CMD_TMPL, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    movl admin_tail, %ecx
    incl %ecx
    andl $31, %ecx
    movl %ecx, admin_tail
    movl bar0, %eax
    movl %ecx, NVME_SQTDBL(%eax)
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  cq_yield
    movl admin_head, %ecx
    shll $4, %ecx
    movl $ACQ_ADDR, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %eax
    testb $1, %al
    jnz ab_bad           /* unexpected completion: abort was serviced */
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae ab_done
    cmpl $1000000000, %eax
    jb 1b
ab_done:
    movl $1, ab
    /* controller reset: CC.EN=0 - the wedged controller dies on it */
    movl bar0, %ebp
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)
    movl NVME_CSTS(%ebp), %eax
    cmpl $0xffffffff, %eax
    jne go_bad
    movl nvme_dev, %edi
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    jne go_bad
    movl $1, go
    jmp st_done
ab_bad:
    movl $msg_stuck, %esi
    call puts
    incl fail
    jmp report
go_bad:
    movl $msg_stuck, %esi
    call puts
    incl fail
    jmp report
st_skip:
    /* consume the completed read so the next phase starts clean */
    movl cq_head1, %ecx
    incl %ecx
    cmpl $32, %ecx
    jne 3f
    xorl %ecx, %ecx
    xorl $1, cq_phase
3:  movl %ecx, cq_head1
    movl bar0, %eax
    movl %ecx, CQ1HDBL(%eax)
st_done:

    /* --- Phase 2: surprise unplug with outstanding queues ----
     * Post 8 reads at UNP_LBA without waiting (each is held ~50 ms by
     * the blkdebug latency rule), then yank the card. */
    xorl %ebp, %ebp              /* i */
unp_post:
    cmpl $8, %ebp
    jae unp_trigger
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_UNP, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $UNP_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    call sq_post
    incl %ebp
    jmp unp_post
unp_trigger:
    movl cq_head1, %eax
    movl %eax, cq_head_snap
    movl bar0, %ebp
    movl $NTO64_UNPLUG_MAGIC, %eax
    movl %eax, NTO64_UNPLUG_REG(%ebp)
    /* poll the CQ head entry for ~0.3 s: any completion = leaked */
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
unp_poll:
    cq_yield
    movl cq_head_snap, %ecx
    shll $4, %ecx
    movl $CQ1, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    andl $1, %edx
    movl cq_phase, %eax
    andl $1, %eax
    cmpl %eax, %edx
    je unp_leak
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $300000000, %eax
    jb unp_poll
    jmp unp_check
unp_leak:
    movl $msg_unp, %esi
    call puts
    incl fail
    jmp unp_after
unp_check:
    /* CSTS must read all-ones */
    movl bar0, %ebp
    movl NVME_CSTS(%ebp), %eax
    cmpl $0xffffffff, %eax
    jne unp_bad
    /* config VID/DID must read all-ones */
    movl nvme_dev, %edi
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    jne unp_bad
    movl $1, unplug_ok
    jmp unp_after
unp_bad:
    movl $msg_unp, %esi
    call puts
    incl fail
unp_after:

    /* --- Phase 3: hot-plug re-attach (run-nvmereplug) ----
     * after the surprise removal the device comes back
     * (nto64-replug-ms): config becomes readable again, and the driver
     * re-enumerates + re-initializes (fresh rings), then proves the
     * data path with a round-trip at a fresh LBA.  Without the
     * property the device stays gone and rp stays 0. */
    movl $0, rp
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
rp_wait:
    movl nvme_dev, %edi
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    jne rp_found
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $2, %edx
    ja rp_done
    jb 1f
    cmpl $0xcb417800, %eax       /* ~12e9 ticks: covers the replug ms */
    jae rp_done
1:  jmp rp_wait
rp_found:
    movl $1, rp
    /* the controller reset fresh with the replug: re-arm the rings */
    movl $0, admin_tail
    movl $0, admin_head
    movl $0, sq_tail1
    movl $0, cq_head1
    movl $0, sq_tail2
    movl $0, cq_head2
    movl $1, admin_phase
    movl $1, cq_phase
    movl $1, cq2_phase
    movl bar0, %ebp
    movl NVME_CC(%ebp), %eax
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)
    movl $10000000, %ecx
1:  movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jz 2f
    decl %ecx
    jnz 1b
    movl $msg_rdy, %esi
    call puts
    incl fail
    jmp report
2:  /* wipe what the previous controller life left in guest memory and
     * re-arm the guest ring state before the new one is enabled */
    call zero_rings
    movl $0x001f001f, NVME_AQA(%ebp)
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)
    movl $10000000, %ecx
1:  movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jnz 2f
    decl %ecx
    jnz 1b
    movl $msg_rdy, %esi
    call puts
    incl fail
    jmp report
2:  /* re-identify the namespace (sanity) */
    call clr_cmd
    movb $6, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $IDNS, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz io_bad
    /*
     * The controller reset above dropped the I/O queue pairs with the
     * admin queue: recreate them before using queue 1 (the same
     * re-initialisation the revive and format-reset paths do).  Without
     * it the doorbells below hit queues the controller no longer has,
     * and the round-trip would only "pass" by reading a stale phase-1
     * completion the wipe above just removed.
     */
    call recreate_queues
    testl %eax, %eax
    jnz io_bad
    /* round-trip at a fresh LBA */
    movl $WB_COLD, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $RPL_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_COLD, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $RPL_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl $WB_COLD, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp rp_done

step33_phases:
    /* --- Phase 4a: SMART async event (AER) cycle ----
     * Set the Async Event Config, keep an Async Event Request
     * outstanding, arm the NTAS SMART event, and verify the AER
     * completion result (event type/info/log page) plus the
     * critical-warning bit in the SMART log.  Reading the log with
     * RAE=0 clears the event mask, so a second arm posts the next
     * SMART event (spare).  Runs on every target - the stock AER
     * machinery. */
    movl $1, ae
    /* Set Features: Async Event Config = SMART spare|temp|reliability */
    call clr_cmd
    movb $9, CMD_TMPL            /* Set Features */
    movl $0, CMD_TMPL+4
    movl $0, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0x0b, CMD_TMPL+40      /* cdw10: FID = async event config */
    movl $0x07, CMD_TMPL+44      /* cdw11: SMART bits 0|1|2 */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz aer_bad
    /* AER #1: submit the request, arm reliability, wait, verify */
    call clr_cmd
    movb $0x0c, CMD_TMPL         /* Async Event Request */
    movl $CMD_TMPL, %esi
    call adm_submit
    movl bar0, %ebp
    movl $NTO64_SMART_MAGIC, %eax
    movl %eax, NTO64_SMART_REG(%ebp)
    movl $0, %ecx
    movl $0, ae_retries
1:  call adm_poll
    jnc 2f
    incl ae_retries
    cmpl $1000000, ae_retries
    jae aer_bad
    jmp 1b
2:  testl %eax, %eax
    jnz aer_bad
    movl %edx, %eax
    andl $0xff, %eax
    cmpl $NVME_AER_TYPE_SMART, %eax
    jne aer_bad
    movl %edx, %eax
    shrl $8, %eax
    andl $0xff, %eax
    cmpl $NVME_AER_INFO_RELIABILITY, %eax
    jne aer_bad
    movl %edx, %eax
    shrl $16, %eax
    andl $0xff, %eax
    cmpl $NVME_LOG_SMART, %eax
    jne aer_bad
    /* Get Log Page: SMART (512 B, RAE=0 clears the event mask) */
    call clr_cmd
    movb $2, CMD_TMPL            /* Get Log Page */
    movl $0xffffffff, CMD_TMPL+4
    movl $SMART_LOG, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $((127 << 16) | NVME_LOG_SMART), CMD_TMPL+40
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz aer_bad
    movzbl SMART_LOG, %eax
    testb $4, %al                /* NVME_SMART_RELIABILITY */
    jz aer_bad
    /* AER #2: the next arm posts SPARE */
    call clr_cmd
    movb $0x0c, CMD_TMPL
    movl $CMD_TMPL, %esi
    call adm_submit
    movl bar0, %ebp
    movl $NTO64_SMART_MAGIC, %eax
    movl %eax, NTO64_SMART_REG(%ebp)
    movl $0, ae_retries
1:  call adm_poll
    jnc 2f
    incl ae_retries
    cmpl $1000000, ae_retries
    jae aer_bad
    jmp 1b
2:  testl %eax, %eax
    jnz aer_bad
    movl %edx, %eax
    shrl $8, %eax
    andl $0xff, %eax
    cmpl $NVME_AER_INFO_SPARE, %eax
    jne aer_bad
    call clr_cmd
    movb $2, CMD_TMPL
    movl $0xffffffff, CMD_TMPL+4
    movl $SMART_LOG, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $((127 << 16) | NVME_LOG_SMART), CMD_TMPL+40
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz aer_bad
    movzbl SMART_LOG, %eax
    testb $1, %al                /* NVME_SMART_SPARE */
    jz aer_bad
    movl $2, ae
    jmp nr_phase
aer_bad:
    movl $msg_aer, %esi
    call puts
    incl fail

    /* --- Phase 4b: NS not-ready window (run-nvmenotready) ----
     * prefill a dedicated LBA, arm the NTNR window, then a read must
     * fail with NVME_NS_NOT_READY until the window expires and a
     * bounded retry lands with the data intact.  Clean targets: the
     * read succeeds immediately and nr stays 1. */
nr_phase:
    movl $1, nr
    movl $WB_NR, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL            /* write the prefill */
    movl $1, CMD_TMPL+4
    movl $WB_NR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $NR_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl bar0, %ebp
    movl $NTO64_NSNR_MAGIC, %eax
    movl %eax, NTO64_NSNR_REG(%ebp)
    movl $0, nr_retries
1:  call clr_cmd
    movb $2, CMD_TMPL            /* read */
    movl $1, CMD_TMPL+4
    movl $WB_NR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $NR_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jz 2f
    cmpl $NVME_NS_NOT_READY, %eax
    jne nr_bad
    incl nr_retries
    cmpl $200000, nr_retries
    jae nr_bad
    jmp 1b
2:  movl $WB_NR, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl nr_retries, %eax
    testl %eax, %eax
    jz 3f
    movl $2, nr
3:  jmp wp_phase
nr_bad:
    movl $msg_nr, %esi
    call puts
    incl fail

    /* --- Phase 4c: write-protect window (run-nvmewp) ----
     * arm the NTWP window, then a write must fail with
     * Namespace is Write Protected while reads still work; after the window
     * expires the bounded retry lands and the read-back matches.
     * Clean targets: the write succeeds immediately (wp stays 1). */
wp_phase:
    movl $1, wp
    movl $WB_NR, %edi
    call fill_pattern
    movl bar0, %ebp
    movl $NTO64_WP_MAGIC, %eax
    movl %eax, NTO64_WP_REG(%ebp)
    movl $0, wp_retries
1:  call clr_cmd
    movb $1, CMD_TMPL            /* write */
    movl $1, CMD_TMPL+4
    movl $WB_NR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $WP_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jz 2f
    cmpl $NVME_NS_WRITE_PROTECTED, %eax
    jne wp_bad
    incl wp_retries
    cmpl $200000, wp_retries
    jae wp_bad
    jmp 1b
2:  /* read-back proves the data path is live again */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_NR, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $WP_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl $WB_NR, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl wp_retries, %eax
    testl %eax, %eax
    jz 3f
    movl $2, wp
3:  jmp fmt_phase
wp_bad:
    movl $msg_wp, %esi
    call puts
    incl fail

    /* --- Phase 4d: Format NVM in-progress (run-nvmeformatstall) ----
     * arm the NTFS stall, submit Format NVM (nsid 1) WITHOUT waiting,
     * then an I/O read must fail with NVME_FORMAT_IN_PROGRESS while
     * the format is held; once the stall window expires the format
     * completes and the read succeeds again (the namespace is
     * writable; the format zeroed it).  Clean targets: the format
     * completes immediately and the read succeeds (fi stays 1). */
fmt_phase:
    movl $1, fi
    movl $0, fi_faulted
    movl bar0, %ebp
    movl $NTO64_FMTS_MAGIC, %eax
    movl %eax, NTO64_FMTS_REG(%ebp)
    call clr_cmd
    movb $0x80, CMD_TMPL         /* Format NVM */
    movl $1, CMD_TMPL+4
    movl $0, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40         /* cdw10: LBAF 0 */
    movl $CMD_TMPL, %esi
    call adm_submit
    /* Bit 0x40000 (run-nvmeformatreset): give up on the held Format NVM
     * and reset the controller instead of waiting out the stall.  Pick
     * the reset test from the expected mode *before* the probe read: the
     * Format NVM is processed on the admin SQ's bottom half, so a read
     * issued right after the doorbell can legitimately land first and
     * find the namespace still ready - that must not be able to skip the
     * reset.  fmt_reset re-probes until the stall is actually visible. */
    call nto64_expect
    testl $0x40000, %eax
    jnz fmt_reset
    call clr_cmd
    movb $2, CMD_TMPL            /* read while the format is pending */
    movl $1, CMD_TMPL+4
    movl $WB_FMT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $FMT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    cmpl $NVME_FORMAT_IN_PROGRESS, %eax
    je 1f
    testl %eax, %eax
    jnz fmt_bad
    jmp 2f
1:  movl $1, fi_faulted
2:  /* wait for the Format completion (bounded; the CSTS MMIO read
     * yields so the stall timer can fire) */
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
3:  call adm_poll
    jnc 4f
    movl bar0, %ebp
    movl NVME_CSTS(%ebp), %eax   /* MMIO yield */
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $2, %edx
    ja fmt_bad
    jb 3b
    cmpl $0x77359400, %eax       /* ~2e9 ticks */
    jae fmt_bad
    jmp 3b
4:  testl %eax, %eax
    jnz fmt_bad
    /* post-format read succeeds (the format zeroed the namespace) */
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_FMT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $FMT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl fi_faulted, %eax
    testl %eax, %eax
    jz 5f
    movl $2, fi
5:  jmp resv_phase
fmt_bad:
    movl $msg_fmt, %esi
    call puts
    incl fail
    ret

    /* --- Phase 4d-2: controller reset inside the format stall ----
     * (run-nvmeformatreset, expects bit 0x40000)  Same arm as phase 4d,
     * but here the driver resets the controller while the Format NVM is
     * held instead of waiting for the window to expire, re-initialises,
     * and samples one I/O.  The namespace has to answer again: the
     * stalled format left FORMAT_IN_PROGRESS in its status, and only a
     * format that runs to completion clears it, so a reset that drops
     * the request without the status leaves every later command
     * refused with 0x84 (DNR=0 - the driver requeues it forever).
     * fr != 0 means the reset recovered the namespace; the sampled 0x84
     * leaves fr at 0 and the expectation check fails the run. */
fmt_reset:
    /* The Format NVM is processed on the admin SQ's bottom half, so a
     * read issued right after the doorbell can land first and see a
     * still-ready namespace.  Reissue it until the stall is actually
     * observable: the reset below is only worth making when there really
     * is a format in flight to interrupt. */
    movl $64, fr_tries
fr_probe:
    call clr_cmd
    movb $2, CMD_TMPL
    movl $1, CMD_TMPL+4
    movl $WB_FMT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $FMT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    cmpl $NVME_FORMAT_IN_PROGRESS, %eax
    je fr_stalled
    testl %eax, %eax
    jnz fmt_bad
    decl fr_tries
    jnz fr_probe
    jmp fmt_bad                 /* the stall never became visible */

fr_stalled:
    movl $2, fi
    movl $1, fi_faulted
    movl bar0, %ebp
    movl NVME_CC(%ebp), %eax            /* CC.EN = 0: reset it */
    andl $0xfffffffe, %eax
    movl %eax, NVME_CC(%ebp)
    movl $10000000, %ecx
fr_off_wait:
    movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jz fr_off_done
    decl %ecx
    jnz fr_off_wait
    jmp fmt_bad                         /* never went idle */
fr_off_done:
    /* Re-enable and re-initialise: the rings are wiped and the guest
     * pointers/phases re-armed while the controller is still disabled
     * (the stuck Format NVM command's completion must not survive the
     * reset in the admin CQ). */
    movl $0, admin_tail
    movl $0, admin_head
    movl $0, sq_tail1
    movl $0, cq_head1
    movl $0, sq_tail2
    movl $0, cq_head2
    movl $1, admin_phase
    movl $1, cq_phase
    movl $1, cq2_phase
    call zero_rings
    /* the held Format NVM's completion must not survive the reset: the
     * wiped ring is where a poll would have found it, so probe the same
     * check admin_cmd() uses with a planted phase-1 entry (see the
     * identical probe in the revive path above) */
    movzwl admin_cid, %edx
    addl $0x8000, %edx
    orl $0x00030000, %edx           /* phase 1 | INVALID_OPCODE << 1 */
    movl $0, ACQ_ADDR
    movl $0, ACQ_ADDR+4
    movl $0, ACQ_ADDR+8
    movl %edx, ACQ_ADDR+12
    call adm_ready
    jnc 8f
    jmp 9f
8:  movl $msg_stale, %esi
    call puts
    incl fail
9:
    movl $0x001f001f, NVME_AQA(%ebp)
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)
    movl $10000000, %ecx
fr_rdy_wait:
    movl NVME_CSTS(%ebp), %eax
    testl $1, %eax
    jnz fr_rdy_done
    decl %ecx
    jnz fr_rdy_wait
    jmp fmt_bad                         /* never came ready */
fr_rdy_done:
    call recreate_queues
    testl %eax, %eax
    jnz fmt_bad
    call clr_cmd
    movb $2, CMD_TMPL                   /* one read: accepted, or 0x84? */
    movl $1, CMD_TMPL+4
    movl $WB_FMT, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $FMT_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz fr_done
    movl $1, fr
fr_done:
    jmp resv_phase

    /* --- Phase 4e: Reservation Conflict window (run-nvmeresv) ----
     * Two controllers share the subsystem namespace (nvme-subsys +
     * shared nvme-ns); the guest arms the NTRC magic and the device
     * marks the shared namespace reserved by the OTHER controller, so
     * this controller's I/O fails with Reservation Conflict (0x0083,
     * DNR=0) until the window expires and the bounded retry lands with
     * the data intact.  Clean targets: the arm is a no-op (zero
     * property or no sibling) and the read succeeds immediately
     * (rc stays 1). */
resv_phase:
    movl $1, rc
    movl $WB_RV, %edi
    call fill_pattern
    call clr_cmd
    movb $1, CMD_TMPL            /* write the prefill */
    movl $1, CMD_TMPL+4
    movl $WB_RV, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $RESV_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jnz io_bad
    movl bar0, %ebp
    movl $NTO64_RESV_MAGIC, %eax
    movl %eax, NTO64_RESV_REG(%ebp)
    movl $0, rc_retries
1:  call clr_cmd
    movb $2, CMD_TMPL            /* read */
    movl $1, CMD_TMPL+4
    movl $WB_RV, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $RESV_LBA, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    movl $1, %eax
    call io_cmd
    testl %eax, %eax
    jz 2f
    cmpl $NVME_NS_RESV_CONFLICT, %eax
    jne resv_bad
    incl rc_retries
    cmpl $200000, rc_retries
    jae resv_bad
    movl bar0, %ebp
    movl NVME_CSTS(%ebp), %eax   /* MMIO yield for the virtual timer */
    jmp 1b
2:  movl $WB_RV, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl rc_retries, %eax
    testl %eax, %eax
    jz 3f
    movl $2, rc
3:  ret
resv_bad:
    movl $msg_rc, %esi
    call puts
    incl fail
    ret
rp_done:
    jmp report

io_bad:
    movl $msg_io, %esi
    call puts
    incl fail
    jmp report
data_bad:
    movl $msg_data, %esi
    call puts
    incl fail
    jmp report

/* --------------------------------------------------------------- */
/* fill_pattern: edi -> buffer; fill 1024 dwords with 0x55667788.
 * Clobbers eax, ecx, edi. */
fill_pattern:
    movl $0x55667788, %eax
    movl $1024, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    ret

/* verify_pattern: esi -> buffer; returns eax = 0 ok, 1 mismatch.
 * Clobbers eax, ecx, esi. */
verify_pattern:
    movl $1024, %ecx
    movl $0x55667788, %eax
1:  cmpl %eax, (%esi)
    jne 2f
    addl $4, %esi
    decl %ecx
    jnz 1b
    xorl %eax, %eax
    ret
2:  movl $1, %eax
    ret

/* adm_ready: is the CQE at admin_head the completion of the command
 * whose CID sits in admin_cid?  Returns CF=0 with eax = status >> 1
 * when the slot's phase matches admin_phase and the CQE's CID matches
 * admin_cid; CF=1 otherwise (an empty slot, or an entry belonging to
 * another command or to an earlier incarnation of the controller - it
 * is left where it is for the caller to re-check).  This is the one
 * place that decides a completion belongs to a command: admin_cmd()
 * polls with it, and the reset paths probe it with a planted stale
 * entry.  Clobbers eax, ecx, edx. */
adm_ready:
    movl admin_head, %ecx
    shll $4, %ecx
    movl $ACQ_ADDR, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx           /* DW3 low half: status + phase */
    movl %edx, %ecx
    andl $1, %ecx
    cmpl admin_phase, %ecx
    jne 9f                          /* no completion in this slot */
    movzwl 12(%eax), %ecx           /* DW3 high half: the CID */
    cmpl admin_cid, %ecx
    jne 9f                          /* somebody else's completion */
    movl %edx, %eax
    shrl $1, %eax                   /* status code */
    clc
    ret
9:  stc
    ret

/* admin_cmd: esi -> 64-byte command; returns eax = status (0 = ok).
 * Clobbers eax, ecx, edx, esi, edi, ebp. */
admin_cmd:
    /*
     * Stamp a fresh CID into the command (CDW0 bits 31:16) and
     * remember it: the counter never restarts, so a completion left
     * behind by an earlier incarnation of the controller carries an
     * older CID and cannot pass the identity check below.  Together
     * with the phase comparison this means an entry is only consumed
     * when it is this command's completion - a stale phase-1 entry at
     * admin_head (or a ring the guest forgot to wipe around a reset)
     * is no longer accepted as evidence that the command completed.
     */
    movzwl admin_cid, %eax
    incl %eax
    movw %ax, admin_cid
    movw %ax, 2(%esi)
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
    andl $31, %ecx
    movl %ecx, admin_tail
    movl bar0, %eax
    movl %ecx, NVME_SQTDBL(%eax)
    movl $100000000, %ebp
1:  cq_yield
    call adm_ready
    jnc 2f
    decl %ebp
    jnz 1b
    movl $msg_acq, %esi
    call puts
    incl fail
    movl $1, %eax
    ret
2:  pushl %eax                      /* the completion's status code */
    movl admin_head, %ecx
    incl %ecx
    cmpl $QSIZE, %ecx
    jne 4f
    xorl %ecx, %ecx
    xorl $1, admin_phase
4:  movl %ecx, admin_head
    movl bar0, %eax
    movl %ecx, NVME_CQHDBL(%eax)
    popl %eax
    ret

/* adm_submit: post the command at esi to the admin SQ and ring the
 * doorbell WITHOUT waiting for a completion.  Clobbers eax, ecx, edx,
 * esi, edi. */
adm_submit:
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
    andl $31, %ecx
    movl %ecx, admin_tail
    movl bar0, %eax
    movl %ecx, NVME_SQTDBL(%eax)
    ret

/* adm_poll: non-blocking poll of the admin CQ at admin_head.
 * Returns CF=0 + eax = status>>1, edx = CQE result dword when a
 * completion is present (head advanced), CF=1 when empty.
 * Clobbers eax, ecx, edx. */
adm_poll:
    movl admin_head, %ecx
    shll $4, %ecx
    movl $ACQ_ADDR, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    movl %edx, %ecx
    andl $1, %ecx
    cmpl admin_phase, %ecx
    jne 9f                     /* not a completion of this CQ phase */
    pushl %edx                 /* save the status word */
    movl 0(%eax), %ecx
    pushl %ecx                 /* save the result dword */
    movl admin_head, %ecx
    incl %ecx
    cmpl $QSIZE, %ecx
    jne 8f
    xorl %ecx, %ecx
    xorl $1, admin_phase
8:  movl %ecx, admin_head
    movl bar0, %eax
    movl %ecx, NVME_CQHDBL(%eax)
    popl %edx                  /* result dword */
    popl %ecx                  /* status word */
    movl %ecx, %eax
    shrl $1, %eax              /* status >> 1 */
    clc
    ret
9:  stc
    ret

/* io_cmd: esi -> 64-byte command on qid 1; blocks on CQ1 and returns
 * eax = status (0 = ok, else NVMe status code).  Clobbers eax, ecx,
 * edx, esi, edi, ebp. */
io_cmd:
    movl sq_tail1, %ecx
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
    movl sq_tail1, %ecx
    incl %ecx
    andl $31, %ecx
    movl %ecx, sq_tail1
    movl bar0, %eax
    movl %ecx, SQ1TDBL(%eax)
    movl $100000000, %edi
1:  cq_yield
    movl cq_head1, %ecx
    shll $4, %ecx
    movl $CQ1, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    movl %edx, %eax
    andl $1, %eax
    movl cq_phase, %ecx
    andl $1, %ecx
    cmpl %ecx, %eax
    je 2f
    decl %edi
    jnz 1b
    movl $msg_iocq, %esi
    call puts
    incl fail
    movl $1, %eax
    ret
2:  movl cq_head1, %ecx
    incl %ecx
    cmpl $32, %ecx
    jne 3f
    xorl %ecx, %ecx
    xorl $1, cq_phase
3:  movl %ecx, cq_head1
    movl bar0, %eax
    movl %ecx, CQ1HDBL(%eax)
    movl %edx, %eax
    shrl $1, %eax
    ret

/* sq_post: esi -> 64-byte command on qid 1; submits without waiting.
 * Clobbers eax, ecx, edx, esi, edi, ebp. */
sq_post:
    movl sq_tail1, %ecx
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
    movl sq_tail1, %ecx
    incl %ecx
    andl $31, %ecx
    movl %ecx, sq_tail1
    movl bar0, %eax
    movl %ecx, SQ1TDBL(%eax)
    ret

/* clr_cmd: zero the 64-byte command template.  Clobbers eax, ecx, edi. */
clr_cmd:
    movl $CMD_TMPL, %edi
    movl $16, %ecx
1:  movl $0, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    ret

/* zero_mem: zero ecx bytes at edi.  Clobbers eax, ecx, edi. */
zero_mem:
    xorl %eax, %eax
1:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 1b
    ret

/* zero_rings: wipe the admin CQ and the I/O CQ/SQ rings.  A controller
 * reset re-arms every CQ at head/tail 0 and phase 1, so completions
 * (and, for the admin queue, commands) left in guest memory by the
 * previous incarnation sit exactly where the next poll looks; they
 * have to be gone before CC.EN goes back to 1 and the guest heads and
 * phases are re-armed.  Sizes are QSIZE entries (CQ 16 B, SQ 64 B). */
zero_rings:
    movl $ACQ_ADDR, %edi
    movl $(QSIZE * 16), %ecx
    call zero_mem
    movl $CQ1, %edi
    movl $(QSIZE * 16), %ecx
    call zero_mem
    movl $SQ1, %edi
    movl $(QSIZE * 64), %ecx
    call zero_mem
    movl $CQ2, %edi
    movl $(QSIZE * 16), %ecx
    call zero_mem
    movl $SQ2, %edi
    movl $(QSIZE * 64), %ecx
    call zero_mem
    ret

/* recreate_queues: recreate CQ1/SQ1/CQ2/SQ2 after a controller reset.
 * The admin queue is already live (CC.EN=1).  eax = 0 ok, 1 failed.
 * Clobbers eax, ecx, edx, esi, edi, ebp. */
recreate_queues:
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl $CQ1, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $1, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $1, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz 9f
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
    jnz 9f
    call recreate_q2
    ret
9:  movl $1, %eax
    ret

/* recreate_q2: recreate CQ2/SQ2 (qid 2).  eax = 0 ok, 1 failed. */
recreate_q2:
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl $CQ2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $2, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $1, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz 9f
    call clr_cmd
    movb $1, CMD_TMPL            /* Create I/O SQ */
    movl $SQ2, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $2, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    movl $2, %eax
    shll $16, %eax
    orl $((2 << 2) | 1), %eax
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz 9f
    xorl %eax, %eax
    ret
9:  movl $1, %eax
    ret

/* sq_post2: like sq_post on qid 2 (SQ2, SQ2TDBL). */
sq_post2:
    movl sq_tail2, %ecx
    shll $6, %ecx
    addl $SQ2, %ecx
    movl %esi, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    movl sq_tail2, %ecx
    incl %ecx
    andl $31, %ecx
    movl %ecx, sq_tail2
    movl bar0, %eax
    movl %ecx, SQ2TDBL(%eax)
    ret

/* io_cmd2: like io_cmd on qid 2 (blocks on CQ2). */
io_cmd2:
    movl sq_tail2, %ecx
    shll $6, %ecx
    addl $SQ2, %ecx
    movl %esi, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    movl sq_tail2, %ecx
    incl %ecx
    andl $31, %ecx
    movl %ecx, sq_tail2
    movl bar0, %eax
    movl %ecx, SQ2TDBL(%eax)
    movl $100000000, %edi
1:  cq_yield
    movl cq_head2, %ecx
    shll $4, %ecx
    movl $CQ2, %eax
    addl %ecx, %eax
    movzwl 14(%eax), %edx
    movl %edx, %eax
    andl $1, %eax
    movl cq2_phase, %ecx
    andl $1, %ecx
    cmpl %ecx, %eax
    je 2f
    decl %edi
    jnz 1b
    movl $msg_iocq, %esi
    call puts
    incl fail
    movl $1, %eax
    ret
2:  movl cq_head2, %ecx
    incl %ecx
    cmpl $32, %ecx
    jne 3f
    xorl %ecx, %ecx
    xorl $1, cq2_phase
3:  movl %ecx, cq_head2
    movl bar0, %eax
    movl %ecx, CQ2HDBL(%eax)
    movl %edx, %eax
    shrl $1, %eax
    ret

/* --------------------------------------------------------------- */
/* pcicfg / pcicfg_write / console helpers (same as nvmetest.S) */
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

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: the expected-mode bitmask records which fault-fire
 * indicator fields must be non-zero for this run config.  Bit 0 -> st
 * (stuck), 1 -> ab (abort), 2 -> go (controller-reset recovery), 3 -> sf
 * (start-fail), 4 -> gv, 5 -> hg (hang), 6 -> fl (flush-lie), 7 -> la
 * (late-attach), 8 -> rp (replug), 9 -> lie (rdy-lie), 10 -> sw, 11 -> sr
 * (stall), 12 -> dq (dead-cq), 13 -> fi (format-in-progress), 14 -> fr
 * (format released by a controller reset).  Set bit
 * means the phase must see the fault (field != 0); clear means it must stay
 * clean (field == 0).  A dead fault hook leaves the field 0 and mismatches,
 * so a fault run cannot silently pass. */
.macro NCHECK bit, var
    movl %ebx, %eax
    testl $\bit, %eax
    jnz .Lve_fault_\bit
    cmpl $0, \var
    je .Lve_ok_\bit
    incl fail
    jmp .Lve_ok_\bit
.Lve_fault_\bit:
    cmpl $0, \var
    jne .Lve_ok_\bit
    incl fail
.Lve_ok_\bit:
.endm

/* For the run-config fields whose clean value is 1 (not-ready, write-
 * protect, reservation, media-change), the fault raises the field past 1
 * but a dead hook leaves it at 1.  Set bit means "must be != 1"; a clear
 * bit means "do not assert" (some targets zero these when the controller
 * dies). */
.macro NCHECK_GT1 bit, var
    movl %ebx, %eax
    testl $\bit, %eax
    jz .Lve_ok_\bit
    cmpl $1, \var
    jne .Lve_ok_\bit
    incl fail
.Lve_ok_\bit:
.endm

verify_expect:
    call nto64_expect
    movl %eax, %ebx
    NCHECK 0x1, st
    NCHECK 0x2, ab
    NCHECK 0x4, go
    NCHECK 0x8, sf
    NCHECK 0x10, gv
    NCHECK 0x20, hg
    NCHECK 0x40, fl
    NCHECK 0x80, la
    NCHECK 0x100, rp
    NCHECK 0x200, lie
    NCHECK 0x400, sw
    NCHECK 0x800, sr
    NCHECK 0x1000, dq
    NCHECK_GT1 0x2000, nr
    NCHECK_GT1 0x4000, wp
    NCHECK_GT1 0x8000, rc
    NCHECK_GT1 0x10000, mc
    NCHECK_GT1 0x20000, fi
    NCHECK 0x40000, fr
    ret

/* report: print the result line, then halt */
report:
    call verify_expect
    movl $msg_fault, %esi
    call puts
    movl $sp_c, %esi
    call puts
    movl lnk_cap_gen, %eax
    call puthex
    movl $sp_s, %esi
    call puts
    movl lnk_sta_gen, %eax
    call puthex
    movl $sp_d, %esi
    call puts
    movl lnk_dwng, %eax
    call puthex
    movl $sp_ho, %esi
    call puts
    movl hot_delta, %eax
    call puthex
    movl $sp_co, %esi
    call puts
    movl cold_delta, %eax
    call puthex
    movl $sp_ws, %esi
    call puts
    movl wear_status, %eax
    call puthex
    movl $sp_wr, %esi
    call puts
    movl wear_retries, %eax
    call puthex
    movl $sp_ud, %esi
    call puts
    movl unplug_ok, %eax
    call puthex
    movl $sp_p, %esi
    call puts
    movl $8, %eax
    call puthex
    movl $sp_st, %esi
    call puts
    movl st, %eax
    call puthex
    movl $sp_ab, %esi
    call puts
    movl ab, %eax
    call puthex
    movl $sp_go, %esi
    call puts
    movl go, %eax
    call puthex
    movl $sp_sf, %esi
    call puts
    movl sf, %eax
    call puthex
    movl $sp_gv, %esi
    call puts
    movl gv, %eax
    call puthex
    movl $sp_hg, %esi
    call puts
    movl hg, %eax
    call puthex
    movl $sp_fl, %esi
    call puts
    movl fl, %eax
    call puthex
    movl $sp_la, %esi
    call puts
    movl la, %eax
    call puthex
    movl $sp_rp, %esi
    call puts
    movl rp, %eax
    call puthex
    movl $sp_lie, %esi
    call puts
    movl lie, %eax
    call puthex
    movl $sp_sw, %esi
    call puts
    movl sw, %eax
    call puthex
    movl $sp_sr, %esi
    call puts
    movl sr, %eax
    call puthex
    movl $sp_dq, %esi
    call puts
    movl dq, %eax
    call puthex
    movl $sp_ae, %esi
    call puts
    movl ae, %eax
    call puthex
    movl $sp_nr, %esi
    call puts
    movl nr, %eax
    call puthex
    movl $sp_fi, %esi
    call puts
    movl fi, %eax
    call puthex
    movl $sp_fr, %esi
    call puts
    movl fr, %eax
    call puthex
    movl $sp_wp, %esi
    call puts
    movl wp, %eax
    call puthex
    movl $sp_rc, %esi
    call puts
    movl rc, %eax
    call puthex
    movl $sp_mc, %esi
    call puts
    movl mc, %eax
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

/* --------------------------------------------------------------- */
    .bss
    .balign 16
fail: .long 0
mbi_ptr: .long 0
nvme_dev: .long 0
bar0: .long 0
bar0_save: .long 0
exp_cap: .long 0
lnk_cap_gen: .long 0
lnk_sta_gen: .long 0
lnk_dwng: .long 0
admin_tail: .long 0
admin_head: .long 0
admin_phase: .long 0
admin_cid: .long 0
sq_tail1: .long 0
cq_head1: .long 0
cq_head_snap: .long 0
t0_lo: .long 0
t0_hi: .long 0
hot_delta: .long 0
cold_delta: .long 0
wear_status: .long 0
wear_retries: .long 0
unplug_ok: .long 0
st: .long 0
ab: .long 0
go: .long 0
sf: .long 0
gv: .long 0
storm_try: .long 0
hg: .long 0
fl: .long 0
la: .long 0
rp: .long 0
lie: .long 0
sw: .long 0
sr: .long 0
dq: .long 0
sq_tail2: .long 0
cq_head2: .long 0
cq_phase: .long 0
cq2_phase: .long 0
ae: .long 0
nr: .long 0
fi: .long 0
fr: .long 0
wp: .long 0
rc: .long 0
mc: .long 0
ae_retries: .long 0
nr_retries: .long 0
wp_retries: .long 0
rc_retries: .long 0
fi_faulted: .long 0
fr_tries: .long 0

    .section .rodata
msg_fault: .asciz "NVME-FAULT"
msg_stale: .asciz " STALE-CQE-ACCEPTED"
sp_c: .asciz " c="
sp_s: .asciz " s="
sp_d: .asciz " d="
sp_ho: .asciz " ho="
sp_co: .asciz " co="
sp_ws: .asciz " ws="
sp_wr: .asciz " wr="
sp_ud: .asciz " ud="
sp_p: .asciz " p="
sp_st: .asciz " st="
sp_ab: .asciz " ab="
sp_go: .asciz " go="
sp_sf: .asciz " sf="
sp_gv: .asciz " gv="
sp_hg: .asciz " hg="
sp_fl: .asciz " fl="
sp_la: .asciz " la="
sp_rp: .asciz " rp="
sp_lie: .asciz " lie="
sp_sw: .asciz " sw="
sp_sr: .asciz " sr="
sp_dq: .asciz " dq="
sp_ae: .asciz " ae="
sp_nr: .asciz " nr="
sp_fi: .asciz " fi="
sp_fr: .asciz " fr="
sp_wp: .asciz " wp="
sp_rc: .asciz " rc="
sp_mc: .asciz " mc="
sp_f: .asciz " f="
nl: .asciz "\n"
msg_nodev: .asciz "no nvme\n"
msg_cap: .asciz "no pcie cap\n"
msg_link: .asciz "link mismatch\n"
msg_rdy: .asciz "rdy timeout\n"
msg_adm: .asciz "bad admin\n"
msg_q: .asciz "bad queue\n"
msg_dmar: .asciz "dma-dead revive bad\n"
msg_aer: .asciz "bad aer\n"
msg_nr: .asciz "bad ns-not-ready\n"
msg_wp: .asciz "bad write-protect\n"
msg_rc: .asciz "bad reservation-conflict\n"
msg_fmt: .asciz "bad format-stall\n"
msg_dq: .asciz "dead queue bad\n"
msg_io: .asciz "io status\n"
msg_data: .asciz "data mismatch\n"
msg_cold: .asciz "cold not slow\n"
msg_wear: .asciz "wear no error\n"
msg_unp: .asciz "unplug bad\n"
msg_stuck: .asciz "wedge bad\n"
msg_storm: .asciz "storm bad\n"
msg_acq: .asciz "acq timeout\n"
msg_iocq: .asciz "iocq timeout\n"
