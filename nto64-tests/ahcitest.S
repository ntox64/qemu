/* SPDX-License-Identifier: BSD-2-Clause */

/* ahcitest.S - freestanding multiboot SATA/AHCI fault slice.
 *
 * Drives the q35 built-in ICH9 AHCI controller + a stock ide-hd on
 * port 0 the way a real devb-sata/ahci driver would: HBA reset, port
 * enable, IDENTIFY, then 4 KiB DMA (READ/WRITE DMA EXT) round-trips
 * against a blkdebug-instrumented raw image.  This is the SATA/AHCI
 * bad-track/fault slice:
 *   a1 bad-track: a transient EIO read (sector 1000) fails once
 *     (ERR status on the port) and a bounded driver retry recovers
 *     the data;
 *   a2/a3/a4 sudden backend errors: EIO write (2000), ENOSPC write
 *     (3000), EIO read (4000) - each recovered by a retry;
 *   a5 persistent backend error until the condition clears: writes
 *     to sector 7000 keep failing with ERR until a FLUSH CACHE EXT
 *     (the driver's recovery action) clears the blkdebug state, then
 *     the write and the readback succeed.
 *   NCQ + spec-breaking completion FISes.
 *     a9 NCQ (nq=1): a clean NCQ READ completes via the SDB (PxSACT
 *     clears) with the data intact; an NCQ bad-track read fails once
 *     (SDB with ERR, TFES, the tag stays stuck) and is recovered with
 *     a COMRESET (the device error state persists, so the ST toggle
 *     alone is NOT enough - every later D2H would re-raise TFES).
 *     a10 SDB-lie (slie=1, nto64-sdb-lie-tag): the SDB for the tag
 *     reports the WRONG SAct payload and leaves the finished tag set
 *     the driver's bounded tag wait times out, the ST-toggle
 *     recovery clears PxSACT and the re-issue recovers.
 *     a11 D2H-lie (dlie, nto64-d2h-lie-sector): the D2H reports the
 *     OPPOSITE of the truth, one-shot - run-satad2hlie (dlie=2): a
 *     successful read reports ERR and the driver's error path +
 *     retry recovers; run-satad2hlie2 (dlie=3): an errored read
 *     reports CLEAN, and since QEMU clears PxCI only on a real clean
 *     status, the lie shows up as "clean D2H but PxCI stuck" - the
 *     driver bounds the wait, sees the clean TFD, recovers with the
 *     ST toggle and re-reads.
 *
 * Per-phase attempt counters are printed (a1..a5, pf = flush count):
 * run-satatest (clean, all a=1), run-satabadtrack (a1=2),
 * run-sataerr (a2/a3/a4=2), run-satapersist (a5=3, pf=1).
 *
 * AHCI 1.3.1 semantics folded into the driver, verified against the
 * spec (serial-ata-ahci-spec-rev1-3-1.pdf):
 *  PxTFD: ERR in bits 15:8, STS in bits 7:0 (spec 3.3.8) - QEMU
 *    packs it exactly this way (this is NOT the 1.3.2+ shadow layout);
 *  PxCI clears only when a D2H FIS clears BSY/DRQ/ERR (spec
 *    3.3.14): an errored command therefore leaves PxCI set, so
 *    completion is detected as CI-clear OR PxIS.TFES (bit 30, set by
 *    any D2H/PIO/SDB FIS whose status has ERR - spec 3.3.5);
 *  error recovery clears the port state with a PxCMD.ST 1->0 toggle
 *    (PxCI is cleared when ST is written from 1 to 0, spec 3.3.14)
 *    before the driver re-issues the command.
 *
 * Run (make run-satatest): -machine q35 -m 64
 *   -drive file=blkdebug:sata-clean.conf:4M.img,if=none,id=drive0,
 *   format=raw,werror=report,rerror=report
 *   -device ide-hd,drive=drive0,bus=ide.0
 *
 * Expected: 'AHCI OK f=00000000 sig=00000101 cap=00002000
 * a1=... a2=... a3=... a4=... a5=... pf=...'
 */

/* AHCI HBA registers (ABAR) */
.equ AHCI_GHC,  0x04
.equ AHCI_PI,   0x0c
.equ P0,        0x100
.equ P_CLB,     0x00
.equ P_FB,      0x08
.equ P_CMD,     0x18
.equ P_TFD,     0x20
.equ P_SIG,     0x24
.equ P_SSTS,    0x28
.equ P_SACT,    0x34
.equ P_CI,      0x38

