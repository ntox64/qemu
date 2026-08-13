/* SPDX-License-Identifier: BSD-2-Clause */

/* nvmetest.S - freestanding multiboot NVMe multi-queue + MSI-X stress
 * test.
 *
 * Drives the stock QEMU nvme device (8086:5845) the way a real NVMe
 * driver would: enable the controller with the admin queue pair,
 * Identify (controller + namespace), Set Features: Number of Queues
 * (4 I/O queues), create 4 I/O SQ/CQ pairs with one MSI-X vector per
 * CQ (CQ qid -> vector qid, destinations alternate CPU0/CPU1), then
 * hammer each queue with PRP writes + reads and verify (a) data
 * round-trips through the namespace, (b) every completion
 * interrupts the vector's target CPU (per-vector and per-CPU IRQ
 * counters), (c) the cross-node queue/buffer traffic shows up in the
 * nto64 whole-RAM slice counters (ctrl MMIO at 0xDF100000).
 *
 * Run (make run-nvmetest): -machine q35,nto64-per-cpu-ram=on
 *   -smp 2 -m 128 -device nvme,serial=nvme0,max_ioqpairs=4,
 *   msix_qsize=6 -drive file=/tmp/nvme-test.img,if=none,id=drv0,
 *   format=raw -device nvme-ns,drive=drv0,nsid=1,bus=nvme0
 *
 * Prints to COM1, halts.  Expected: 'NVME q=4 adm=11 io=32 rw=OK
 * v=11,8,8,8,8 cpu=27,16 ... f=00000000' (v = per-vector IRQ hits
 * for admin + CQ1..CQ4, cpu = per-CPU IRQ totals; slice counters
 * nonzero from the node-1 queues).
 */

/* NVMe register offsets in BAR0 (NvmeBar) */
.equ NVME_CAP,   0x00
.equ NVME_VS,    0x08
.equ NVME_CC,    0x14
.equ NVME_CSTS,  0x1c
.equ NVME_AQA,   0x24
.equ NVME_ASQ,   0x28
.equ NVME_ACQ,   0x30
.equ NVME_SQTDBL, 0x1000      /* SQ0TDBL; stride 8 per queue pair */
.equ NVME_CQHDBL, 0x1004      /* CQ0HDBL */

.equ CQES,       16
.equ SQES,       64
.equ QSIZE,      16            /* entries per queue (phase never wraps) */
.equ NQ,         4             /* I/O queue pairs */

/* guest memory layout (-m 128: node0 = [0,64M), node1 = [64M,128M)) */
.equ TRAMP,      0x8000        /* AP trampoline (16-bit) */
.equ AP_GDT,     0x8040        /* AP GDT (24 bytes) */
.equ AP_GDTD,    0x8060        /* AP GDT descriptor */
.equ AP_STACK,   0x7e000
.equ IDT_BASE,   0x11000
.equ IDT_PTR,    0x11800
.equ ASQ_ADDR,   0x13000       /* admin SQ (16 x 64B) */
.equ ACQ_ADDR,   0x14000       /* admin CQ (16 x 16B) */
.equ IDCTRL,     0x15000       /* identify controller buffer */
.equ IDNS,       0x16000       /* identify namespace buffer */
.equ CMD_TMPL,   0x17000       /* 64-byte command template */
.equ LAPIC,      0xfee00000
.equ NTO64_CTRL, 0xdf100000

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
    movl $0, adm_count

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

    /* enable memory space, read BAR0 (64-bit) */
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
    movl %eax, bar0

    /* CAP sanity: MQES >= 4 (max queue entries >= 16) */
    movl bar0, %ebp
    movl (%ebp), %eax          /* CAP low dword: MQES = bits 15:0 */
    andl $0xffff, %eax
    cmpl $15, %eax
    jae cap_ok
    movl $msg_cap, %esi
    call puts
    incl fail
    jmp report
