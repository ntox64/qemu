/* SPDX-License-Identifier: BSD-2-Clause */

/* scsitest.S - freestanding multiboot test for the modern:
 * virtio-scsi + scsi-hd + blkdebug generic SCSI fault slice.
 *
 * A minimal LEGACY virtio-scsi driver (PCI I/O BAR, three vrings: ctrl,
 * event, request) driving the STOCK virtio-scsi-pci + scsi-hd pair over
 * a blkdebug-instrumented raw image.  The driver must survive:
 *   CHECK CONDITION with sense data: a transient EIO read (blkdebug
 *     once at sector 1000) completes as CHECK CONDITION with MEDIUM
 *     ERROR sense (SPC-5 03/11-00 UNRECOVERED READ ERROR); REQUEST
 *     SENSE reads the sense, a bounded retry recovers and the data
 *     must come back intact;
 *   sudden backend errors: a transient ENOSPC write (3000) completes
 *     as CHECK CONDITION and is recovered by a retry;
 *   dropped completion / command timeout / TMF: with the scsi-hd
 *     nto64-drop-sector=4000 fault, the read never completes - the
 *     driver's bounded poll times out, a TMF ABORT_TASK cancels it
 *     (function-complete response), the stale completion is drained,
 *     and the retry succeeds;
 *   LUN reset / unit attention: a TMF LOGICAL_UNIT_RESET makes the
 *     next command complete as CHECK CONDITION with UNIT ATTENTION
 *     (06/29); REQUEST SENSE clears it and the retry succeeds.
 *   TMF breadth (the 2026-08-22 fold): ABORT TASK SET and CLEAR
 *     TASK SET cancel a hung command (the nto64-drop-sector=4000
 *     timeout shape) with a function-complete TMF response and a
 *     drained stale completion, then the retry succeeds (a8/a9=2 on
 *     the fault target); I_T NEXUS RESET surfaces the UNIT ATTENTION
 *     on every target (a10=2) and REQUEST SENSE clears it; and the
 *     ABORT-vs-already-completing race submits a READ without polling,
 *     aborts its tag, drains both rings and tolerates either a normal
 *     completion or an ABORTED response, then reuses the tag (a11=1).
 *   media-change / capacity change (run-scsimedia,
 *     a6): the first command at nto64-media-change-sector completes,
 *     the next command surfaces UNIT ATTENTION CAPACITY DATA HAS
 *     CHANGED (06/2A), READ CAPACITY reports half the sectors and a
 *     read beyond the new end fails LBA OUT OF RANGE;
 *   write-protected media (run-scsiwp, a7): after the command at
 *     nto64-wp-trigger-sector, every write fails DATA PROTECT / WRITE
 *     PROTECTED (07/27) persistently - reads stay available;
 *   bring-up readiness (run-scsibringup, a5): the first
 *     nto64-bringup-fail TEST UNIT READY commands fail NOT READY
 *     (02/04), then recover.
 * Also checks INQUIRY + REPORT LUNS sanity during bring-up.
 *
 * The request wire format (packed, per linux/virtio_scsi.h):
 *   cmd_req: lun[8]@0 (lun[0]=1, lun[1]=target, lun[2..3]=lun),
 *            tag@8 (u64), task_attr@16, prio@17, crn@18, cdb[32]@19;
 *   cmd_resp: sense_len@0, resid@4, status_qualifier@8, status@10
 *            (SCSI status: 0=GOOD, 2=CHECK CONDITION), response@11
 *            (0=ok), sense[96]@12;
 *   tmf_req: type@0 (0=TMF), subtype@4, lun[8]@8, tag@16;
 *   tmf_resp: response@0.
 * QEMU's virtio_scsi_device_get requires lun[0]==1 and reads the target
 * from lun[1] and the LUN from lun[2..3].
 *
 * Machine: -machine pc -m 64, one virtio-scsi-pci (ioeventfd=off - see
 * 's finding) + one scsi-hd on a 4 MiB sparse raw image through
 * blkdebug (raw on top: -drive format=raw,file=blkdebug:conf:img).
 * Build: `make scsitest`, run: `make run-scsitest` (clean),
 * `run-scsifault` (drop-completion via nto64-drop-sector=4000),
 * `run-scsierr` (EIO read + ENOSPC write).
 * Prints 'SCSI ...' and halts.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

#define VQ_CTRL   0
#define VQ_EVENT  1
#define VQ_REQ    2

#define RING_CTRL   0x200000
#define RING_EVENT  0x210000
#define RING_REQ    0x220000

#define CMD_HDR   0x300000        /* 64-byte virtio-scsi cmd req buffer */
#define CDB_BUF   0x300100        /* 16-byte CDB staging */
#define RESP      0x300200        /* 256-byte response+sense buffer */
#define DATA      0x300400        /* 512-byte data buffer */
#define TMF_HDR   0x301000        /* 32-byte TMF request buffer */
#define TMF_RESP  0x301100        /* 4-byte TMF response buffer */

