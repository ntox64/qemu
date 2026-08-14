/* SPDX-License-Identifier: BSD-2-Clause */

/* ahciintr.S - freestanding multiboot SATA/AHCI completion /
 * interrupt-loss test.
 *
 * A minimal ICH9-AHCI driver that runs the HBA with the port interrupt
 * + global interrupt enable + MSI enabled (IDT + BSP LAPIC, vector 0x20
 * -> isr_common) and proves the polling-fallback recovery when a
 * completion interrupt is lost:
 *
 *   a1 - one Write completes via the ISR (irq_seen, no poll fallback);
 *   a2 - the armed MSI is LOST (-global ich9-ahci.nto64-msi-drop=2):
 *        the port still completes (PxCI clears) but no MSI fires, the
 *        driver's bounded ISR wait times out, it falls back to polling
 *        PxCI and recovers (a2=2, poll=1);
 *   a3 - delivery RESUMES on the next command (a3=1).
 *
 * Device hook: hw/ide/ich.c pci_ich9_ahci_update_irq -> `nto64-msi-drop=N`
 * drops the Nth deliverable MSI raise (the command still completes).
 *
 * Run:
 *   make run-ahciintr           (clean, a1=a2=1 a3=1)
 *   make run-ahciintrdrop       (-global ich9-ahci.nto64-msi-drop=2, a2=2)
 *
 * Prints to COM1, halts.  Expected: 'AINTR a1=1 a2=<1|2> a3=1 p=<0|1>
 * f=00000000'.
 */

/* AHCI HBA registers (ABAR) */
.equ AHCI_GHC,  0x04
.equ P0,        0x100
.equ P_CLB,     0x00
.equ P_FB,      0x08
.equ P_IS,      0x10
.equ P_IE,      0x14
.equ P_CMD,     0x18
.equ P_TFD,     0x20
.equ P_SSTS,    0x28
.equ P_CI,      0x38

/* guest memory layout (-m 64, flat RAM) */
.equ IDT_BASE,  0x11000
.equ LAPIC,     0xfee00000
.equ CLB,       0x21000       /* command list (32 x 32B) */
.equ CTAB,      0x22000       /* command table (128B header + PRDT) */
.equ FB,        0x23000       /* FIS receive area (256B) */
.equ IDBUF,     0x24000       /* IDENTIFY buffer (512B) */
.equ DBUF,      0x25000       /* 4 KiB DMA data buffer */

.equ ATA_IDENTIFY, 0xec
.equ ATA_WR_DMA,   0x35
.equ IRQ_TIMEOUT,  300000000
.equ CI_TIMEOUT,   100000000

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
    movl $0, a1
    movl $0, a2
    movl $0, a3
    movl $0, irq_total
    movl $0, poll_total

    /* mask the legacy PICs (IRQ0 cannot fake the AHCI MSI) */
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    /* --- find the AHCI controller (class 0x010601).  %edi holds the
     * bdf = (dev<<3)|func; pcicfg below splits it correctly, so this
     * reaches the ICH9 AHCI at dev 31 func 2 (the original nto64
     * pcicfg's <<11 only ever reached function 0). ---- */
    xorl %edi, %edi              /* bdf 0..0xFF (dev 0..31 x func 0..7) */
scan:
    movl %edi, ahci_dev          /* stash bdf (pcicfg clobbers ebx) */
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
    movl ahci_dev, %edi
    incl %edi
    cmpl $256, %edi
    jne scan
    movl $msg_nodev, %esi
    call puts
    incl fail
    jmp report