/* guest memory layout (-m 64, flat RAM) */
.equ CLB,       0x21000       /* command list (32 x 32B) */
.equ CTAB,      0x22000       /* command table (128B header + PRDT) */
.equ FB,        0x23000       /* FIS receive area (256B) */
.equ IDBUF,     0x24000       /* IDENTIFY buffer (512B) */
.equ DBUF,      0x25000       /* 4 KiB DMA data buffer */
.equ WB_COLD,   0x26000       /* slow-media buffers */
.equ WB_WEAR,   0x27000
.equ WB_UNP,    0x28000

.equ ATA_IDENTIFY, 0xec
.equ ATA_RD_DMA,   0x25
.equ ATA_WR_DMA,   0x35
.equ ATA_FLUSH,    0xea
.equ ATA_NCQ_READ, 0x60
.equ SLOW1_LBA,    0x1b00   /* 6912: slow-media recoverable */
.equ SLOW2_LBA,    0x1b08   /* 6920: slow-media unrecoverable */
.equ STUCK_LBA,    0x1c00   /* 7168: media-recovery wedge */
.equ NCQ_OK_LBA,   0x1e00   /* 7680: NCQ clean read */
.equ NCQ_BAD_LBA,  0x1d00   /* 7424: NCQ bad-track (sata-ncq.conf) */
.equ NCQ_LIE_LBA,  0x1e08   /* 7688: SDB-lie NCQ read */
.equ D2H_LIE_LBA,  0x1e10   /* 7696: D2H-lie sector (both directions) */
.equ FB_SDB,       0x58     /* SDB FIS offset in the FIS receive area */

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
    movl $0, pf

    /* mask the legacy PICs (no IDT here; keep IRQ0 quiet) */
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    /* --- find the AHCI controller (class 0x010601) ---- */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je scan_next
    movl $0x08, %ecx
    call pcicfg
    andl $0xffffff00, %eax
    cmpl $0x01060100, %eax
    je ahci_found
scan_next:
    incl %edi
    cmpl $256, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

ahci_found:
    movl %edi, ahci_dev

    /* enable memory space + bus mastering, read BAR5 (ABAR) */
    movl $4, %ecx
    call pcicfg
    orl $6, %eax
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    movl ahci_dev, %edi
    movl $0x24, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, bar0

    /* --- HBA reset (SeaBIOS probes the SATA drive during POST) ---- */
    movl bar0, %ebp
    movl $1, %eax
    movl %eax, AHCI_GHC(%ebp)      /* GHC.HR = 1 */
    movl $1000000, %ecx
hr_wait:
    movl AHCI_GHC(%ebp), %eax
    testl $1, %eax
    jz hr_ok
    decl %ecx
    jnz hr_wait
    movl $msg_hr, %esi
    call puts
    incl fail
    jmp report
hr_ok:
    movl $0x80000000, %eax
    movl %eax, AHCI_GHC(%ebp)      /* GHC.AE = 1 */

    /* --- port 0: command list + FIS area, then FRE ---- */
    movl bar0, %ebp
    movl $CLB, %eax
    movl %eax, P0+P_CLB(%ebp)
    movl $0, P0+P_CLB+4(%ebp)
    movl $FB, %eax
    movl %eax, P0+P_FB(%ebp)
    movl $0, P0+P_FB+4(%ebp)
    movl $0xffffffff, %eax
    movl %eax, P0+0x10(%ebp)       /* PxIS: clear stale bits */
    movl $0x16, %eax               /* SUD | POD | FRE */
    movl %eax, P0+P_CMD(%ebp)
    /* wait for the device to be detected (PxSSTS DET = 3) */
    movl $1000000, %ecx
det_wait:
    movl P0+P_SSTS(%ebp), %eax
    andl $0xf, %eax
    cmpl $3, %eax
    je det_ok
    decl %ecx
    jnz det_wait
    movl $msg_det, %esi
    call puts
    incl fail
    jmp report
det_ok:
    movl P0+P_SIG(%ebp), %eax
    cmpl $0x00000101, %eax          /* ATA signature */
    jne sig_bad
    movl P0+P_CMD(%ebp), %eax
    orl $1, %eax
    movl %eax, P0+P_CMD(%ebp)       /* PxCMD |= ST */
    jmp port_ok
sig_bad:
    movl $msg_sig, %esi
    call puts
    incl fail
    jmp report
port_ok:

    /* --- IDENTIFY DEVICE ---- */
    movl $ATA_IDENTIFY, s_cmd
    movl $0, s_lba
    movl $1, s_count
    movl $IDBUF, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    /* model string at word 27.  ATA IDENTIFY strings are stored
     * byte-swapped inside each 16-bit word (QEMU's padstr writes
     * str[i^1], like real drives; Linux's ata_id_c_string swaps back),
     * so word 27 reads "EQ" not "QE": the dword at byte 54 is 0x4d555145
     * ("EQUM" in memory order) for "QEMU HARDDISK". */
    movl $IDBUF, %esi
    cmpl $0x4d555145, 54(%esi)      /* swapped "QEMU" */
    jne ident_bad
    movl 200(%esi), %eax            /* word 100: LBA48 sectors low */
    movl %eax, cap
    jmp ident_ok