#define VIRTIO_PCI_HOST_FEATURES  0x00
#define VIRTIO_PCI_GUEST_FEATURES 0x04
#define VIRTIO_PCI_QUEUE_PFN      0x08
#define VIRTIO_PCI_QUEUE_SIZE     0x0c
#define VIRTIO_PCI_QUEUE_SEL      0x0e
#define VIRTIO_PCI_QUEUE_NOTIFY   0x10
#define VIRTIO_PCI_STATUS         0x12
#define VIRTIO_PCI_CONFIG         0x14

#define VRING_DESC_F_NEXT         1
#define VRING_DESC_F_WRITE        2

#define VIRTIO_SCSI_S_OK          0
#define VIRTIO_SCSI_S_ABORTED     2
#define VIRTIO_SCSI_S_FUNCTION_SUCCEEDED 10
#define VIRTIO_SCSI_T_TMF         0
#define VIRTIO_SCSI_T_TMF_ABORT_TASK      0
#define VIRTIO_SCSI_T_TMF_ABORT_TASK_SET  1
#define VIRTIO_SCSI_T_TMF_CLEAR_ACA       2
#define VIRTIO_SCSI_T_TMF_CLEAR_TASK_SET  3
#define VIRTIO_SCSI_T_TMF_I_T_NEXUS_RESET 4
#define VIRTIO_SCSI_T_TMF_LOGICAL_UNIT_RESET 5

#define SCSI_STATUS_GOOD          0x00
#define SCSI_STATUS_CHECK         0x02
#define SENSE_KEY_MEDIUM_ERROR    0x03
#define SENSE_KEY_UNIT_ATTENTION  0x06
#define SENSE_KEY_NOT_READY       0x02
#define SENSE_KEY_ILLEGAL_REQUEST 0x05
#define SENSE_KEY_DATA_PROTECT    0x07

/* media-change / write-protect test sectors
 * (4 MiB image = 8192 sectors; MC_OLD_END must exist on clean runs) */
#define MC_TRIG     100
#define MC_OLD_END  6000
#define WP_TRIG     500
#define WP_TEST     600

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

    /* zero the staging area: cmd header, cdb, resp, data, tmf buffers */
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
    movl %edi, %ecx
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
    jmp no_dev
found_scsi:
    movl %edi, scsi_dev

    /* --- enable I/O + bus master, read the I/O BAR0 ---- */
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

    /* --- legacy virtio bring-up ---- */
    voutw VIRTIO_PCI_STATUS, $0           /* reset */
    voutw VIRTIO_PCI_STATUS, $1           /* ACKNOWLEDGE */
    voutw VIRTIO_PCI_STATUS, $3           /* | DRIVER */
    vinw VIRTIO_PCI_HOST_FEATURES, %ebx   /* host features (ignored) */
    voutl VIRTIO_PCI_GUEST_FEATURES, $0

    /* zero all three vring areas (3 pages each) */
    movl $RING_CTRL, %edi
    xorl %eax, %eax
    movl $0x9000, %ecx
1:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 1b

    /* set up vq0 (ctrl), vq1 (event), vq2 (request) */
    movl $0, %edi
    movl $RING_CTRL, %esi
    call setup_vq
    movl $1, %edi
    movl $RING_EVENT, %esi
    call setup_vq
    movl $2, %edi
    movl $RING_REQ, %esi
    call setup_vq

    voutw VIRTIO_PCI_STATUS, $7             /* | DRIVER_OK */

    /* --- P0': bring-up readiness (run-scsibringup) ----
     * With nto64-bringup-fail=N the first N TEST UNIT READY commands
     * fail with NOT READY (02/04) while the logical unit initializes;
     * the driver polls with a bound (SPC-5 5.1.2.5 - TUR is the
     * command to poll a logical unit until ready).  Clean targets:
     * the first TUR is GOOD and a5 stays 1. */
    movl $1, a5
    movl $0, bup_fail_seen
    movl $0, bup_retries