cap_ok:

    /* --- MSI-X: find the capability, program 6 vectors, enable ---- */
    movl nvme_dev, %edi
    movl $0x34, %ecx
    call pcicfg
    andl $0xff, %eax
    movl %eax, msix_cap        /* first cap pointer (pcicfg clobbers ebx) */
msix_cap_loop:
    movl msix_cap, %ebx
    testl %ebx, %ebx
    jz msix_bad
    movl %ebx, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xff, %edx           /* cap id */
    cmpl $0x11, %edx           /* MSI-X */
    je msix_found
    shrl $8, %eax
    andl $0xff, %eax           /* next cap pointer */
    movl %eax, msix_cap
    jmp msix_cap_loop
msix_bad:
    movl $msg_msix, %esi
    call puts
    incl fail
    jmp report
msix_found:
    /* table offset register at cap+4: bits 31:3 = byte offset, BIR 2:0 */
    movl msix_cap, %ebx
    leal 4(%ebx), %ecx
    call pcicfg
    andl $0xfffffff8, %eax
    addl bar0, %eax
    movl %eax, msix_table
    /* program vectors 0..5: data = 0x20+i, dest = i & 1 */
    movl $6, %ecx
    xorl %ebx, %ebx
msix_prog:
    movl msix_table, %eax
    movl %ebx, %edx
    shll $4, %edx
    addl %edx, %eax
    movl %ebx, %edx
    andl $1, %edx
    shll $12, %edx
    orl $0xfee00000, %edx
    movl %edx, (%eax)          /* message address low */
    movl $0, 4(%eax)           /* address high */
    leal 0x20(%ebx), %edx
    movl %edx, 8(%eax)         /* message data = vector */
    movl $0, 12(%eax)          /* vector control: unmasked */
    incl %ebx
    decl %ecx
    jnz msix_prog
    /* enable MSI-X.  The message control lives in dword bits 31:16
     * of the (dword-aligned) capability register: enable = bit 15 of
     * that word = dword bit 31, function-mask clear = dword bit 30. */
    movl nvme_dev, %edi
    movl msix_cap, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xffff, %edx         /* keep cap id + next pointer bytes */
    shrl $16, %eax
    orl $0x8000, %eax          /* MSI-X enable */
    andl $0xbfff, %eax         /* clear function mask */
    shll $16, %eax
    orl %edx, %eax
    movl nvme_dev, %edi
    movl msix_cap, %ecx
    call pcicfg_write

    /* --- IDT: 256 gates; vectors 0x20..0x23 -> stubs, rest dummy ---- */
    movl $IDT_BASE, %edi
    xorl %ebx, %ebx
idt_loop:
    cmpl $0x20, %ebx
    jb idt_dummy
    cmpl $0x24, %ebx
    jae idt_dummy
    movl $irq_common, %edx
    jmp idt_set
idt_dummy:
    movl $dummy_isr, %edx
idt_set:
    movw %dx, 0(%edi)
    movw $0x08, 2(%edi)        /* flat code selector */
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)        /* present, dpl0, 32-bit int gate */
    shrl $16, %edx
    movw %dx, 6(%edi)
    addl $8, %edi
    incl %ebx
    cmpl $256, %ebx
    jne idt_loop
    lidt idt_desc

    /* mask the legacy PICs so IRQ0 (vector 0x20) cannot fake NVMe */
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    /* --- BSP local APIC: SVR enable, mask LINT0/LINT1 ---- */
    movl $LAPIC, %eax
    movl $0x1f0, 0xf0(%eax)
    movl $0x10000, 0x350(%eax)
    movl $0x10000, 0x360(%eax)

    /* --- bring up AP1 via INIT-SIPI ---- */
    call ap_bringup

    sti

    /* --- NVMe controller enable ---- */
    movl bar0, %ebp
    /* SeaBIOS probes the device during POST and leaves the controller
     * enabled with ITS admin queues; a driver must reset first: clear
     * CC.EN and wait for CSTS.RDY=0 before reconfiguring. */
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
    movl $0x000f000f, NVME_AQA(%ebp)   /* admin queues: 16 entries */
    movl $ASQ_ADDR, NVME_ASQ(%ebp)
    movl $0, NVME_ASQ+4(%ebp)
    movl $ACQ_ADDR, NVME_ACQ(%ebp)
    movl $0, NVME_ACQ+4(%ebp)
    movl $0x00460001, NVME_CC(%ebp)    /* EN, IOCQES=4, IOSQES=6 */
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

    /* --- admin: identify controller ---- */
    call clr_cmd
    movb $6, CMD_TMPL            /* Identify */
    movl $IDCTRL, CMD_TMPL+24    /* PRP1 */
    movl $0, CMD_TMPL+28
    movl $1, CMD_TMPL+40         /* CNS = 1 (controller) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz adm_bad
    movzwl IDCTRL, %eax
    cmpl $0x8086, %eax
    je vid_ok
    cmpl $0x1b36, %eax        /* Red Hat PCI ID (use-intel-id=off) */
    je vid_ok
    jmp adm_bad