ahci_found:
    movl %edi, ahci_dev
    movl $msg_found, %esi
    call puts
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
    /* debug: print bar0 */
    movl $msg_bar0, %esi
    call puts
    movl bar0, %eax
    call puthex
    call putnl

    /* --- HBA reset, then port 0 enable (like ahcitest.S) ---- */
    movl bar0, %ebp
    movl $1, %eax
    movl %eax, AHCI_GHC(%ebp)      /* GHC.HR */
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
    movl %eax, AHCI_GHC(%ebp)      /* GHC.AE */
    /* port 0: command list + FIS area, then FRE */
    movl bar0, %ebp
    movl $CLB, %eax
    movl %eax, P0+P_CLB(%ebp)
    movl $0, P0+P_CLB+4(%ebp)
    movl $FB, %eax
    movl %eax, P0+P_FB(%ebp)
    movl $0, P0+P_FB+4(%ebp)
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)
    movl $0x16, %eax
    movl %eax, P0+P_CMD(%ebp)      /* SUD | POD | FRE */
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
    movl P0+P_CMD(%ebp), %eax
    orl $1, %eax
    movl %eax, P0+P_CMD(%ebp)      /* PxCMD |= ST */
    /* debug: read PxCMD back */
    movl P0+P_CMD(%ebp), %eax
    movl %eax, dbg
    movl $msg_cmd, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl P0+P_CLB(%ebp), %eax
    movl %eax, dbg
    movl $msg_clb, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl

    /* --- IDENTIFY (polling; interrupts still masked) ---- */
    movl $ATA_IDENTIFY, s_cmd
    movl $0, s_write
    movl $1, s_prdtl
    movl $0, s_lba
    movl $0, s_count
    movl $IDBUF, s_buf
    call sata_cmd_poll
    testl %eax, %eax
    jnz init_bad

    /* --- find the MSI cap (id 5) via the cap pointer list ---- */
    movl ahci_dev, %edi
    movl $0x34, %ecx
    call pcicfg
    andl $0xfc, %eax
    movl %eax, msi_cap
msi_cap_loop:
    movl msi_cap, %ebx
    testl %ebx, %ebx
    jz msi_bad
    movl %ebx, %ecx
    call pcicfg
    movl %eax, %edx
    andl $0xff, %edx
    cmpl $0x05, %edx             /* PCI_CAP_ID_MSI */
    je msi_found
    shrl $8, %eax
    andl $0xfc, %eax
    movl %eax, msi_cap
    jmp msi_cap_loop
msi_bad:
    movl $msg_msi, %esi
    call puts
    incl fail
    jmp report
msi_found:
    /* 64-bit MSI at msi_cap (0x80): addr low +4, addr high +8, data
     * +0x0c.  NOTE: %ebx was clobbered by the pcicfg call above (it
     * now holds the bdf 0xfa, not the cap offset) - always reload
     * msi_cap from memory and never compute offsets from %ebx here.
     * (A 4+0xfa=0xfe / 8+0xfa=0x102 / 0xc+0xfa=0x106 offset set
     * wraps to config offsets 0xfc/0x00/0x04, and the 0x04 write
     * lands on PCI_COMMAND, clearing the memory-space enable bit and
     * unmapping the AHCI BAR - the 2026-08-22 interrupt-loss
     * mystery.) */
    movl $0xfee00000, %eax
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    addl $4, %ecx
    call pcicfg_write
    movl $0, %eax
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    addl $8, %ecx
    call pcicfg_write
    movl $0x20, %eax
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    addl $0x0c, %ecx
    call pcicfg_write
    /* enable MSI: the enable bit is bit 0 of the message control
     * WORD at cap+2, i.e. bit 16 of the dword read at cap+0 (a plain
     * `orl $1` on the dword ORs the cap-ID byte - a no-op). */
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    call pcicfg
    orl $0x10000, %eax
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    call pcicfg_write

    /* --- IDT: vector 0x20 -> isr_common, rest dummy ---- */
    movl $IDT_BASE, %edi
    xorl %ebx, %ebx
idt_loop:
    cmpl $0x20, %ebx
    je idt_irq
    movl $dummy_isr, %edx
    jmp idt_set
