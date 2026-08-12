/* SPDX-License-Identifier: BSD-2-Clause */

/* slicetrace.S - minimal foreign-slice access loop for TCG tracing.
 *
 * With -machine q35,nto64-per-cpu-ram=on,nto64-node-trap=on -smp 2
 * -m 40, cpu 1 owns [0x01400000, 0x02800000); this kernel (in cpu 0's
 * slice) writes and reads 0x01800000 in a tight loop.  Run with
 * -d in_asm,out_asm and count translations of the loop to see whether
 * every trapped memory op re-enters/re-translates the code chain.
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
    movl $16, %ecx
1:  movl $0x11223344, 0x01800000   /* foreign slice dword (trapped) */
    movl 0x01800000, %eax
    decl %ecx
    jnz 1b

    movl $ok_msg, %esi
    call puts
    jmp halt

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

halt:
    cli
1:  hlt
    jmp 1b

    .section .rodata
ok_msg: .asciz "SLICE TRACE OK\n"