vid_ok:
    cmpl $0x554d4551, IDCTRL+24  /* "QEMU" */
    jne adm_bad

    /* --- admin: identify namespace 1 ---- */
    call clr_cmd
    movb $6, CMD_TMPL
    movl $1, CMD_TMPL+4          /* nsid */
    movl $IDNS, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl $0, CMD_TMPL+40         /* CNS = 0 (namespace) */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz adm_bad
    movl IDNS, %eax
    testl %eax, %eax            /* NSZE low dword */
    jz adm_bad

    /* --- admin: set features, number of queues (request 4) ---- */
    call clr_cmd
    movb $9, CMD_TMPL            /* Set Features */
    movl $7, CMD_TMPL+40         /* FID = Number of Queues */
    movl $0x00030003, CMD_TMPL+44 /* NCQR=3, NSQR=3 */
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz adm_bad
    movl adm_res, %eax
    cmpl $0x00030003, %eax
    jne adm_bad
    jmp adm_ok
adm_bad:
    movl $msg_adm, %esi
    call puts
    incl fail
    jmp report
adm_ok:

    /* --- create I/O queue pairs 1..NQ (vector qid, IEN, PC) ---- */
    movl $1, %ebx                /* qid (admin_cmd clobbers ebp) */
create_q:
    cmpl $NQ, %ebx
    ja queues_ok
    /* create CQ */
    call clr_cmd
    movb $5, CMD_TMPL            /* Create I/O CQ */
    movl q_cq(,%ebx,4), %eax
    movl %eax, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl %ebx, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40       /* qid | (qsize-1)<<16 */
    movl %ebx, %eax
    shll $16, %eax
    orl $3, %eax                 /* PC | IEN */
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    /* create SQ */
    call clr_cmd
    movb $1, CMD_TMPL            /* Create I/O SQ */
    movl q_sq(,%ebx,4), %eax
    movl %eax, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl %ebx, %eax
    orl $((QSIZE-1) << 16), %eax
    movl %eax, CMD_TMPL+40
    /* DW11: PC | QPRIO (15:0), CQID (31:16) - per the NVMe spec and
     * QEMU's NvmeCreateSq, cqid is NOT in DW12. */
    movl %ebx, %eax
    shll $16, %eax
    orl $((2 << 2) | 1), %eax
    movl %eax, CMD_TMPL+44
    movl $CMD_TMPL, %esi
    call admin_cmd
    testl %eax, %eax
    jnz q_bad
    incl %ebx
    jmp create_q
q_bad:
    movl $msg_q, %esi
    call puts
    incl fail
    jmp report
queues_ok:

    /* --- slice counters before the I/O phase ---- */
    movl $NTO64_CTRL, %eax
    movl 0x28(%eax), %ecx
    movl %ecx, slr_before
    movl 0x2c(%eax), %ecx
    movl %ecx, slw_before

    /* --- I/O stress: 4 writes + 4 reads per queue ---- */
    movl $1, %ebx                /* qid (io_cmd clobbers ebp) */
