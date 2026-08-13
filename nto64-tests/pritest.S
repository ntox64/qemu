/* SPDX-License-Identifier: BSD-2-Clause */

/* pritest.S - freestanding multiboot test for the PRI-like device
 * fault emulation of nto64-dma.
 *
 * Machine: q35 + nto64-dma,queues=1 (2 MSI-X vectors: 0 = queue
 * completion, 1 = fault).
 *
 *   Phase 1 (window fault, polled): a 2 MiB RAM->RAM bulk transfer
 *   from the non-overlapping source 0x300000..0x500000 to the
 *   destination 0x600000..0x800000, with the fault window covering the
 *   second half of the destination (0x700000..0x800000, 1 MiB).
 *   Chunk 0 (1 MiB) lands, chunk 1 faults: status bit3, fault address
 *   0x700000, count 1, and the data before the fault is verifiably
 *   written (partial progress).
 *   The guest "resolves" by disabling the window and writing
 *   fault-control bit2 (resolve/retry); the retry completes the
 *   whole transfer.
 *   Phase 2 (injected fault + MSI-X IRQ): IDT + LAPIC + MSI-X table,
 *   fault vector 1 -> BSP APIC, vector 0x60; fault-control inject
 *   (bit1) + IRQ enable (bit3).  The next transfer faults at its
 *   first byte, the fault IRQ is delivered, then resolve/retry
 *   completes it.
 * Prints to COM1, halts.  Build: `make pritest`,
 * run: `make run-pritest`.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

    .section .text
    .globl _start
_start:
    movl $stack_top, %esp
    andl $-16, %esp
    /* find nto64-dma (1234:1ee9) */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0x1ee91234, %eax
    je found
scan_next:
    incl %edi
    cmpl $32, %edi
    jb scan
    incl devf
    jmp report
found:
    movl %edi, dma_dev
    /* enable memory + bus master, read BAR0/BAR1 */
    movl $4, %ecx
    call cfgread32
    orl $6, %eax
    movl %eax, %ebp
    movl dma_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl dma_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, dma_bar0
    movl dma_dev, %edi
    movl $0x14, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, dma_bar1

    /* --- fill the 2 MiB source buffer with a pattern ---- */
    movl $0x300000, %edi
    movl $0x11223344, %eax
    movl $524288, %ecx
fill_src:
    movl %eax, (%edi)
    addl $4, %edi
    addl $0x01010101, %eax
    decl %ecx
    jnz fill_src

    /* zero the 2 MiB destination (0x600000, non-overlapping with the
     * 2 MiB source at 0x300000: the old 0x400000 dest overlapped the
     * source's upper 1 MiB, so zero_dst corrupted the pattern) */
    movl $0x600000, %edi
    xorl %eax, %eax
    movl $524288, %ecx
zero_dst:
    movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz zero_dst

    /* --- phase 1: window fault, partial progress, resolve ----
     * window = [0x700000, 0x800000) (second half of the 2 MiB dest),
     * 2 MiB transfer from 0x300000 to 0x600000.  Chunk 0 (1 MiB)
     * lands; chunk 1 faults at 0x700000. */
    movl dma_bar0, %esi
    movl $0x700000, 0x88(%esi)
    movl $0, 0x8c(%esi)
    movl $0x100000, 0x90(%esi)
    movl $1, 0x74(%esi)       /* fault control: window enable */

    movl $0x300000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x600000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x200000, 0x18(%esi)
    movl $1, 0x04(%esi)       /* START */
    call wait_fault
    /* status bit3 (fault) latched */
    movl 0x1c(%esi), %eax
    testl $8, %eax
    jnz 1f
    incl p1a
1:  /* fault address == 0x700000, count == 1, pending */
    movl 0x7c(%esi), %eax
    cmpl $0x700000, %eax
    je 2f
    incl p1b
2:  movl 0x84(%esi), %eax
    cmpl $1, %eax
    je 3f
    incl p1c
3:  movl 0x78(%esi), %eax
    testl $1, %eax
    jnz 4f
    incl p1d
4:  /* partial progress: dst[0] and dst[0xfff00] written, the
     * faulting chunk (dst[0x100000]) untouched */
    movl $0x600000, %edi
    cmpl $0x11223344, (%edi)
    je 5f
    incl p1e
5:  movl $0x6fff00, %edi
    movl (%edi), %eax
    movl $0x3fff00, %esi
    cmpl (%esi), %eax
    je 6f
    incl p1f
6:  movl $0x700000, %edi
    cmpl $0, (%edi)
    je 7f
    incl p1g
7:  /* resolve: disable the window + write the resolve bit */
    movl dma_bar0, %esi
    movl $4, 0x74(%esi)
    call wait_done
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jz 8f
    incl p1h
