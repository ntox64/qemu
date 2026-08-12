/* SPDX-License-Identifier: BSD-2-Clause */

/* slicecount.S - freestanding multiboot test for the whole-RAM slice
 * counters (built-in instrumented RAM).
 *
 * BSP (cpu 0) snapshots the slice read/write counters (nto64-remote
 * ctrl 0x28/0x2c), performs exactly 4096 dword reads and 4096 dword
 * writes to cpu 1's slice (0x04000000 with -m 128 -smp 2), then
 * prints the deltas.  The exact-count gate is DISABLED for
 * performance ( is the fast path; the gate costs ~37% of
 * per-access cost - 27.5 vs 20.1 cycles/access), so the deltas are
 * informational: expect 4096 + a few (first-touch/NOTDIRTY and
 * stale-slot cases double/spuriously count).  The exact assertions
 * below are commented out; re-enable them together with the 7-arg
 * gate in HELPER(mem_instrument) if exact auditing is ever wanted.
 * A busy-wait lets the AP settle into its hlt loop before the
 * snapshot so its (legitimate) foreign counts do not pollute the
 * delta.  Prints to COM1, halts.
 * Build: `make slicecount`, run: `make run-slicecount`.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002          /* multiboot magic */
    .long 0                   /* flags */
    .long -0x1BADB002         /* checksum */

    .section .text
    .globl _start
_start:
    /* let the AP finish its boot noise and reach the hlt loop */
    movl $5000000, %ecx
1:  decl %ecx
    jnz 1b
    movl 0xdf100028, %eax
    movl %eax, rd_before
    movl 0xdf10002c, %eax
    movl %eax, wr_before
    /* exactly 4096 dword reads from cpu 1's slice */
    movl $4096, %ecx
    xorl %ebx, %ebx
1:  movl 0x04000000(%ebx), %eax
    addl $4, %ebx
    decl %ecx
    jnz 1b
    /* exactly 4096 dword writes */
    movl $4096, %ecx
    xorl %ebx, %ebx
2:  movl $0xdeadbeef, 0x04000000(%ebx)
    addl $4, %ebx
    decl %ecx
    jnz 2b
    movl 0xdf100028, %eax
    subl rd_before, %eax
    movl %eax, rd_delta
    movl 0xdf10002c, %eax
    subl wr_before, %eax
    movl %eax, wr_delta
    /* minimum-count checks: with the gate disabled the deltas are
     * 4096 + a few (first-touch/stale-slot overcount), never fewer. */
    cmpl $4096, rd_delta
    jae 3f
    incl fail
3:  cmpl $4096, wr_delta
    jae 4f
    incl fail
4:  /* data result: the 4096 dwords written must read back unchanged */
    movl $4096, %ecx
    xorl %ebx, %ebx
5:  movl 0x04000000(%ebx), %eax
    cmpl $0xdeadbeef, %eax
    je 6f
    incl fail
6:  addl $4, %ebx
    decl %ecx
    jnz 5b
    movl $msg, %esi
    call puts
    movl $sp_rd, %esi
    call puts
    movl rd_delta, %eax
    call puthex
    movl $sp_wr, %esi
    call puts
    movl wr_delta, %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
5:  hlt
    jmp 5b

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
rd_before: .long 0
wr_before: .long 0
rd_delta: .long 0
wr_delta: .long 0
fail: .long 0

    .section .rodata
msg: .asciz "SLICECOUNT"
sp_rd: .asciz " rd="
sp_wr: .asciz " wr="
sp_f: .asciz " f="
nl: .asciz "\n"