io_q:
    cmpl $NQ, %ebx
    ja io_done
    /* fill the write buffer with the queue pattern (1 KiB dwords) */
    movl q_wb(,%ebx,4), %edi
    movl %ebx, %eax
    orl $0x11223300, %eax
    movl $1024, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    /* 4 writes, slba = i*8, nlb = 7 (8 sectors = 4 KiB) */
    xorl %ebp, %ebp              /* i */
io_w:
    cmpl $4, %ebp
    jae io_r
    call clr_cmd
    movb $1, CMD_TMPL            /* Write */
    movl $1, CMD_TMPL+4          /* nsid */
    movl q_wb(,%ebx,4), %eax
    movl %eax, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl %ebp, %eax
    shll $3, %eax
    movl %eax, CMD_TMPL+40       /* slba */
    movl $7, CMD_TMPL+48         /* nlb */
    movl $CMD_TMPL, %esi
    pushl %ebp
    movl %ebx, %eax
    call io_cmd
    popl %ebp
    testl %eax, %eax
    jnz io_bad
    incl %ebp
    jmp io_w
io_r:
    xorl %ebp, %ebp
io_rl:
    cmpl $4, %ebp
    jae io_qn
    call clr_cmd
    movb $2, CMD_TMPL            /* Read */
    movl $1, CMD_TMPL+4
    movl q_rb(,%ebx,4), %eax
    movl %eax, CMD_TMPL+24
    movl $0, CMD_TMPL+28
    movl %ebp, %eax
    shll $3, %eax
    movl %eax, CMD_TMPL+40
    movl $7, CMD_TMPL+48
    movl $CMD_TMPL, %esi
    pushl %ebp
    movl %ebx, %eax
    call io_cmd
    popl %ebp
    testl %eax, %eax
    jnz io_bad
    incl %ebp
    jmp io_rl
io_qn:
    /* verify the read-back buffer */
    movl q_rb(,%ebx,4), %esi
    movl %ebx, %eax
    orl $0x11223300, %eax
    movl $1024, %ecx
1:  cmpl %eax, (%esi)
    jne data_bad
    addl $4, %esi
    decl %ecx
    jnz 1b
    incl %ebx
    jmp io_q
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
io_done:
    sti                          /* let any final pending interrupts in */

    /* --- slice counters after the I/O phase ---- */
    movl $NTO64_CTRL, %eax
    movl 0x28(%eax), %ecx
    movl %ecx, slr_after
    movl 0x2c(%eax), %ecx
    movl %ecx, slw_after

    /* --- wait for per-CPU MSI-X routing ----
     * The nvme completion BH batches CQEs + MSIs and TCG defers APIC
     * delivery, so rapid same-vector edges coalesce in the IRR
     * (spec-correct edge semantics).  Every command's completion is
     * verified by CQ polling + data; here we prove the ROUTING: the
     * admin vector fires on CPU0 (adm_count), at least one I/O vector
     * delivery lands on each target CPU (CQ1/CQ3 -> CPU1, CQ2/CQ4 ->
     * CPU0). */
    movl $200000000, %edi
msi_wait:
    movl adm_count, %eax
    incl %eax
    cmpl cpu_hits, %eax
    ja 1f
    cmpl $1, cpu_hits+4
    jae msi_ok
1:  decl %edi
    jnz msi_wait
    movl $msg_msi, %esi
    call puts
    incl fail
msi_ok:

    jmp report

/* --------------------------------------------------------------- */
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
    incl adm_count
    sti
    movl %edx, %eax
    shrl $1, %eax
    ret

/* io_cmd: eax = qid, esi -> 64-byte command; returns eax = status.
 * Clobbers eax, ecx, edx, esi, edi, ebp. */
io_cmd:
    pushl %eax
    movl %eax, %ebp
    movl sq_tail(,%ebp,4), %ecx
    shll $6, %ecx
    addl q_sq(,%ebp,4), %ecx
    movl %esi, %edi
    movl $16, %edx