ident_bad:
    movl $msg_ident, %esi
    call puts
    incl fail
    jmp report
ident_ok:

    /* --- prefill the pattern to the READ-fault sectors only ----
     * Sectors 1000 (a1 bad-track) and 4000 (a4 EIO read) must contain
     * the pattern before the fault phases.  The write-fault sectors
     * (2000/3000/7000) are deliberately NOT prefilled: a prefill write
     * would consume the blkdebug once/persistent write rules. */
    movl $DBUF, %edi
    call fill_pattern
    movl $ATA_WR_DMA, s_cmd
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    movl $1000, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $4000, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    /* D2H-lie sector: the a11 phase reads it (read-only lie); the
     * write prefill does NOT consume the hook */
    movl $D2H_LIE_LBA, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    /* NCQ sectors: a9/a10 read them; the writes are not throttled by
     * the read-only bad-track rules */
    movl $NCQ_OK_LBA, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $NCQ_BAD_LBA, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $NCQ_LIE_LBA, s_lba
    call sata_cmd
    testl %eax, %eax
    jnz io_bad

    /* --- a1: bad-track read (sector 1000) ---- */
    movl $1, a1
    movl $ATA_RD_DMA, s_cmd
    movl $1000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a1_ok
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax            /* ATA-6: UNC set if data uncorrectable */
    jne err_bad
    movl $2, a1
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
a1_ok:
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a2: sudden EIO write (sector 2000) ---- */
    movl $1, a2
    movl $ATA_WR_DMA, s_cmd
    movl $2000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a2_ok
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $2, a2
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
a2_ok:
    movl $ATA_RD_DMA, s_cmd
    movl $2000, s_lba
    movl $0, s_write
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a3: sudden ENOSPC write (sector 3000) ---- */
    movl $1, a3
    movl $ATA_WR_DMA, s_cmd
    movl $3000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a3_ok
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $2, a3
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
a3_ok:
    movl $ATA_RD_DMA, s_cmd
    movl $3000, s_lba
    movl $0, s_write
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a4: sudden EIO read (sector 4000) ---- */
    movl $1, a4
    movl $ATA_RD_DMA, s_cmd
    movl $4000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a4_ok
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $2, a4
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
a4_ok:
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a5: persistent write error until a FLUSH clears it ----
     * (sector 7000; blkdebug state 1 fails every write until the
     * flush_to_os event moves it to state 2) */
    movl $1, a5
    movl $ATA_WR_DMA, s_cmd
    movl $7000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a5_ok
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $2, a5
    call sata_cmd
    testl %eax, %eax
    jz a5_flush
    cmpl $2, %eax
    je io_timeout
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $3, a5
a5_flush:
    /* FLUSH CACHE EXT: the driver's recovery action */
    movl $ATA_FLUSH, s_cmd
    movl $0, s_lba
    movl $0, s_count
    movl $0, s_buf
    movl $0, s_write
    movl $0, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $1, pf
    /* the write must now land */
    movl $ATA_WR_DMA, s_cmd
    movl $7000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
a5_ok:
    movl $ATA_RD_DMA, s_cmd
    movl $7000, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a6: slow media, recoverable - the drive retries internally
     * for ~2 s (blkdebug [latency]) then completes (sata-slow.conf) ---- */
    movl $0, sl
    movl $WB_COLD, %edi
    call fill_pattern
    movl $ATA_WR_DMA, s_cmd
    movl $SLOW1_LBA, s_lba
    movl $8, s_count
    movl $WB_COLD, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
    movl $ATA_RD_DMA, s_cmd
    movl $SLOW1_LBA, s_lba
    movl $8, s_count
    movl $WB_COLD, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    testl %edx, %edx
    jnz a6_slow
    cmpl $1000000000, %eax
    jae a6_slow
    jmp a6_ok          /* fast path: no latency rule configured */
a6_slow:
    cmpl $1, %edx
    jae a6_delay_ok
    cmpl $2000000000, %eax
    jae a6_delay_ok
    movl $msg_delay, %esi
    call puts
    incl fail
    jmp report
a6_delay_ok:
    movl $1, sl