idt_irq:
    movl $isr_common, %edx
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

    /* BSP local APIC: SVR enable, mask LINT0/LINT1, then IF */
    movl $LAPIC, %eax
    movl $0x1f0, 0xf0(%eax)
    movl $0x10000, 0x350(%eax)
    movl $0x10000, 0x360(%eax)

    /* clear any stale port status (the IDENTIFY D2H is still latched
     * in PxIS) BEFORE arming interrupts - otherwise the pending DHRS
     * raises immediately when PxIE is written and consumes one
     * nto64-msi-drop slot (the drop counts every deliverable raise,
     * and the IDENTIFY's DHRS would be raise #1, shifting a2's drop
     * onto a1). */
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)

    /* interrupts: GHC.GIE + all port interrupt enables */
    movl bar0, %ebp
    movl %ebp, dbg
    movl $msg_bar0b, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    /* GHC |= GIE (read-modify-write) */
    movl AHCI_GHC(%ebp), %eax
    orl $2, %eax
    movl %eax, AHCI_GHC(%ebp)
    /* PxIE = all interrupt enables */
    movl P0+P_IE(%ebp), %eax
    orl $0xffffffff, %eax
    movl %eax, P0+P_IE(%ebp)
    /* debug: read back GHC, PxIE, MSI ctl */
    movl AHCI_GHC(%ebp), %eax
    movl %eax, dbg
    movl $msg_ghc, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl P0+P_IE(%ebp), %eax
    movl %eax, dbg
    movl $msg_pie, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl ahci_dev, %edi
    movl msi_cap, %ecx
    call pcicfg
    movl %eax, dbg
    movl $msg_msictl, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl msi_cap, %eax
    movl %eax, dbg
    movl $msg_capoff, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    sti

    /* --- fill the DMA buffer ---- */
    movl $DBUF, %edi
    movl $0x55667788, %eax
    movl $1024, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    incl %eax
    decl %ecx
    jnz 1b

    /* --- phase a1: Write, interrupt-driven ---- */
    movl $ATA_WR_DMA, s_cmd
    movl $1, s_prdtl
    movl $0x100, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    call sata_cmd_irq
    movl %eax, s_stat            /* save command status */
    /* debug: PxIS after a1 */
    movl bar0, %ebp
    movl P0+P_IS(%ebp), %eax
    movl %eax, dbg
    movl $msg_pxis, %esi
    call puts
    movl dbg, %eax
    call puthex
    call putnl
    movl s_stat, %eax
    testl %eax, %eax
    jnz io_fail
    cmpl $1, poll_last
    je io_fail
    movl $1, a1

    /* --- phase a2: Write whose MSI is LOST ---- */
    movl $ATA_WR_DMA, s_cmd
    movl $1, s_prdtl
    movl $0x200, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    call sata_cmd_irq
    testl %eax, %eax
    jnz io_fail
    cmpl $1, poll_last
    je a2_drop
    movl $1, a2
    jmp a2_done
a2_drop:
    movl $2, a2
a2_done:

    /* --- phase a3: Write, delivery resumed ---- */
    movl $ATA_WR_DMA, s_cmd
    movl $1, s_prdtl
    movl $0x300, s_lba
    movl $8, s_count
    movl $DBUF, s_buf
    movl $1, s_write
    call sata_cmd_irq
    testl %eax, %eax
    jnz io_fail
    cmpl $1, poll_last
    je io_fail
    movl $1, a3

    jmp report

io_fail:
    movl $msg_io, %esi
    call puts
    incl fail
    jmp report

init_bad:
    movl $msg_init, %esi
    call puts
    incl fail
    jmp report

/* sata_cmd_poll: ahcitest-style polling command (no interrupt wait).
 * Returns 0 clean, 2 on CI timeout, 3 on TFES error. */
sata_cmd_poll:
    movl $CTAB, %edi
    movb $0x27, 0(%edi)
    movb $0x80, 1(%edi)
    movb s_cmd, %al
    movb %al, 2(%edi)
    movb $0, 3(%edi)
    movl s_lba, %eax
    movb %al, 4(%edi)
    movb %ah, 5(%edi)
    shrl $16, %eax
    movb %al, 6(%edi)
    movb $0x40, 7(%edi)
    movb $0, 8(%edi)
    movb $0, 9(%edi)
    movb $0, 10(%edi)
    movl s_count, %eax
    movb %al, 12(%edi)
    movb %ah, 13(%edi)
    movb $0, 14(%edi)
    movb $0, 15(%edi)
    movl s_buf, %eax
    movl %eax, 0x80(%edi)
    movl $0, 0x84(%edi)
    movl $0, 0x88(%edi)
    movl $0x80000fff, 0x8c(%edi)
    movl $CLB, %edi
    movl s_prdtl, %eax
    shll $16, %eax
    movl s_write, %edx
    shll $6, %edx
    orl %edx, %eax
    movl %eax, 0(%edi)
    movl $0, 4(%edi)
    movl $CTAB, 8(%edi)
    movl $0, 12(%edi)
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)
    movl $1, %eax
    movl %eax, P0+P_CI(%ebp)
    movl $CI_TIMEOUT, %edi