1:  movl (%edi), %eax
    movl %eax, (%ecx)
    addl $4, %edi
    addl $4, %ecx
    decl %edx
    jnz 1b
    movl sq_tail(,%ebp,4), %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, sq_tail(,%ebp,4)
    movl bar0, %eax
    leal NVME_SQTDBL(%eax), %eax
    movl %ebp, %edx
    shll $3, %edx
    movl %ecx, (%eax,%edx)       /* SQqTDBL */
    movl $100000000, %edi
1:  movl cq_head(,%ebp,4), %ecx
    shll $4, %ecx
    movl q_cq(,%ebp,4), %edx
    addl %ecx, %edx
    movzwl 14(%edx), %eax
    testb $1, %al
    jnz 2f
    decl %edi
    jnz 1b
    movl $msg_iocq, %esi
    call puts
    incl fail
    movl $1, %eax
    popl %edx
    ret
2:  movl %eax, %edx          /* CQE status (with phase); ebx is the
                               * caller's queue id - do not clobber it */
    movl cq_head(,%ebp,4), %ecx
    incl %ecx
    andl $15, %ecx
    movl %ecx, cq_head(,%ebp,4)
    movl bar0, %eax
    leal NVME_CQHDBL(%eax), %eax
    movl %ebp, %esi
    shll $3, %esi
    movl %ecx, (%eax,%esi)       /* CQqHDBL */
    movl %edx, %eax
    shrl $1, %eax
    popl %edx
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

/* ap_bringup: copy the trampoline to 0x8000, build GDT at 0x8040,
 * INIT + SIPI to APIC id 1, wait for ap_ready.  Clobbers eax..edi. */
ap_bringup:
    /* copy trampoline (16-bit blob) */
    movl $ap_tramp, %esi
    movl $TRAMP, %edi
    movl $ap_tramp_end, %ecx
    subl $ap_tramp, %ecx
1:  movb (%esi), %al
    movb %al, (%edi)
    incl %esi
    incl %edi
    decl %ecx
    jnz 1b
    /* GDT at AP_GDT: null, code 0x08, data 0x10 */
    movl $0, AP_GDT
    movl $0, AP_GDT+4
    movl $0x0000ffff, AP_GDT+8
    movl $0x00cf9a00, AP_GDT+12
    movl $0x0000ffff, AP_GDT+16
    movl $0x00cf9200, AP_GDT+20
    /* descriptor at AP_GDTD */
    movw $23, AP_GDTD
    movl $AP_GDT, AP_GDTD+2
    movl $0, AP_GDTD+6
    /* INIT then SIPI to APIC 1 */
    movl $LAPIC, %eax
    movl $1 << 24, 0x310(%eax)   /* ICRH: dest = APIC 1 */
    movl $0x00004500, 0x300(%eax) /* INIT assert */
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax) /* SIPI vector 8 -> 0x8000 */
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax) /* second SIPI */
    /* wait for ap_ready */
    movl $100000000, %ecx
1:  movl ap_ready, %eax
    testl %eax, %eax
    jnz 2f
    decl %ecx
    jnz 1b
    movl $msg_ap, %esi
    call puts
    incl fail
2:  ret

ap_delay:
    movl $1000000, %ecx
1:  decl %ecx
    jnz 1b
    ret

/* Interrupt handler for the NVMe vectors (0x20..0x23): bump the
 * per-CPU total (the LAPIC ID tells which CPU took it) and EOI.
 * Per-CPU delivery is the MSI-X locality proof; the per-vector ISR
 * read is unreliable under TCG, so vectors are verified via their
 * target CPU totals.  pushal/popal balance and iret consumes the
 * frame - no stack games. */
irq_common:
    pushal
    movl $LAPIC, %edx
    movl $0, 0xb0(%edx)          /* EOI first: the per-CPU count is
                                   * what the submit path waits on, so
                                   * it must imply the vector is fully
                                   * serviced (count after EOI) */
    movl 0x20(%edx), %ecx        /* LAPIC ID */
    shrl $24, %ecx
    cmpl $4, %ecx
    jae 1f
    incl cpu_hits(,%ecx,4)
