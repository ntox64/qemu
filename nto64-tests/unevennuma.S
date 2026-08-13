/* SPDX-License-Identifier: BSD-2-Clause */

/* unevennuma.S - freestanding multiboot test for the instrumented node
 * ranges following the SRAT when an explicit -numa topology sizes the
 * nodes differently.
 *
 *   -machine q35,nto64-per-cpu-ram=on -smp 2 -m 128 \
 *   -object memory-backend-ram,size=32M,id=n0 \
 *   -object memory-backend-ram,size=96M,id=n1 \
 *   -numa node,nodeid=0,memdev=n0,cpus=0 \
 *   -numa node,nodeid=1,memdev=n1,cpus=1
 *
 * cpu 0 is node 0, so node 0 owns [0, 32M) and node 1 owns
 * [32M, 128M).  Both sides of the boundary are probed with the
 * interconnect's slice-read counter: the last dword of node 0's
 * memory and 16 MiB inside it stay direct (no counted access), while
 * the first dword of node 1's memory and 48 MiB inside it are counted
 * as foreign.  A ram_size / num_nodes split would hand [0, 64M) to
 * node 0 and call the 32/48 MiB probes local instead.
 *
 * Prints 'UNEVEN lo=... bound=... hi=... far=... fail=...' to COM1
 * and halts.  Build: `make unevennuma`, run: `make run-unevennuma`.
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

    .section .text
    .globl _start
#define CTRL        0xdf100000  /* interconnect control registers */
#define CTRL_SRD    0x28        /* slice read counter */

_start:
    movl $stack_top, %esp
    andl $-16, %esp

    /* node 0, 16 MiB: own memory, direct */
    movl CTRL+CTRL_SRD, %eax
    movl %eax, %ebx
    movl 0x01000000, %ecx
    movl CTRL+CTRL_SRD, %eax
    subl %ebx, %eax
    movl %eax, lo

    /* node 0's last dword, just below the 32 MiB boundary */
    movl CTRL+CTRL_SRD, %eax
    movl %eax, %ebx
    movl 0x01fffffc, %ecx
    movl CTRL+CTRL_SRD, %eax
    subl %ebx, %eax
    movl %eax, bound

    /* node 1's first dword at the boundary */
    movl CTRL+CTRL_SRD, %eax
    movl %eax, %ebx
    movl 0x02000000, %ecx
    movl CTRL+CTRL_SRD, %eax
    subl %ebx, %eax
    movl %eax, hi

    /* node 1, 48 MiB: foreign to cpu 0 */
    movl CTRL+CTRL_SRD, %eax
    movl %eax, %ebx
    movl 0x03000000, %ecx
    movl CTRL+CTRL_SRD, %eax
    subl %ebx, %eax
    movl %eax, far

    xorl %ebx, %ebx
    cmpl $0, lo
    je 1f
    incl %ebx
1:  cmpl $0, bound
    je 2f
    incl %ebx
2:  cmpl $0, hi
    jne 3f
    incl %ebx
3:  cmpl $0, far
    jne 4f
    incl %ebx
4:  movl %ebx, fail

    movl $msg, %esi
    call puts
    movl lo, %eax
    call puthex
    movl $sp_bound, %esi
    call puts
    movl bound, %eax
    call puthex
    movl $sp_hi, %esi
    call puts
    movl hi, %eax
    call puthex
    movl $sp_far, %esi
    call puts
    movl far, %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    jmp halt

/* puts: esi = string */
puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    incl %esi
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

halt:
    cli
1:  hlt
    jmp 1b

    .section .bss
    .balign 16
lo:    .long 0
bound: .long 0
hi:    .long 0
far:   .long 0
fail:  .long 0
    .space 4096
stack_top:

    .section .rodata
msg:      .asciz "UNEVEN lo="
sp_bound: .asciz " bound="
sp_hi:    .asciz " hi="
sp_far:   .asciz " far="
sp_f:     .asciz " fail="
nl:       .asciz "\n"
