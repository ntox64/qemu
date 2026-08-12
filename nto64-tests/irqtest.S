/* SPDX-License-Identifier: BSD-2-Clause */

/* irqtest.S - freestanding multiboot test for nto64-irqgen.
 *
 * Scans PCI for 1234:1ee7, reads the magic, fires 5 interrupts,
 * starts a 1 ms edge storm with a dummy IDT/EOI handler, prints
 * results to COM1, halts.  Build with `make irqtest` (or see the
 * Makefile) and run with `make run-irqtest` against the local
 * qemu/build/qemu-system-x86_64 (the nto64 testbed build).
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
    /* find the device: vendor 0x1234, device 0x1ee7 */
    xorl %edi, %edi           /* dev */
scan:
    movl %edi, %ecx
    xorl %ecx, %ecx           /* reg 0 */
    call pcicfg
    cmpl $0xffffffff, %eax
    je next
    cmpl $0x1ee71234, %eax
    je found
next:
    incl %edi
    cmpl $32, %edi
    jne scan
    movl $fail_msg, %esi
    call puts
    jmp halt

found:
    /* enable memory space: cmd reg 4 |= 2 */
    movl $4, %ecx
    call pcicfg
    orl $2, %eax
    movl %edi, %esi
    movl $4, %ecx
    call pcicfg_write

    /* BAR0 */
    movl $0x10, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, %ebp           /* bar0 */

    /* magic */
    movl (%ebp), %eax
    cmpl $0x49544e4f, %eax
    je magic_ok
    movl $magic_msg, %esi
    call puts
    movl %ebp, %eax
    call puthex
    movl $spc, %esi
    call puts
    movl (%ebp), %eax
    call puthex
    movl $nl, %esi
    call puts
    jmp halt
magic_ok:

    /* fire 5 single interrupts */
    movl $5, %ebx
fire:
    movl $1, 0x10(%ebp)
    decl %ebx
    jnz fire

    /* count */
    movl 0x08(%ebp), %eax
    movl %eax, count0_save    /* count0 */

    /* IDT: 256 gates -> irq_handler (dummy: EOI + iret) */
    movl $idt_table, %edi
    movl $irq_handler, %eax
    movw %cs, %dx              /* gate selector = current flat CS */
    movl $256, %ecx
idt_loop:
    movl %eax, %ebx
    movw %bx, 0(%edi)          /* offset low */
    movw %dx, 2(%edi)          /* selector: flat code */
    movb $0, 4(%edi)
    movb $0x8e, 5(%edi)        /* present, dpl 0, 32-bit int gate */
    shrl $16, %ebx
    movw %bx, 6(%edi)          /* offset high */
    addl $8, %edi
    decl %ecx
    jnz idt_loop
    lidt idt_ptr

    /* storm: enable + edge + storm, period 1000 us */
    movl $0xb, 0x04(%ebp)
    movl $1000, 0x0c(%ebp)
    movl 0x08(%ebp), %eax
    movl %eax, count1_save    /* count right after setup */

    /* wait until the storm delivers 100 more interrupts: sti + hlt
     * wakes on each delivered interrupt (handler EOIs the PICs) */
    movl $1000000, %esi
stormwait:
    sti
    hlt
    movl 0x08(%ebp), %eax
    cmpl $105, %eax
    jge stormdone
    decl %esi
    jnz stormwait
stormdone:

    movl 0x08(%ebp), %eax
    movl %eax, %ecx           /* count1 */
    movl handler_count, %edx  /* hcount */
    movl %ebp, bar_save       /* bar0 */

    movl $ok_msg, %esi
    call puts
    movl count0_save, %eax
    call puthex
    movl $spc, %esi
    call puts
    movl %ecx, %eax
    call puthex
    movl $spc3, %esi
    call puts
    movl count1_save, %eax
    call puthex
    movl $spc4, %esi
    call puts
    movl bar_save, %eax
    call puthex
    movl $spc2, %esi
    call puts
    movl handler_count, %eax
    call puthex
    movl $nl, %esi
    call puts
    jmp halt

/* dummy interrupt handler: EOI both PICs, iret */
irq_handler:
    incl handler_count
    pushl %eax
    movb $0x20, %al
    outb %al, $0x20
    outb %al, $0xa0
    popl %eax
    iret

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

    .section .rodata
idt_ptr: .word 0x7ff
         .long idt_table
idt_table: .space 256*8, 0
handler_count: .long 0
count0_save: .long 0
count1_save: .long 0
bar_save: .long 0
ok_msg:  .asciz "IRQTEST OK magic=NTOI count0="
magic_msg: .asciz "IRQTEST FAIL: bad magic\n"
fail_msg: .asciz "IRQTEST FAIL: device not found\n"
spc:     .asciz " count1="
spc2:    .asciz " handled="
spc3:    .asciz " early="
spc4:    .asciz " bar="
nl:      .asciz "\n"