a6_ok:
    movl $WB_COLD, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a7: slow media, unrecoverable-then-recoverable - ~2 s of
     * internal retry, then UNC; the driver retry succeeds after
     * another ~2 s (sata-slow.conf: latency + once-error at SLOW2) ---- */
    movl $0, su
    movl $WB_WEAR, %edi
    call fill_pattern
    movl $ATA_WR_DMA, s_cmd
    movl $SLOW2_LBA, s_lba
    movl $8, s_count
    movl $WB_WEAR, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
    movl $ATA_RD_DMA, s_cmd
    movl $SLOW2_LBA, s_lba
    movl $8, s_count
    movl $WB_WEAR, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a7_ok           /* fast success (no fault conf): skip */
    cmpl $2, %eax
    je io_timeout
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae a7_delay_ok
    cmpl $2000000000, %eax
    jae a7_delay_ok
    movl $msg_delay, %esi
    call puts
    incl fail
    jmp report
a7_delay_ok:
    movl s_err, %eax
    cmpl $0x40, %eax
    jne err_bad
    movl $1, su
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
    movl $ATA_RD_DMA, s_cmd
    movl $SLOW2_LBA, s_lba
    movl $8, s_count
    movl $WB_WEAR, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $1, %edx
    jae a7_retry_ok
    cmpl $2000000000, %eax
    jae a7_retry_ok
    movl $msg_delay, %esi
    call puts
    incl fail
    jmp report
a7_retry_ok:
a7_ok:
    movl $WB_WEAR, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad

    /* --- a8: media-recovery wedge - the drive holds BSY and never
     * completes (ide-hd nto64-stuck-sector); the ST toggle alone does
     * NOT clear it, only a COMRESET (PxSCTL DET 1->0) recovers
     * (run-satastuck).  Without the property the read completes fast. */
    movl $0, st
    movl $0, rs
    movl $WB_UNP, %edi
    call fill_pattern
    movl $ATA_WR_DMA, s_cmd
    movl $STUCK_LBA, s_lba
    movl $8, s_count
    movl $WB_UNP, s_buf
    movl $1, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $ATA_RD_DMA, s_cmd
    movl $STUCK_LBA, s_lba
    movl $8, s_count
    movl $WB_UNP, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz a8_skip
    cmpl $2, %eax
    jne a8_bad
    movl $1, st
    /* ST toggle does not clear the wedge: re-issue and expect the
     * same timeout (handle_cmd refuses while BSY is held) */
    movl bar0, %ebp
    movl P0+P_CMD(%ebp), %eax
    andl $0xfffffff8, %eax
    movl %eax, P0+P_CMD(%ebp)
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    movl P0+P_CMD(%ebp), %eax
    orl $1, %eax
    movl %eax, P0+P_CMD(%ebp)
    movl $ATA_RD_DMA, s_cmd
    movl $STUCK_LBA, s_lba
    movl $8, s_count
    movl $WB_UNP, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    cmpl $2, %eax
    jne a8_bad
    /* COMRESET: PxSCTL DET=1 then DET=0 -> port reset clears the wedge */
    movl bar0, %ebp
    movl $1, %eax
    movl %eax, P0+0x2c(%ebp)
    movl $1000000, %ecx
1:  decl %ecx
    jnz 1b
    movl $0, %eax
    movl %eax, P0+0x2c(%ebp)
    movl bar0, %ebp
    movl $1000000, %ecx
1:  movl P0+P_SSTS(%ebp), %eax
    andl $0xf, %eax
    cmpl $3, %eax
    je 2f
    decl %ecx
    jnz 1b
    movl $msg_det, %esi
    call puts
    incl fail
    jmp report
2:  movl P0+P_SIG(%ebp), %eax
    cmpl $0x00000101, %eax
    jne sig_bad
    movl $ATA_RD_DMA, s_cmd
    movl $STUCK_LBA, s_lba
    movl $8, s_count
    movl $WB_UNP, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jnz io_bad
    movl $WB_UNP, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl $1, rs
    jmp a8_done
a8_skip:
a8_done:

    /* --- a9: NCQ (run-satancq) ----
     * A clean NCQ read completes via the SDB (PxSACT bit 0 clears)
     * with the data intact; with sata-ncq.conf the NCQ read at
     * NCQ_BAD_LBA fails once (SDB with ERR, TFES, the tag stays stuck)
     * and the ST-toggle recovery + re-issue recovers the data. */
    movl $0, nq
    movl $1, ncq_tag           /* a9 uses tag 1 so the SDB-lie target's
                                * tag-0 lie is not consumed here */
    movl $DBUF, %edi
    call fill_pattern
    movl $ATA_NCQ_READ, s_cmd
    movl $NCQ_OK_LBA, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_prdtl
    call ncq_cmd
    testl %eax, %eax
    jnz nq_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    movl $NCQ_BAD_LBA, s_lba
    call ncq_cmd
    testl %eax, %eax
    jz nq_done            /* no bad-track configured: clean */
    cmpl $1, %eax
    jne nq_bad
    movl $1, nq
    call ncq_cmd          /* retry after the ST-toggle recovery */
    testl %eax, %eax
    jnz nq_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp nq_done