8:  /* full destination (0x600000) now holds the original pattern:
     * verify it against an independently regenerated pattern, not by
     * comparing to a source that the overlap used to corrupt. */
    movl $0x600000, %edi
    movl $0x11223344, %eax
    movl $0x01010101, %ebx
    movl $524288, %ecx
chk_full:
    cmpl %eax, (%edi)
    je 9f
    incl p1i
9:  addl %ebx, %eax
    addl $4, %edi
    decl %ecx
    jnz chk_full
    movl dma_bar0, %esi
    movl 0x20(%esi), %eax
    cmpl $1, %eax
    je 10f
    incl p1j
10:

    /* --- phase 2: injected fault + MSI-X fault IRQ ----
     * IDT (256 gates -> irq_handler: counter++ + LAPIC EOI), LAPIC
     * enabled, MSI-X vector 1 (the fault vector) -> BSP, 0x60. */
    movl $idt_table, %edi
    movl $irq_handler, %eax
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
    lidt idt_ptr
    movl $0xfee00000, %esi
    movl $0x1ff, 0xf0(%esi)   /* LAPIC SPIV: enable, spurious 0xff */

    /* MSI-X: find the capability (id 0x11), program vector 1 */
    movl dma_dev, %edi
    movl $0x34, %ecx
    call cfgread32
    andl $0xff, %eax
    movl %eax, %ebx           /* first cap pointer */
cap_loop:
    testl %ebx, %ebx
    jz 1f
    movl %ebx, %ebp          /* save the cap ptr: cfgread32 clobbers ebx */
    movl %ebx, %ecx
    call cfgread32
    andl $0xff, %eax
    cmpl $0x11, %eax
    je cap_found
    movl %ebp, %ebx          /* reload before the next read */
    movl %ebx, %ecx
    call cfgread32
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, %ebx
    jmp cap_loop
1:  incl p2f
    jmp phase2_done
cap_found:
    movl %ebp, %ebx          /* reload the real cap pointer */
    movl %ebx, cap_off
    /* table base = bar1 + (cap+4 table offset & ~7) */
    leal 4(%ebx), %ecx
    call cfgread32
    andl $0xfffffff8, %eax
    addl dma_bar1, %eax
    movl %eax, %edi
    /* vector 1 (fault) -> APIC 0, vector 0x60, unmasked */
    movl $0xfee00000, 16(%edi)
    movl $0, 20(%edi)
    movl $0x60, 24(%edi)
    movl $0, 28(%edi)
    /* enable MSI-X: message control bit15 (cap+2) = bit31 of the
     * aligned dword at cap (the cap fields are 16-bit inside the
     * aligned 32-bit word) */
    movl cap_off, %ebx
    movl dma_dev, %edi
    leal 2(%ebx), %ecx
    call cfgread32
    orl $0x80000000, %eax
    movl %eax, %ebp
    movl dma_dev, %edi
    movl cap_off, %ebx       /* reload: cfgread32 clobbers ebx */
    leal 2(%ebx), %ecx
    call cfgwrite32

    /* inject a fault on the next transfer + enable the fault IRQ */
    movl dma_bar0, %esi
    movl $0xa, 0x74(%esi)     /* INJECT | IRQEN */
    movl $0x300000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x320000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x1000, 0x18(%esi)
    movl $1, 0x04(%esi)       /* START */

    /* wait for the fault IRQ (handler count >= 1) */
    movl $10000000, %ecx
irq_wait:
    sti
    hlt
    movl handler_count, %eax
    testl %eax, %eax
    jnz 2f
    decl %ecx
    jnz irq_wait
2:  movl handler_count, %eax
    movl %eax, irq_cnt
    /* fault latched: address = transfer start (0x300000), count 2 */
    movl dma_bar0, %esi
    movl 0x7c(%esi), %eax
    cmpl $0x300000, %eax
    je 3f
    incl p2f
3:  movl 0x84(%esi), %eax
    cmpl $2, %eax
    je 4f
    incl p2f
4:  /* resolve + retry: the inject was consumed; clear + resolve */
    movl $4, 0x74(%esi)
    call wait_done
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jz 5f
    incl p2f
5:  /* verify the 4 KiB landed */
    movl $0x320000, %edi
    movl $0x300000, %esi
    movl $1024, %ecx
chk_retry:
    movl (%esi), %eax
    cmpl (%edi), %eax
    je 6f
    incl p2f
6:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz chk_retry
phase2_done:

    /* --- P3: nto64-dma "silent success" fixes ----
     * start-while-busy must latch ST_ERR (status bit 2) instead of
     * being silently dropped (the error survives the in-flight
     * completion), and a truncated ring (valid descriptors run out
     * before ring_count) must report ERR with ring_done = processed,
     * not a clean DONE. */
    movl dma_bar0, %esi
    /* bulk: 4 KiB 0x300000 -> 0x320000, START twice back-to-back.
     * The first transfer is completed from a bottom half, so whether
     * the second START really lands while the engine is busy depends
     * on when that BH runs relative to the two MMIO exits - under load
     * the first transfer can already be done and the second START is
     * then a fresh start, not an error.  Re-arm and retry: a device
     * that latches the start-while-busy error has to latch it in one
     * of the attempts, while a device that silently drops the second
     * START never will. */
    movl $32, p3_tries