1:  movl $CDB_BUF, %edi
    movb $0x00, 0(%edi)        /* TEST UNIT READY */
    movl $0x1050, %eax
    movl $CDB_BUF, %ebx
    xorl %ecx, %ecx            /* no data */
    call scsi_cmd
    testb %al, %al
    jnz bup_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jz bup_ok
    cmpb $SCSI_STATUS_CHECK, %al
    jne bup_bad
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_UNIT_ATTENTION, %al
    jne bup_nr
    /* a power-on / device-reset unit attention precedes the very
     * first command: clear it with REQUEST SENSE and re-probe */
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)          /* REQUEST SENSE */
    movb $6, 4(%edi)
    movl $0x1051, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz bup_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz bup_bad
    jmp 1b
bup_nr:
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_NOT_READY, %al
    jne bup_bad
    incl bup_fail_seen
    incl bup_retries
    cmpl $16, bup_retries
    jae bup_bad
    jmp 1b
bup_ok:
    movl bup_fail_seen, %eax
    testl %eax, %eax
    jz bup_done
    movl $2, a5
bup_done:
    jmp p0_cont
bup_bad:
    FAILPT 'B'
p0_cont:

    /* --- P0: config + INQUIRY + REPORT LUNS ---- */
    movl io_base, %edx
    addl $VIRTIO_PCI_CONFIG, %edx
    addl $30, %edx
    inw %dx, %ax
    movzwl %ax, %eax
    movl %eax, max_target
    movl io_base, %edx
    addl $VIRTIO_PCI_CONFIG, %edx
    addl $32, %edx
    inl %dx, %eax
    movl %eax, max_lun

    /* INQUIRY (0x12), alloc 96 */
    movl $CDB_BUF, %edi
    movb $0x12, 0(%edi)
    movb $0, 1(%edi)
    movb $0, 6(%edi)
    movb $96, 7(%edi)
    movl $0x1000, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx              /* data-in 512B */
    call scsi_cmd
    testb %al, %al
    jz 1f
    movl $'T', %eax
    call putc
    FAILPT '0'
    jmp p0_ok
1:
    movzbl RESP+11, %eax       /* response */
    testb %al, %al
    jnz p0_bad
    movzbl RESP+10, %eax       /* status */
    testb %al, %al
    jnz p0_bad
    jmp p0_ok
p0_bad:
    FAILPT '0'
p0_ok:

    /* REPORT LUNS (0xa0), alloc 16 */
    movl $CDB_BUF, %edi
    movb $0xa0, 0(%edi)
    movb $0, 6(%edi)
    movb $0, 7(%edi)
    movb $0, 8(%edi)
    movb $16, 9(%edi)
    movl $0x1001, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0l_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p0l_bad
    jmp p0l_ok
p0l_bad:
    FAILPT '1'
p0l_ok:

    /* --- P0b: data path - read s0 (zeros), write/read s1 ---- */
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)        /* READ(10) */
    movl $0, 2(%edi)           /* LBA 0 (BE) */
    movb $0, 7(%edi)
    movb $1, 8(%edi)           /* blocks = 1 */
    movl $0x1002, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0b_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne 9f
    /* the device reset leaves a UNIT ATTENTION for the first command:
     * verify the sense key and clear it with REQUEST SENSE, then retry */
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_UNIT_ATTENTION, %al
    jne p0b_bad
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)
    movb $6, 4(%edi)
    movl $0x1005, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0b_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p0b_bad
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $0, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1006, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0b_bad
    movzbl RESP+10, %eax
9:  testb %al, %al
    jnz p0b_bad
    movl $DATA, %edi
    movl $128, %ecx
    xorl %eax, %eax
1:  cmpl %eax, (%edi)
    jne p0b_bad
    addl $4, %edi
    decl %ecx
    jnz 1b

    movl $0xa5a5a5a5, %eax
    call fill_data
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)        /* WRITE(10) */
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)         /* LBA 1 (BE) */
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1003, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0b_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p0b_bad

    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1004, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p0b_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p0b_bad
    movl $0xa5a5a5a5, %eax
    call verify_data
    testl %eax, %eax
    jz p0b_ok
p0b_bad:
    FAILPT '2'
p0b_ok:

    /* --- P1: CHECK CONDITION recovery (EIO read once @1000) ---- */
    movl $0x11223344, %eax
    call fill_data
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)
    movl $1000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1010, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p1_prebad
    movzbl RESP+10, %eax
    testb %al, %al
    jz 1f
p1_prebad:
    FAILPT '3'
1:  movl $1, a1
p1_retry:
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1011, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p1_timeout
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p1_ok
    /* CHECK CONDITION: verify the MEDIUM ERROR sense (SPC-5 03/11-00
     * for a media read error), then REQUEST SENSE */
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_MEDIUM_ERROR, %al
    jne p1_bad
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)        /* REQUEST SENSE */
    movb $6, 4(%edi)           /* alloc = 6 */
    movl $0x1012, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p1_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p1_bad
    cmpl $8, a1
    jae p1_bad
    incl a1
    jmp p1_retry