nq_bad:
    movl $msg_nq, %esi
    call puts
    incl fail
nq_done:

    /* --- a10: SDB-lie (run-satasdblie) ----
     * The SDB for the tag-0 NCQ read LIES (nto64-sdb-lie-tag=0): the
     * payload clears the wrong bit and PxSACT bit 0 stays set - the
     * driver's bounded tag wait times out and the ST-toggle recovery
     * + re-issue recovers.  Without the property the read completes. */
    movl $0, slie
    movl $0, ncq_tag           /* a10: tag 0 (the SDB-lie tag) */
    movl $DBUF, %edi
    call fill_pattern
    movl $NCQ_LIE_LBA, s_lba
    call ncq_cmd
    testl %eax, %eax
    jz slie_done
    cmpl $2, %eax
    jne slie_bad
    movl $1, slie
    call ncq_cmd          /* re-issue after the ST-toggle recovery */
    testl %eax, %eax
    jnz slie_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp slie_done
slie_bad:
    movl $msg_slie, %esi
    call puts
    incl fail
slie_done:

    /* --- a11: D2H-lie (run-satad2hlie / run-satad2hlie2) ----
     * The D2H for the read at D2H_LIE_LBA reports the OPPOSITE of the
     * truth, one-shot.  run-satad2hlie: a SUCCESSFUL read reports ERR
     * the driver's error path (TFD UNC) + retry recovers with the
     * data intact (dlie=2).  run-satad2hlie2: an errored read
     * (blkdebug once) reports CLEAN - the D2H is clean but CI stays
     * set (the device finished without clearing the slot, the
     * "clean completion, command never done" lie) - the driver must
     * bound the wait, spot the clean TFD, recover with the ST toggle
     * and re-read (dlie=3). */
    movl $0, dlie
    movl $DBUF, %edi
    movl $1024, %ecx
1:  movl $0, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    movl $ATA_RD_DMA, s_cmd
    movl $D2H_LIE_LBA, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $0, s_write
    movl $1, s_prdtl
    call sata_cmd
    testl %eax, %eax
    jz dlie_clean
    cmpl $2, %eax
    jne dlie_err
    /* timeout: the false-success lie - a CLEAN D2H was received (PxIS
     * DHRS) but PxCI never cleared (the errored command left the slot
     * set).  The driver checks TFD: clean -> the device lied, recover
     * with the ST toggle (clears PxCI) and re-read. */
    movl bar0, %ebp
    movl P0+P_TFD(%ebp), %eax
    testl $1, %eax               /* BSY in the low byte? */
    jnz dlie_bad
    movl %eax, %edx
    shrl $8, %edx
    andl $0xff, %edx
    testl %edx, %edx             /* error register clean? */
    jnz dlie_bad
    movl $3, dlie
    movl P0+P_CMD(%ebp), %eax
    andl $0xfffffff8, %eax
    movl %eax, P0+P_CMD(%ebp)    /* ST toggle: clears PxCI */
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    movl P0+P_CMD(%ebp), %eax
    orl $1, %eax
    movl %eax, P0+P_CMD(%ebp)
    call sata_cmd
    testl %eax, %eax
    jnz dlie_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp dlie_done
dlie_clean:
    /* clean completion: verify the data (a clean D2H + CI clear that
     * still left wrong data would also be the lie) */
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jz dlie_done
    movl $3, dlie
    call sata_cmd
    testl %eax, %eax
    jnz dlie_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp dlie_done
dlie_err:
    /* reported error: the false-error lie (or a real error) */
    movl $2, dlie
    call sata_cmd
    testl %eax, %eax
    jnz dlie_bad
    movl $DBUF, %esi
    call verify_pattern
    testl %eax, %eax
    jnz data_bad
    jmp dlie_done
dlie_bad:
    movl $msg_dlie, %esi
    call puts
    incl fail
dlie_done:
    jmp report
a8_bad:
    movl $msg_stuck, %esi
    call puts
    incl fail
    jmp report

io_timeout:
    movl $msg_iocq, %esi
    call puts
    incl fail
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
err_bad:
    movl $msg_err, %esi
    call puts
    incl fail
    jmp report

/* --------------------------------------------------------------- */
/* sata_cmd: issue one command described by s_cmd/s_lba/s_count/
 * s_buf/s_write/s_prdtl; returns eax = 0 ok, 1 error (TFD ERR),
 * 2 timeout.  Clobbers eax, ecx, edx, edi, ebp. */