1:  movl P0+P_CI(%ebp), %eax
    testl $1, %eax
    jz 2f
    movl P0+P_IS(%ebp), %eax
    testl $0x40000000, %eax
    jnz 3f
    decl %edi
    jnz 1b
    movl $2, %eax
    ret
2:  movl P0+P_TFD(%ebp), %eax
    testl $1, %eax
    jnz 3f
    xorl %eax, %eax
    ret
3:  movl $3, %eax
    ret

/* sata_cmd_irq: issue one command on port 0, wait for the completion
 * interrupt (irq_seen), and - on timeout - fall back to polling PxCI.
 * Returns eax = 0 on clean completion (CI clear, no TFES), 3 on error.
 * Sets poll_last (1 if the ISR wait timed out). */
sata_cmd_irq:
    /* build the H2D FIS + PRDT + command header (as ahcitest.S) */
    movl $CTAB, %edi
    movb $0x27, 0(%edi)
    movb $0x80, 1(%edi)
    movb s_cmd, %al
    movb %al, 2(%edi)
    movb $0, 3(%edi)
    movl s_lba, %eax
    movb %al, 4(%edi)
    movb %ah, 5(%edi)
    shrl $16, %eax
    movb %al, 6(%edi)
    movb $0x40, 7(%edi)
    movb $0, 8(%edi)
    movb $0, 9(%edi)
    movb $0, 10(%edi)
    movl s_count, %eax
    movb %al, 12(%edi)
    movb %ah, 13(%edi)
    movb $0, 14(%edi)
    movb $0, 15(%edi)
    movl s_buf, %eax
    movl %eax, 0x80(%edi)
    movl $0, 0x84(%edi)
    movl $0, 0x88(%edi)
    movl $0x80000fff, 0x8c(%edi)
    movl $CLB, %edi
    movl s_prdtl, %eax
    shll $16, %eax
    movl s_write, %edx
    shll $6, %edx
    orl %edx, %eax
    movl %eax, 0(%edi)
    movl $0, 4(%edi)
    movl $CTAB, 8(%edi)
    movl $0, 12(%edi)
    /* issue: clear stale PxIS, reset irq_seen, PxCI = 1 */
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)
    movl $0, irq_seen
    movl $1, %eax
    movl %eax, P0+P_CI(%ebp)
    /* bounded wait for the ISR */
    movl $IRQ_TIMEOUT, %edi
1:  cmpl $1, irq_seen
    je 2f
    decl %edi
    jnz 1b
    movl $1, poll_last
    incl poll_total
    jmp 3f
2:  movl $0, poll_last
3:  /* bounded poll PxCI for completion (CI clear) or TFES */
    movl $CI_TIMEOUT, %edi
4:  movl P0+P_CI(%ebp), %eax
    testl $1, %eax
    jz 5f
    movl P0+P_IS(%ebp), %eax
    testl $0x40000000, %eax       /* TFES */
    jnz 6f
    decl %edi
    jnz 4b
    movl $msg_ci, %esi
    call puts
    movl $3, %eax
    ret
5:  movl P0+P_TFD(%ebp), %eax
    testl $1, %eax
    jnz 6f
    /* debug: what PxIS did the completion set? */
    movl P0+P_IS(%ebp), %edx
    movl $msg_pxisd, %esi
    call puts
    movl %edx, %eax
    call puthex
    call putnl
    movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)      /* clear complete */
    incl irq_total
    xorl %eax, %eax
    ret