p1_ok:
    movl $0x11223344, %eax
    call verify_data
    testl %eax, %eax
    jz p1_done
p1_timeout:
p1_bad:
    FAILPT '4'
p1_done:

    /* --- P1b: sudden ENOSPC write @3000 (retry recovers) ---- */
    movl $0x55667788, %eax
    call fill_data
    movl $1, a2
p1b_retry:
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)
    movl $3000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1020, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p1b_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_GOOD, %al
    je p1b_ok
    cmpl $8, a2
    jae p1b_bad
    incl a2
    jmp p1b_retry
p1b_ok:
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $3000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1021, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p1b_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p1b_bad
    movl $0x55667788, %eax
    call verify_data
    testl %eax, %eax
    jz p1b_done
p1b_bad:
    FAILPT '5'
p1b_done:

    /* --- P2: dropped completion / timeout / TMF abort @4000 ----
     * With scsi-hd nto64-drop-sector=4000 the read never completes: the
     * bounded poll times out, TMF ABORT_TASK cancels it, the stale
     * used entry is drained, and the retry succeeds.  Without the fault
     * (clean run) the read completes immediately and no TMF is sent. */
    movl $1, a3
    movl $0, tmf
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1030, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    cmpb $0xff, %al
    jne p2_complete
    /* timed out: TMF ABORT_TASK for tag 0x1030 */
    movl $VIRTIO_SCSI_T_TMF_ABORT_TASK, %eax
    movl $0x1030, %ebx
    call scsi_tmf
    movl %eax, tmf
    testl %eax, %eax
    jnz p2_bad
    call vq_drain
    incl a3
    jmp p2_retry
p2_complete:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p2_bad
    jmp p2_done
p2_retry:
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4000, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1031, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p2_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p2_bad
    jmp p2_done
p2_bad:
    FAILPT '6'
p2_done:

    /* --- P3: LUN reset -> unit attention on the next command ---- */
    movl $VIRTIO_SCSI_T_TMF_LOGICAL_UNIT_RESET, %eax
    movl $0, %ebx
    call scsi_tmf
    testl %eax, %eax
    jnz p3_bad

    movl $1, a4
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1040, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p3_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p3_ua_clean
    /* UNIT ATTENTION: verify sense key 06, then REQUEST SENSE, retry */
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_UNIT_ATTENTION, %al
    jne p3_bad
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)
    movb $6, 4(%edi)
    movl $0x1041, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p3_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p3_bad
    incl a4
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1042, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p3_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p3_bad
    movl $0xa5a5a5a5, %eax
    call verify_data
    testl %eax, %eax
    jz p4_start
    jmp p3_bad
p3_ua_clean:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p3_bad
    jmp p4_start
p3_bad:
    FAILPT '7'

    /* --- P4: media change -> capacity change (run-scsimedia) ----
     * With nto64-media-change-sector=X the first command at X
     * completes and the media changes: the next command returns
     * CHECK CONDITION with UNIT ATTENTION / CAPACITY DATA HAS CHANGED
     * (SPC-5 06/2A-09), READ CAPACITY reports half the sectors, and a
     * read beyond the new end fails with ILLEGAL REQUEST / LBA OUT OF
     * RANGE - the driver must clear the UA, re-read the capacity and
     * re-validate its I/O ranges.  Clean targets: no UA, unchanged
     * capacity, the old-end read still works (a6 stays 1). */
p4_start:
    movl $1, a6
    movl $0, mc_seen
    /* prefill at MC_TRIG (the write completes; on the fault target it
     * also triggers the change, queueing the UA for the next command) */
    movl $0x11223344, %eax
    call fill_data
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)          /* WRITE(10) */
    movl $MC_TRIG, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1060, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p4_bad
    /* read at MC_TRIG: on the fault target this surfaces the UA */
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $MC_TRIG, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1061, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p4_noua
    /* the UA: verify key 06, clear with REQUEST SENSE, retry the read */
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_UNIT_ATTENTION, %al
    jne p4_bad
    incl mc_seen
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)          /* REQUEST SENSE */
    movb $6, 4(%edi)
    movl $0x1062, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p4_bad
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $MC_TRIG, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1063, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p4_bad
    movl $0x11223344, %eax
    call verify_data
    testl %eax, %eax
    jnz p4_bad