sata_cmd:
    movl $CTAB, %edi
    movb $0x27, 0(%edi)        /* H2D register FIS */
    movb $0x80, 1(%edi)        /* C = 1 */
    movb s_cmd, %al
    movb %al, 2(%edi)
    movb $0, 3(%edi)           /* features */
    movl s_lba, %eax
    movb %al, 4(%edi)          /* LBA low */
    movb %ah, 5(%edi)          /* LBA mid */
    shrl $16, %eax
    movb %al, 6(%edi)          /* LBA high */
    movb $0x40, 7(%edi)        /* LBA bit, drive 0 */
    movb $0, 8(%edi)           /* LBA upper (0 for our 32-bit LBAs) */
    movb $0, 9(%edi)
    movb $0, 10(%edi)
    movl s_count, %eax
    movb %al, 12(%edi)         /* sector count low */
    movb %ah, 13(%edi)         /* sector count high */
    movb $0, 14(%edi)          /* control */
    movb $0, 15(%edi)
    /* PRDT at CTAB+0x80: one 4 KiB entry */
    movl s_buf, %eax
    movl %eax, 0x80(%edi)
    movl $0, 0x84(%edi)
    movl $0, 0x88(%edi)
    movl $0x80000fff, 0x8c(%edi) /* I bit | (4096-1) */
    /* command header at CLB */
    movl $CLB, %edi
    movl s_prdtl, %eax
    shll $16, %eax
    movl s_write, %edx
    shll $6, %edx              /* AHCI_CMD_WRITE = 1 << 6 */
    orl %edx, %eax
    movl %eax, 0(%edi)
    movl $0, 4(%edi)
    movl $CTAB, 8(%edi)
    movl $0, 12(%edi)
    /* issue: clear stale port interrupt bits (RW1C), then PxCI = 1.
     * Completion is CI-clear OR PxIS.TFES (bit 30): per AHCI 1.3.1
     * 3.3.14 PxCI only clears when the D2H FIS clears BSY/DRQ/ERR, so
     * an errored command leaves CI set and TFES is the signal. */
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+0x10(%ebp)     /* PxIS: write-1-clear */
    movl $1, %eax
    movl %eax, P0+P_CI(%ebp)
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  movl P0+P_CI(%ebp), %eax
    testl $1, %eax
    jz 2f
    movl P0+0x10(%ebp), %eax     /* PxIS */
    testl $0x40000000, %eax      /* TFES */
    jnz 3f
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $2, %edx
    ja 4f
    jb 1b
    cmpl $0x540be400, %eax       /* budget ~1e10 ticks (seconds-scale
                                  * media delays must complete inside) */
    jb 1b
4:  movl $2, %eax
    ret
2:  movl P0+P_TFD(%ebp), %eax
    testl $1, %eax               /* QEMU packs TFD as (error<<8)|status */
    jnz 3f
    xorl %eax, %eax
    ret
3:  /* error recovery (spec 3.3.14): clear TFES, then toggle PxCMD.ST
     * off and on - writing ST from 1 to 0 clears PxCI, so the slot is
     * free for the driver's retry. */
    movl bar0, %ebp
    movl P0+P_TFD(%ebp), %eax
    movl %eax, %edx
    shrl $8, %edx
    andl $0xff, %edx
    movl %edx, s_err           /* task-file error register (ATA-6 7.9):
                                 * UNC (0x40) for uncorrectable media */
    movl $0x40000000, %eax
    movl %eax, P0+0x10(%ebp)     /* clear TFES (RW1C) */
    movl P0+P_CMD(%ebp), %eax
    andl $0xfffffff8, %eax       /* clear ST (keep FRE/SUD/POD) */
    movl %eax, P0+P_CMD(%ebp)
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    movl P0+P_CMD(%ebp), %eax
    orl $1, %eax
    movl %eax, P0+P_CMD(%ebp)    /* ST back on */
    movl $1, %eax
    ret

/* ncq_cmd: issue an NCQ READ FIS (tag 0, slot 0) using s_lba/s_count/
 * s_buf; waits for the SDB-driven PxSACT bit 0 to clear.  eax = 0
 * done (data in s_buf, sdb_payload = the SDB SAct payload), 1 NCQ
 * error (TFD error in s_err, ST-toggle recovery done), 2 timeout (the
 * tag stayed stuck - the SDB-lie signature).  Clobbers eax, ecx, edx,
 * esi, edi, ebp. */
