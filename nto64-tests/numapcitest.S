/* SPDX-License-Identifier: BSD-2-Clause */

/* numapcitest.S - freestanding multiboot NUMA-aware PCI BAR
 * placement test.
 *
 * With nto64-per-cpu-ram=on, two nto64-barmem instances model two
 * "node devices".  The guest (acting as the OS resource manager)
 * moves each device's BAR0 into an aperture adjacent to a chosen
 * CPU's per-CPU window (0xDF200000 near CPU 0, 0xDF400000 near
 * CPU 1), enables memory space and verifies both devices respond -
 * the OS-side "assign PCI devices among different cores" behavior on
 * top of the per-CPU views.  The per-CPU window itself is checked
 * unchanged.
 * Build: `make numapcitest`, run: `make run-numapcitest`.
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
    xorl %edi, %edi           /* dev */
    xorl %esi, %esi           /* instance count */
scan:
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je next
    cmpl $0xbeef1234, %eax
    jne next
    movl %edi, %eax
    cmpl $0, %esi
    jne 1f
    movl %eax, dev_save0
    jmp 2f
1:  movl %eax, dev_save1
2:  incl %esi
next:
    incl %edi
    cmpl $32, %edi
    jne scan
    cmpl $2, %esi
    jge two
    movl $nf_msg, %esi
    call puts
    jmp halt

two:
    /* firmware-assigned BARs for both instances */
    movl dev_save0, %edi
    movl $0x10, %ecx
    call pcicfg
    movl %eax, bar0a
    movl $0x14, %ecx
    call pcicfg
    movl %eax, bar1a
    movl dev_save1, %edi
    movl $0x10, %ecx
    call pcicfg
    movl %eax, bar0b
    movl $0x14, %ecx
    call pcicfg
    movl %eax, bar1b

    /* instance A -> aperture near CPU 0's window */
    movl dev_save0, %edi
    movl $0x10, %ecx
    movl $0xdf200000, %eax
    call pcicfg_write
    call mem_enable
    /* instance B -> aperture near CPU 1's window */
    movl dev_save1, %edi
    movl $0x10, %ecx
    movl $0xdf400000, %eax
    call pcicfg_write
    call mem_enable

    /* verify A: pattern at its new BAR, magic at its ctrl BAR */
    movl $0x11223344, 0xdf200000
    movl 0xdf200000, %eax
    movl %eax, pat
    movl bar1a, %eax
    andl $0xfffffff0, %eax
    movl %eax, %ebp
    movl 0(%ebp), %eax
    movl %eax, magic
    /* verify B: magic at its ctrl BAR */
    movl bar1b, %eax
    andl $0xfffffff0, %eax
    movl %eax, %ebp
    movl 0(%ebp), %eax
    movl %eax, magic2
    /* per-CPU window intact: BSP own page */
    movl $0xcafebabe, 0xdf000000
    movl 0xdf000000, %eax
    movl %eax, own

    movl $ok_msg, %esi
    call puts
    movl bar0a, %eax
    call puthex
    movl $sp_ab, %esi
    call puts
    movl bar0b, %eax
    call puthex
    movl $sp_pat, %esi
    call puts
    movl pat, %eax
    call puthex
    movl $sp_mag, %esi
    call puts
    movl magic, %eax
    call puthex
    movb $'/', %al
    call putc
    movl magic2, %eax
    call puthex
    movl $sp_own, %esi
    call puts
    movl own, %eax
    call puthex
    movl $nl, %esi
    call puts
    jmp halt

/* enable memory space for the device in edi */
mem_enable:
    movl $4, %ecx
    call pcicfg
    orl $2, %eax
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write
    movl %esi, %edi
    ret

/* pcicfg: edi=dev, ecx=reg -> eax */
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

/* pcicfg_write: edi=dev, ecx=reg, eax=value */
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
dev_save0: .long 0
dev_save1: .long 0
bar0a: .long 0
bar1a: .long 0
bar0b: .long 0
bar1b: .long 0
pat:   .long 0
magic: .long 0
magic2: .long 0
own:   .long 0

    .section .rodata
ok_msg:  .asciz "NUMA PCI OK a="
nf_msg:  .asciz "NUMA PCI FAIL: need two barmem devices\n"
sp_ab:   .asciz " b="
sp_pat:  .asciz " pat="
sp_mag:  .asciz " mag="
sp_own:  .asciz " own="
nl:      .asciz "\n"