p4_noua:
    /* READ CAPACITY: reports the new (halved on the fault target) size */
    movl $CDB_BUF, %edi
    movb $0x25, 0(%edi)          /* READ CAPACITY(10) */
    movb $8, 7(%edi)
    movl $0x1064, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p4_bad
    movl DATA, %eax              /* last LBA (BE) */
    bswap %eax
    movl %eax, mc_cap
    /* a read beyond the new end: must succeed on clean, fail on fault */
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $MC_OLD_END, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1065, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p4_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p4_clean
    /* CHECK CONDITION: must be ILLEGAL REQUEST (key 05) AND the UA
     * must have been observed (the capacity really shrank) */
    movl mc_seen, %eax
    testl %eax, %eax
    jz p4_bad
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_ILLEGAL_REQUEST, %al
    jne p4_bad
    movl $2, a6
    jmp p4_done
p4_clean:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p4_bad
    movl mc_seen, %eax
    testl %eax, %eax
    jnz p4_bad          /* a change was seen but the old-end read worked:
                         * the capacity did not shrink - inconsistent */
    jmp p4_done
p4_bad:
    FAILPT '8'
p4_done:

    /* --- P5: write-protected media (run-scsiwp) ----
     * With nto64-wp-trigger-sector=X the first command at X completes
     * and the media becomes write-protected: every later write fails
     * with DATA PROTECT / WRITE PROTECTED (SPC-5 07/27-00)
     * persistently, so the driver must stop retrying writes and keep
     * reads available.  Clean targets: the write succeeds (a7 stays
     * 1). */
    movl $1, a7
    movl $0, wp_seen
    /* prefill at WP_TRIG (succeeds; on the fault target it arms wp) */
    movl $0x55667788, %eax
    call fill_data
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)
    movl $WP_TRIG, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1070, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p5_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p5_bad
    /* write at WP_TEST: fails 07/27 on the fault target */
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)
    movl $WP_TEST, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1071, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p5_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p5_clean
    /* verify DATA PROTECT (key 07), clear with REQUEST SENSE */
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_DATA_PROTECT, %al
    jne p5_bad
    incl wp_seen
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)
    movb $6, 4(%edi)
    movl $0x1072, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p5_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p5_bad
    /* a second write must fail identically: the protection persists,
     * so the driver must NOT keep retrying */
    movl $CDB_BUF, %edi
    movb $0x2a, 0(%edi)
    movl $WP_TEST, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1073, %eax
    movl $CDB_BUF, %ebx
    movl $2, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p5_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p5_bad
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_DATA_PROTECT, %al
    jne p5_bad
    movl $2, a7
    jmp p5_read
p5_clean:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p5_bad
p5_read:
    /* reads still work on both targets */
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $WP_TRIG, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1074, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p5_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p5_bad
    movl $0x55667788, %eax
    call verify_data
    testl %eax, %eax
    jz p5_done
p5_bad:
    FAILPT '9'
p5_done:

    /* --- P6: TMF ABORT TASK SET (subtype 1) ----
     * Same shape as P2 but the task-set TMF: with the
     * nto64-drop-sector2=4001 fault the read times out, ABORT TASK SET
     * cancels the LUN's tasks, the stale completion is drained and the
     * retry succeeds (a8=2 on the fault target, a8=1 clean). */
    movl $1, a8
    movl $0, tmf
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4001, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1050, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    cmpb $0xff, %al
    jne p6_complete
    movl $VIRTIO_SCSI_T_TMF_ABORT_TASK_SET, %eax
    movl $0xffffffff, %ebx
    call scsi_tmf
    movl %eax, tmf
    testl %eax, %eax
    jnz p6_bad
    call vq_drain
    incl a8
    jmp p6_retry
p6_complete:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p6_bad
    jmp p6_done
p6_retry:
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4001, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1051, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p6_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p6_bad
    jmp p6_done
p6_bad:
    FAILPT 'A'
p6_done:

    /* --- P7: TMF CLEAR TASK SET (subtype 3) ----
     * Same as P6 with the clear-task-set TMF (a9=2 on the fault
     * target, a9=1 clean). */
    movl $1, a9
    movl $0, tmf
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4002, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1052, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    cmpb $0xff, %al
    jne p7_complete
    movl $VIRTIO_SCSI_T_TMF_CLEAR_TASK_SET, %eax
    movl $0xffffffff, %ebx
    call scsi_tmf
    movl %eax, tmf
    testl %eax, %eax
    jnz p7_bad
    call vq_drain
    incl a9
    jmp p7_retry
p7_complete:
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p7_bad
    jmp p7_done
p7_retry:
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $4002, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1053, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p7_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p7_bad
    jmp p7_done
