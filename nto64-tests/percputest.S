/* SPDX-License-Identifier: BSD-2-Clause */

/* percputest.S - freestanding multiboot test for the per-CPU RAM
 * machine option (-machine q35,nto64-per-cpu-ram=on).
 *
 * Verifies that every vCPU has its own address-space view that still
 * unions into the real RAM: the shared system RAM is reachable (the
 * alias), the BSP's own private window (0xDF000000 + cpu_index*4K)
 * contains its marker, and another CPU's window address does NOT
 * contain that marker (per-CPU isolation).  Prints to COM1, halts.
 * Build: `make percputest`, run: `make run-percputest`.
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
    /* shared RAM is reachable through the per-CPU view */
    movl $0x12345678, 0x100000
    movl 0x100000, %eax
    movl %eax, sys_save

    /* own private window (cpu 0): write + read back */
    movl $0xcafebabe, 0xdf000000
    movl 0xdf000000, %eax
    movl %eax, own_save

    /* another CPU's window (cpu 1) must NOT hold our marker */
    movl 0xdf001000, %eax
    movl %eax, other_save

    /* whole-RAM slice (cpu 1's slice: 0x04000000 with -m 128 -smp 2):
     * coherent from here either way - direct RAM by default, a
     * counted trap with nto64-node-trap=on */
    movl $0xdeadbeef, 0x04000000
    movl 0x04000000, %eax
    movl %eax, slice_save
    movl 0xdf100028, %eax
    movl %eax, srd_save
    movl 0xdf10002c, %eax
    movl %eax, swr_save

    /* verify the observations: a per-CPU isolation result, not a
     * blind "OK" (shared alias, own window, foreign window, slice). */
    cmpl $0x12345678, sys_save
    je chk_sys_ok
    incl fail
chk_sys_ok:
    cmpl $0xcafebabe, own_save
    je chk_own_ok
    incl fail
chk_own_ok:
    cmpl $0xcafebabe, other_save   /* another CPU's window must NOT
                                    * hold our marker */
    jne chk_other_ok
    incl fail
chk_other_ok:
    cmpl $0xdeadbeef, slice_save
    je chk_slice_ok
    incl fail
chk_slice_ok:
    movl $msg, %esi
    call puts
    movl sys_save, %eax
    call puthex
    movl $spc_own, %esi
    call puts
    movl own_save, %eax
    call puthex
    movl $spc_other, %esi
    call puts
    movl other_save, %eax
    call puthex
    movl $spc_slice, %esi
    call puts
    movl slice_save, %eax
    call puthex
    movl $spc_srd, %esi
    call puts
    movl srd_save, %eax
    call puthex
    movl $spc_swr, %esi
    call puts
    movl swr_save, %eax
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
sys_save:   .long 0
own_save:   .long 0
other_save: .long 0
slice_save: .long 0
srd_save:   .long 0
swr_save:   .long 0
fail:       .long 0

    .section .rodata
msg:      .asciz "PERCPU sys="
spc_own:  .asciz " own="
spc_other: .asciz " other="
spc_slice: .asciz " slice="
spc_srd:   .asciz " srd="
spc_swr:   .asciz " swr="
sp_f:     .asciz " fail="
nl:       .asciz "\n"