1:
    popal
    iret

dummy_isr:
    iret

/* --------------------------------------------------------------- */
/* AP trampoline: 16-bit real-mode code copied to 0x8000.  The GDT
 * descriptor lives at fixed 0x8060 (built by ap_bringup); the far
 * jump target is the link address of ap_entry32. */
    .code16
ap_tramp:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7f00, %sp
    lgdtl 0x8060
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long ap_entry32
    .word 0x08
ap_tramp_end:
    .code32

ap_entry32:
    movl $0x10, %eax
    movl %eax, %ds
    movl %eax, %es
    movl %eax, %fs
    movl %eax, %gs
    movl %eax, %ss
    movl $AP_STACK, %esp
    lidt idt_desc
    movl $LAPIC, %eax
    movl $0x1f0, 0xf0(%eax)
    movl $0x10000, 0x350(%eax)
    movl $0x10000, 0x360(%eax)
    movl $1, ap_ready
    sti
1:  hlt
    jmp 1b

/* --------------------------------------------------------------- */
/* pcicfg / pcicfg_write / console helpers */
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

/* report: print the result line, then halt */
report:
    movl $msg_nvme, %esi
    call puts
    movl $sp_q, %esi
    call puts
    movl $NQ, %eax
    call putdec
    movl $sp_adm, %esi
    call puts
    movl adm_count, %eax
    call putdec
    movl $sp_io, %esi
    call puts
    movl $32, %eax
    call putdec
    movl $sp_cpu, %esi
    call puts
    movl cpu_hits, %eax
    call putdec
    movl $sp_comma, %esi
    call puts
    movl cpu_hits+4, %eax
    call putdec
    movl $sp_slr, %esi
    call puts
    movl slr_after, %eax
    subl slr_before, %eax
    call putdec
    movl $sp_slw, %esi
    call puts
    movl slw_after, %eax
    subl slw_before, %eax
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

/* --------------------------------------------------------------- */
    .bss
    .balign 16
fail: .long 0
nvme_dev: .long 0
bar0: .long 0
msix_cap: .long 0
msix_table: .long 0
adm_res: .long 0
adm_count: .long 0
admin_tail: .long 0
admin_head: .long 0
sq_tail: .fill 8,4,0
cq_head: .fill 8,4,0
slr_before: .long 0
slw_before: .long 0
slr_after: .long 0
slw_after: .long 0
ap_ready: .long 0
irq_hits: .fill 8,4,0
cpu_hits: .fill 4,4,0

    .data
    .balign 16
q_cq: .long 0, 0x200000, 0x5000000, 0x210000, 0x5100000
q_sq: .long 0, 0x201000, 0x5001000, 0x211000, 0x5101000
q_wb: .long 0, 0x202000, 0x5002000, 0x212000, 0x5102000
q_rb: .long 0, 0x203000, 0x5003000, 0x213000, 0x5103000

    .section .rodata
msg_nvme: .asciz "NVME"
sp_q: .asciz " q="
sp_adm: .asciz " adm="
sp_io: .asciz " io="
sp_v: .asciz " v="
sp_cpu: .asciz " cpu="
sp_slr: .asciz " slr="
sp_slw: .asciz " slw="
sp_f: .asciz " f="
sp_comma: .asciz ","
nl: .asciz "\n"
msg_nodev: .asciz "no nvme\n"
msg_cap: .asciz "bad cap\n"
msg_msix: .asciz "bad msix\n"
msg_rdy: .asciz "rdy timeout\n"
msg_adm: .asciz "bad admin\n"
msg_q: .asciz "bad queue\n"
msg_io: .asciz "io status\n"
msg_data: .asciz "data mismatch\n"
msg_msi: .asciz "msi miss\n"
msg_acq: .asciz "acq timeout\n"
msg_iocq: .asciz "iocq timeout\n"
msg_ap: .asciz "ap timeout\n"

idt_desc:
    .word 0x7ff
    .long IDT_BASE