6:  movl bar0, %ebp
    movl $0xffffffff, %eax
    movl %eax, P0+P_IS(%ebp)
    /* debug: print TFD (error<<8 | status) */
    movl P0+P_TFD(%ebp), %edx
    movl $msg_tfd, %esi
    call puts
    movl %edx, %eax
    call puthex
    call putnl
    movl $3, %eax                 /* error */
    ret

/* -------- low-level helpers (copied from ahcitest.S) --------- */
pcicfg:
    /* %edi = bdf (dev<<3 | func); build a correct config address */
    movl %edi, %ebx
    movl %ebx, %eax
    shrl $3, %eax
    andl $0x1f, %eax
    shll $11, %eax
    movl %ebx, %edx
    andl $7, %edx
    shll $8, %edx
    orl %edx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    inl %edx, %eax
    ret

pcicfg_write:
    movl %eax, %esi
    movl %edi, %ebx
    movl %ebx, %eax
    shrl $3, %eax
    andl $0x1f, %eax
    shll $11, %eax
    movl %ebx, %edx
    andl $7, %edx
    shll $8, %edx
    orl %edx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
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

putnl:
    movl $' ', %eax
    call putc
    ret

isr_common:
    pushal
    movl $1, irq_seen
    movl $LAPIC, %eax
    movl $0, 0xb0(%eax)          /* EOI */
    popal
    iret

dummy_isr:
    iret

/* nto64_expect + hex helper come from the shared include. */
.include "nto64-expect.inc"

/* verify_expect: the A2 phase must match the run config.  Bit 0 of the
 * expected mask means "the armed MSI must be lost" (a2=2); otherwise the
 * run is clean (a2=1).  A mismatch increments fail, so a dead drop hook
 * is a real failure rather than a silent a2=1 pass. */
verify_expect:
    call nto64_expect
    movl %eax, %ebx
    testl $1, %ebx
    jnz .Lve_drop
    cmpl $1, a2
    je .Lve_done
    incl fail
    jmp .Lve_done
.Lve_drop:
    cmpl $2, a2
    je .Lve_done
    incl fail
.Lve_done:
    ret

report:
    call verify_expect
    movl $msg_aintr, %esi
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
mbi_ptr:    .long 0
fail:       .long 0
ahci_dev:   .long 0
bar0:       .long 0
msi_cap:    .long 0
a1:         .long 0
a2:         .long 0
a3:         .long 0
irq_seen:   .long 0
poll_last:  .long 0
irq_total:  .long 0
poll_total: .long 0
s_cmd:      .long 0
s_lba:      .long 0
s_count:    .long 0
s_buf:      .long 0
s_prdtl:    .long 0
s_write:    .long 0
s_tmp:      .long 0
s_stat:     .long 0
dbg:        .long 0

    .data
idt_desc:
    .word 256*8 - 1
    .long IDT_BASE

msg_nodev: .asciz "AHCI: no device\n"
msg_found: .asciz "AHCI: found\n"
msg_dbg:   .asciz " "
msg_msi:   .asciz "AHCI: no MSI\n"
msg_hr:    .asciz "AHCI: hba reset\n"
msg_det:   .asciz "AHCI: no det\n"
msg_io:    .asciz "AHCI: io\n"
msg_ci:    .asciz "AHCI: ci\n"
msg_init:  .asciz "AHCI: identify\n"
msg_tfd:   .asciz "AHCI: tfd="
msg_pxis:  .asciz "AHCI: pxis="
msg_pxisd: .asciz "AHCI: pxisd="
msg_cmd:   .asciz "AHCI: cmd="
msg_bar0:  .asciz "AHCI: bar0="
msg_clb:   .asciz "AHCI: clb="
msg_ghc:   .asciz "AHCI: ghc="
msg_pie:   .asciz "AHCI: pie="
msg_msictl: .asciz "AHCI: msictl="
msg_capoff: .asciz "AHCI: msi_cap="
msg_bar0b: .asciz "AHCI: bar0b="
msg_aintr: .asciz "AINTR"
sp_a1:     .asciz " a1="
sp_a2:     .asciz " a2="
sp_a3:     .asciz " a3="
sp_p:      .asciz " p="
sp_f:      .asciz " f="
nl:        .asciz "\n"