1:  movl $0, 0x1c(%esi)        /* clear status */
    movl $0x300000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0x320000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x1000, 0x18(%esi)
    movl $1, 0x04(%esi)        /* START */
    movl $1, 0x04(%esi)        /* START while busy -> ERR latched */
    call wait_done
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jnz 2f
    decl p3_tries
    jnz 1b
    incl p3f
2:  movl $0, 0x1c(%esi)        /* clear status */

    /* truncated ring: ring_count=4, only descriptors 0/1 valid */
    movl $0x340000, %edi
    movl $0x300000, 0(%edi)
    movl $0x320000, 4(%edi)
    movl $0x40, 8(%edi)
    movl $1, 12(%edi)
    movl $0x300100, 16(%edi)
    movl $0x320100, 20(%edi)
    movl $0x40, 24(%edi)
    movl $1, 28(%edi)
    movl $0, 32(%edi)          /* desc2: invalid -> truncation */
    movl $0, 36(%edi)
    movl $0, 40(%edi)
    movl $0, 44(%edi)
    movl $0, 48(%edi)
    movl $0, 52(%edi)
    movl $0, 56(%edi)
    movl $0, 60(%edi)
    movl $0x340000, 0x28(%esi)
    movl $0, 0x2c(%esi)
    movl $4, 0x30(%esi)
    movl $16, 0x34(%esi)
    movl $5, 0x04(%esi)        /* START | RING */
    call wait_done
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jnz 2f
    incl p3f
2:  movl 0x38(%esi), %eax      /* descriptors processed == 2 */
    cmpl $2, %eax
    je 3f
    incl p3f
3:

report:
    movl $msg, %esi
    call puts
    movl p1a, %eax
    addl p1b, %eax
    addl p1c, %eax
    addl p1d, %eax
    addl p1e, %eax
    addl p1f, %eax
    addl p1g, %eax
    addl p1h, %eax
    addl p1i, %eax
    addl p1j, %eax
    addl p2f, %eax
    addl p3f, %eax
    addl devf, %eax
    movl %eax, fail
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
    movl $sp_fa, %esi
    call puts
    movl dma_bar0, %esi
    movl 0x7c(%esi), %eax
    call puthex
    movl $sp_fc, %esi
    call puts
    movl dma_bar0, %esi
    movl 0x84(%esi), %eax
    call puthex
    movl $sp_ir, %esi
    call puts
    movl irq_cnt, %eax
    call puthex
    movl $sp_1, %esi
    call puts
    movl p1a, %eax
    addl p1b, %eax
    addl p1c, %eax
    addl p1d, %eax
    addl p1e, %eax
    addl p1f, %eax
    addl p1g, %eax
    addl p1h, %eax
    addl p1i, %eax
    addl p1j, %eax
    call puthex
    movl $sp_2, %esi
    call puts
    movl p2f, %eax
    call puthex
    movl $sp_3, %esi
    call puts
    movl p3f, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* fault IRQ handler: count + LAPIC EOI + iret */
irq_handler:
    pushl %eax
    incl handler_count
    movl $0xfee00000, %eax
    movl $0, 0xb0(%eax)       /* EOI */
    popl %eax
    iret

/* wait_fault: poll status (esi=bar0) until fault (bit3) or error */
wait_fault:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $12, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
    ret

/* wait_done: poll status (esi=bar0) until done or error */
wait_done:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $6, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
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

    .bss
    .balign 16
dma_dev:   .long 0
dma_bar0:  .long 0
dma_bar1:  .long 0
cap_off:   .long 0
handler_count: .long 0
irq_cnt:   .long 0
p1f:       .long 0
p1a:       .long 0
p1b:       .long 0
p1c:       .long 0
p1d:       .long 0
p1e:       .long 0
p1g:       .long 0
p1h:       .long 0
p1i:       .long 0
p1j:       .long 0
p2f:       .long 0
p3f:       .long 0
p3_tries:  .long 0
devf:      .long 0
fail:      .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .data
    .balign 16
idt_ptr:   .word 0x7ff        /* limit = 256 * 8 - 1 */
           .long idt_table
idt_table: .space 256 * 8, 0

    .section .rodata
msg:     .asciz "PRI "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_fa:   .asciz " fa="
sp_fc:   .asciz " cnt="
sp_ir:   .asciz " irq="
sp_1:    .asciz " p1="
sp_2:    .asciz " p2="
sp_3:    .asciz " p3="
nl:      .asciz "\n"