ncq_cmd:
    movl $CTAB, %edi
    movb $0x27, 0(%edi)        /* H2D register FIS */
    movb $0x80, 1(%edi)        /* C = 1 */
    movb $ATA_NCQ_READ, 2(%edi)
    movl s_count, %eax
    movb %al, 3(%edi)          /* sector_count_low = the transfer count */
    movl s_lba, %eax
    movb %al, 4(%edi)          /* lba0 */
    movb %ah, 5(%edi)          /* lba1 */
    shrl $16, %eax
    movb %al, 6(%edi)          /* lba2 */
    movb $0x40, 7(%edi)        /* device: LBA bit */
    movb $0, 8(%edi)           /* lba3 */
    movb $0, 9(%edi)           /* lba4 */
    movb $0, 10(%edi)          /* lba5 */
    movb $0, 11(%edi)          /* sector_count_high (features 15:8) */
    movl ncq_tag, %eax
    shll $3, %eax
    movb %al, 12(%edi)         /* tag (bits 7:3) */
    movb $0, 13(%edi)          /* prio */
    movb $0, 14(%edi)          /* icc */
    movb $0, 15(%edi)          /* control */
    /* PRDT at CTAB+0x80: one 4 KiB entry */
    movl s_buf, %eax
    movl %eax, 0x80(%edi)
    movl $0, 0x84(%edi)
    movl $0, 0x88(%edi)
    movl $0x80000fff, 0x8c(%edi)
    /* command header at CLB (slot 0) */
    movl $CLB, %edi
    movl s_prdtl, %eax
    shll $16, %eax
    movl %eax, 0(%edi)
    movl $0, 4(%edi)
    movl $CTAB, 8(%edi)
    movl $0, 12(%edi)
    /* issue: PxSACT bit 0 (tag outstanding), then PxCI bit 0 */
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+0x10(%ebp)     /* PxIS: write-1-clear */
    movl $1, %eax
    movl ncq_tag, %ecx
    shll %cl, %eax             /* PxSACT bit = 1 << tag */
    movl %eax, P0+P_SACT(%ebp)
    movl %eax, ncq_sact
    movl $1, %eax
    movl %eax, P0+P_CI(%ebp)
    rdtsc
    movl %eax, t0_lo
    movl %edx, t0_hi
1:  movl P0+0x10(%ebp), %eax
    testl $0x40000000, %eax      /* TFES (SDB with ERR) */
    jnz 3f
    movl P0+P_SACT(%ebp), %eax
    movl ncq_sact, %edx
    testl %edx, %eax
    jz 2f
    rdtsc
    subl t0_lo, %eax
    sbbl t0_hi, %edx
    cmpl $2, %edx
    ja 4f
    jb 1b
    cmpl $0x540be400, %eax
    jb 1b
4:  movl $2, %eax
    ret
2:  /* tag 0 done: record the SDB SAct payload (the lie check) */
    movl $FB, %esi
    addl $FB_SDB, %esi
    movl 4(%esi), %eax
    movl %eax, sdb_payload
    xorl %eax, %eax
    ret
3:  /* NCQ error: TFD error register; the device error state persists
     * (status ERR re-raises TFES on every subsequent D2H), so the
     * recovery is a COMRESET (PxSCTL DET 1->0), not just an ST toggle
     * the same port reset the a8 wedge phase uses */
    movl P0+P_TFD(%ebp), %eax
    movl %eax, %edx
    shrl $8, %edx
    andl $0xff, %edx
    movl %edx, s_err
    movl $0x40000000, %eax
    movl %eax, P0+0x10(%ebp)     /* clear TFES (RW1C) */
    movl $1, %eax
    movl %eax, P0+0x2c(%ebp)     /* PxSCTL DET = 1 */
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    movl $0, %eax
    movl %eax, P0+0x2c(%ebp)     /* DET = 0 -> COMRESET */
    movl $1000000, %ecx
1:  movl P0+P_SSTS(%ebp), %eax
    andl $0xf, %eax
    cmpl $3, %eax
    je 2f
    decl %ecx
    jnz 1b
    movl $msg_det, %esi
    call puts
    incl fail
    movl $2, %eax
    ret
2:  movl P0+P_SIG(%ebp), %eax
    cmpl $0x00000101, %eax
    jne 3f
    movl $1, %eax                /* error observed + recovered */
    ret
3:  movl $msg_sig, %esi
    call puts
    incl fail
    movl $1, %eax
    ret

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

/* --------------------------------------------------------------- */
/* pcicfg / pcicfg_write: edi = DEVFN (device<<3|function), ecx =
 * offset.  NOTE this differs from nvmetest.S's helper, which treats
 * edi as a device number at function 0 (device << 11): the ICH9 SATA
 * controller is at device 31 function 2 (devfn 0xfa), invisible to a
 * function-0-only scan.  The PCI config address encodes devfn in bits
 * 15:8, i.e. devfn << 8. */