p7_bad:
    FAILPT 'B'
p7_done:

    /* --- P8: TMF I_T NEXUS RESET (subtype 4) ----
     * Nexus-level reset: the next command surfaces UNIT ATTENTION
     * (sense key 06) on every target, REQUEST SENSE clears it and the
     * retry succeeds (a10=2). */
    movl $1, a10
    movl $VIRTIO_SCSI_T_TMF_I_T_NEXUS_RESET, %eax
    movl $0xffffffff, %ebx
    call scsi_tmf
    testl %eax, %eax
    jnz p8_bad
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1060, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p8_bad
    movzbl RESP+10, %eax
    cmpb $SCSI_STATUS_CHECK, %al
    jne p8_bad
    movzbl RESP+14, %eax
    andb $0x0f, %al
    cmpb $SENSE_KEY_UNIT_ATTENTION, %al
    jne p8_bad
    movl $CDB_BUF, %edi
    movb $0x03, 0(%edi)
    movb $6, 4(%edi)
    movl $0x1061, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p8_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p8_bad
    incl a10
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1062, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p8_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p8_bad
    jmp p8_done
p8_bad:
    FAILPT 'C'
p8_done:

    /* --- P9: ABORT_TASK racing an already-completing command ----
     * A normal READ is submitted WITHOUT polling, then ABORT_TASK is
     * sent for its tag before the completion is consumed.  The
     * command may finish before or after the abort - the TMF response
     * is FUNCTION COMPLETE either way and the command's used entry is
     * either a normal completion (response 0) or an ABORTED response
     * (2).  The driver drains both rings, tolerates either outcome,
     * and reuses the tag cleanly (a11=1). */
    movl $1, a11
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    /* cmd_req at CMD_HDR, tag 0x1080 */
    movl $CMD_HDR, %edi
    movb $1, 0(%edi)
    movl $0, 4(%edi)
    movl $0x1080, %eax
    movl %eax, 8(%edi)
    movl $0, 12(%edi)
    movl $0, 16(%edi)
    movl $CDB_BUF, %ebx
    xorl %edx, %edx
1:  movb (%ebx,%edx), %al
    movb %al, 19(%edi,%edx)
    incl %edx
    cmpl $16, %edx
    jb 1b
    xorl %eax, %eax
    movl $15, %edx
2:  movb %al, 35(%edi,%edx)
    decl %edx
    jns 2b
    /* descriptors: d0 = CMD_HDR (NEXT->1), d1 = RESP (IN, NEXT->2),
     * d2 = DATA (IN) */
    movl $RING_REQ, %edi
    movl $CMD_HDR, 0(%edi)
    movl $83, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)
    movl $RESP, 16(%edi)
    movl $204, 24(%edi)
    movw $(VRING_DESC_F_NEXT | VRING_DESC_F_WRITE), 28(%edi)
    movw $2, 30(%edi)
    movl $DATA, 32(%edi)
    movl $512, 40(%edi)
    movw $VRING_DESC_F_WRITE, 44(%edi)
    /* avail idx++ + notify WITHOUT polling the request ring */
    movl q_avail+8, %edi
    movl q_availidx+8, %eax
    movl q_mask+8, %edx
    andl %edx, %eax
    movw $0, 4(%edi,%eax,2)
    movl q_availidx+8, %eax
    incl %eax
    movl %eax, q_availidx+8
    movw %ax, 2(%edi)
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    movw $2, %ax
    outw %ax, %dx
    /* abort the tag before consuming the completion */
    movl $VIRTIO_SCSI_T_TMF_ABORT_TASK, %eax
    movl $0x1080, %ebx
    call scsi_tmf
    movl %eax, tmf
    testl %eax, %eax
    jnz p9_bad
    call vq_drain
    /* the command entry: status GOOD and response ok(0) or aborted(2) */
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p9_bad
    movzbl RESP+11, %eax
    cmpb $VIRTIO_SCSI_S_ABORTED, %al
    je 3f
    testb %al, %al
    jnz p9_bad
3:  /* the tag is reusable */
    movl $CDB_BUF, %edi
    movb $0x28, 0(%edi)
    movl $1, %eax
    bswap %eax
    movl %eax, 2(%edi)
    movb $0, 7(%edi)
    movb $1, 8(%edi)
    movl $0x1080, %eax
    movl $CDB_BUF, %ebx
    movl $1, %ecx
    call scsi_cmd
    testb %al, %al
    jnz p9_bad
    movzbl RESP+10, %eax
    testb %al, %al
    jnz p9_bad
    jmp p9_done
p9_bad:
    FAILPT 'D'
p9_done:

p3_done:
    jmp report

no_dev:
    movl $msg_nodev, %esi
    call puts
    jmp halt

/* --------------------------------------------------------------- */
/* setup_vq: edi = vq index, esi = ring base.  Reads the queue size,
 * zeroes the ring, computes avail/used, stores per-vq state, and writes
 * the queue PFN.  Clobbers eax..edx, esi, edi. */
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
    /* avail = ring + 16*qn ; used = align4096(avail + 6 + 2*qn) */
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
    /* zero the ring (3 pages) */
    movl %esi, %edi
    xorl %eax, %eax
    movl $0x3000, %ecx
2:  movb %al, (%edi)
    incl %edi
    decl %ecx
    jnz 2b
    /* queue PFN */
    movl %esi, %eax
    shrl $12, %eax
    movl %eax, %ebx
    voutl VIRTIO_PCI_QUEUE_PFN, %ebx
    ret

/* scsi_cmd: eax = tag, ebx = cdb buffer (16 bytes), ecx = dir
 * (0 = no data, 1 = data-in, 2 = data-out).  Submits on the request vq
 * and polls.  Returns 0 on completion, 0xff on poll timeout.
 * Clobbers most registers. */
scsi_cmd:
    /* header: lun{1,0,0,0,0,0,0,0}, tag, attr/prio/crn=0, cdb[32] */
    movl $CMD_HDR, %edi
    movb $1, 0(%edi)
    movl $0, 4(%edi)
    movl %eax, 8(%edi)         /* tag lo */
    movl $0, 12(%edi)          /* tag hi */
    movl $0, 16(%edi)          /* task_attr/prio/crn + padding */
    xorl %edx, %edx
1:  movb (%ebx,%edx), %al
    movb %al, 19(%edi,%edx)
    incl %edx
    cmpl $16, %edx
    jb 1b
    xorl %eax, %eax
    movl $15, %edx
2:  movb %al, 35(%edi,%edx)
    decl %edx
    jns 2b

    /* descriptors on the request vq (ring 0x220000) */
    movl $RING_REQ, %edi
    movl $CMD_HDR, 0(%edi)
    movl $83, 8(%edi)            /* 51-byte req + 32-byte cdb */
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)
    testl %ecx, %ecx
    jz nodata
    cmpl $1, %ecx
    jne 3f
    /* data-in: d1 = response (IN, NEXT -> 2), d2 = data (IN) */
    movl $RESP, 16(%edi)
    movl $204, 24(%edi)          /* resp(108) + sense(96) */
    movw $(VRING_DESC_F_NEXT | VRING_DESC_F_WRITE), 28(%edi)
    movw $2, 30(%edi)
    movl $DATA, 32(%edi)
    movl $512, 40(%edi)
    movw $VRING_DESC_F_WRITE, 44(%edi)
    jmp submit
3:  /* data-out: d1 = data (OUT, NEXT -> 2), d2 = response (IN) */
    movl $DATA, 16(%edi)
    movl $512, 24(%edi)
    movw $VRING_DESC_F_NEXT, 28(%edi)
    movw $2, 30(%edi)
    movl $RESP, 32(%edi)
    movl $204, 40(%edi)
    movw $VRING_DESC_F_WRITE, 44(%edi)
    jmp submit
nodata:
    movl $RESP, 16(%edi)
    movl $204, 24(%edi)
    movw $VRING_DESC_F_WRITE, 28(%edi)
submit:
    movl $VQ_REQ, %eax
    call vq_submit
    ret

/* scsi_tmf: eax = subtype, ebx = tag.  Submits on the ctrl vq.
 * Returns 0 on success (function-complete response), 0xff on timeout. */
scsi_tmf:
    movl $TMF_HDR, %edi
    movl $VIRTIO_SCSI_T_TMF, 0(%edi)
    movl %eax, 4(%edi)
    movb $1, 8(%edi)
    movl $0, 12(%edi)
    movl %ebx, 16(%edi)
    movl $0, 20(%edi)

    movl $RING_CTRL, %edi
    movl $TMF_HDR, 0(%edi)
    movl $24, 8(%edi)
    movw $VRING_DESC_F_NEXT, 12(%edi)
    movw $1, 14(%edi)
    movl $TMF_RESP, 16(%edi)
    movl $4, 24(%edi)
    movw $VRING_DESC_F_WRITE, 28(%edi)

    movl $VQ_CTRL, %eax
    call vq_submit
    testb %al, %al
    jnz 1f
    movzbl TMF_RESP, %eax
    cmpb $VIRTIO_SCSI_S_OK, %al
    je 2f
    cmpb $VIRTIO_SCSI_S_FUNCTION_SUCCEEDED, %al
    je 2f
    movl $1, %eax
    ret