pcicfg:
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $8, %ebx
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
    shll $8, %ebx
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
.set NTO64_NEEDS_SEQ, 1
.include "nto64-expect.inc"

/* verify_expect: compare each phase to the expected-value string (one
 * hex digit per phase, in report order: a1,a2,a3,a4,a5,pf,sl,su,st,rs,
 * nq,slie,dlie; the s_err field is a live error-register snapshot, not a
 * phase indicator, so position 10 is a placeholder and not checked).  A
 * dead fault hook leaves a phase at its clean value, which then
 * mismatches, so a fault run cannot silently pass. */
.macro CHECK_EXPECT off, var
    movl expect+\off, %eax
    cmpl %eax, \var
    je .Lve_ok_\off
    incl fail
.Lve_ok_\off:
.endm

verify_expect:
    call nto64_expect_seq
    testl %eax, %eax
    jz .Lve_done
    CHECK_EXPECT 0, a1
    CHECK_EXPECT 4, a2
    CHECK_EXPECT 8, a3
    CHECK_EXPECT 12, a4
    CHECK_EXPECT 16, a5
    CHECK_EXPECT 20, pf
    CHECK_EXPECT 24, sl
    CHECK_EXPECT 28, su
    CHECK_EXPECT 32, st
    CHECK_EXPECT 36, rs
    CHECK_EXPECT 44, nq
    CHECK_EXPECT 48, slie
    CHECK_EXPECT 52, dlie
.Lve_done:
    ret

/* report: print the result line, then halt */
report:
    call verify_expect
    movl $msg_ahci, %esi
    call puts
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $sp_sig, %esi
    call puts
    movl $0x00000101, %eax
    call puthex
    movl $sp_cap, %esi
    call puts
    movl cap, %eax
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
    movl $sp_pf, %esi
    call puts
    movl pf, %eax
    call puthex
    movl $sp_sl, %esi
    call puts
    movl sl, %eax
    call puthex
    movl $sp_su, %esi
    call puts
    movl su, %eax
    call puthex
    movl $sp_st, %esi
    call puts
    movl st, %eax
    call puthex
    movl $sp_rs, %esi
    call puts
    movl rs, %eax
    call puthex
    movl $sp_er, %esi
    call puts
    movl s_err, %eax
    call puthex
    movl $sp_nq, %esi
    call puts
    movl nq, %eax
    call puthex
    movl $sp_slie, %esi
    call puts
    movl slie, %eax
    call puthex
    movl $sp_dlie, %esi
    call puts
    movl dlie, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* --------------------------------------------------------------- */
    .bss
    .balign 16
mbi_ptr: .long 0
expect: .space 64
fail: .long 0
ahci_dev: .long 0
bar0: .long 0
cap: .long 0
a1: .long 0
a2: .long 0
a3: .long 0
a4: .long 0
a5: .long 0
pf: .long 0
sl: .long 0
su: .long 0
st: .long 0
rs: .long 0
nq: .long 0
slie: .long 0
dlie: .long 0
sdb_payload: .long 0
ncq_tag: .long 0
ncq_sact: .long 0
t0_lo: .long 0
t0_hi: .long 0
s_cmd: .long 0
s_lba: .long 0
s_count: .long 0
s_buf: .long 0
s_write: .long 0
s_prdtl: .long 0
s_err: .long 0

    .section .rodata
msg_ahci: .asciz "AHCI OK"
sp_f: .asciz " f="
sp_sig: .asciz " sig="
sp_cap: .asciz " cap="
sp_a1: .asciz " a1="
sp_a2: .asciz " a2="
sp_a3: .asciz " a3="
sp_a4: .asciz " a4="
sp_a5: .asciz " a5="
sp_pf: .asciz " pf="
sp_sl: .asciz " sl="
sp_su: .asciz " su="
sp_st: .asciz " st="
sp_rs: .asciz " rs="
sp_er: .asciz " er="
sp_nq: .asciz " nq="
sp_slie: .asciz " slie="
sp_dlie: .asciz " dlie="
nl: .asciz "\n"
msg_nodev: .asciz "no ahci\n"
msg_hr: .asciz "hba reset timeout\n"
msg_det: .asciz "no device\n"
msg_sig: .asciz "bad signature\n"
msg_ident: .asciz "identify bad\n"
msg_io: .asciz "io error\n"
msg_data: .asciz "data mismatch\n"
msg_iocq: .asciz "cmd timeout\n"
msg_err: .asciz "bad error reg\n"
msg_delay: .asciz "slow media not slow\n"
msg_stuck: .asciz "wedge recovery bad\n"
msg_nq: .asciz "ncq bad\n"
msg_slie: .asciz "sdb lie bad\n"
msg_dlie: .asciz "d2h lie bad\n"