2:  xorl %eax, %eax
    ret
1:  movl $0xff, %eax
    ret

/* vq_submit: eax = vq index; descriptors prebuilt in that vq's ring,
 * head = 0.  Appends to avail, notifies, polls used.  Returns 0 on
 * completion, 0xff on timeout.  Clobbers eax..edi. */
vq_submit:
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
    /* notify vq eax */
    movl io_base, %edx
    addl $VIRTIO_PCI_QUEUE_NOTIFY, %edx
    outw %ax, %dx
    /* poll used.idx */
    movl %eax, %ecx
    movl q_used(,%ecx,4), %edi
    movl $200000000, %edx
1:  movzwl 2(%edi), %eax
    cmpl q_lastused(,%ecx,4), %eax
    jne 2f
    decl %edx
    jnz 1b
    movl $0xff, %eax
    ret
2:  movl %eax, q_lastused(,%ecx,4)
    xorl %eax, %eax
    ret

/* vq_drain: consume any pending used entries on the request vq (the
 * cancelled request's completion after a TMF).  Clobbers eax, edi. */
vq_drain:
    movl $2, %ecx
    movl q_used(,%ecx,4), %edi
    movzwl 2(%edi), %eax
    movl %eax, q_lastused(,%ecx,4)
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
.set NTO64_NEEDS_SEQ, 1
.include "nto64-expect.inc"

/* verify_expect: compare each phase to the expected-value string (one
 * hex digit per phase, in report order: a1..a11).  A dead fault hook
 * leaves the phase at its clean value, which then mismatches, so a
 * fault run cannot silently pass. */
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
    CHECK_EXPECT 20, a6
    CHECK_EXPECT 24, a7
    CHECK_EXPECT 28, a8
    CHECK_EXPECT 32, a9
    CHECK_EXPECT 36, a10
    CHECK_EXPECT 40, a11
.Lve_done:
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
    movl q_ring+8, %eax
    call puthex
    movl $sp_tg, %esi
    call puts
    movl max_target, %eax
    call puthex
    movl $sp_lun, %esi
    call puts
    movl max_lun, %eax
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
    movl $sp_a7, %esi
    call puts
    movl a7, %eax
    call puthex
    movl $sp_a8, %esi
    call puts
    movl a8, %eax
    call puthex
    movl $sp_a9, %esi
    call puts
    movl a9, %eax
    call puthex
    movl $sp_a10, %esi
    call puts
    movl a10, %eax
    call puthex
    movl $sp_a11, %esi
    call puts
    movl a11, %eax
    call puthex
    movl $sp_tm, %esi
    call puts
    movl tmf, %eax
    call puthex
    movl $nl, %esi
    call puts
halt:
    cli
1:  hlt
    jmp 1b

    .bss
    .balign 16
scsi_dev:   .long 0
io_base:    .long 0
max_target: .long 0
max_lun:    .long 0
q_ring:     .long 0,0,0
q_mask:     .long 0,0,0
q_avail:    .long 0,0,0
q_used:     .long 0,0,0
q_availidx: .long 0,0,0
q_lastused: .long 0,0,0
a1:         .long 0
a2:         .long 0
a3:         .long 0
a4:         .long 0
a5:         .long 0
a6:         .long 0
a7:         .long 0
a8:         .long 0
a9:         .long 0
a10:        .long 0
a11:        .long 0
tmf:        .long 0
bup_fail_seen: .long 0
bup_retries:   .long 0
mc_seen:       .long 0
wp_seen:       .long 0
mc_cap:        .long 0
fail:       .long 0
mbi_ptr:    .long 0
expect:     .space 64

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:       .asciz "SCSI "
okmsg:     .asciz "OK"
failmsg:   .asciz "FAIL"
msg_nodev: .asciz "SCSI nodev\n"
sp_f:      .asciz " f="
sp_qn:     .asciz " qn="
sp_tg:     .asciz " tg="
sp_lun:    .asciz " lun="
sp_a1:     .asciz " a1="
sp_a2:     .asciz " a2="
sp_a3:     .asciz " a3="
sp_a4:     .asciz " a4="
sp_a5:     .asciz " a5="
sp_a6:     .asciz " a6="
sp_a7:     .asciz " a7="
sp_a8:     .asciz " a8="
sp_a9:     .asciz " a9="
sp_a10:    .asciz " a10="
sp_a11:    .asciz " a11="
sp_tm:     .asciz " tmf="
nl:        .asciz "\n"
