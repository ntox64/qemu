/* SPDX-License-Identifier: BSD-2-Clause */

/* pcitest.S - freestanding multiboot PCI BAR assignment test.
 *
 * Re-enacts the firmware's PCI resource protocol on the barmem device
 * (1234:beef): enumerate the bus, decode the firmware-assigned BARs,
 * probe the BAR0 size the way SeaBIOS/OVMF do (write all-ones, read
 * the mask back), then REASSIGN BAR0 to a free hole address, enable
 * memory space and verify the device responds at the new address.
 * This is the config-space protocol nto64's /dev/pci server
 * (rsrcdbmgr, DCMD_PCI_*) must speak .
 * Build: `make pcitest`, run: `make run-pcitest`.
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
scan:
    xorl %ecx, %ecx
    call pcicfg
    cmpl $0xffffffff, %eax
    je next
    cmpl $0xbeef1234, %eax
    je found
    /* print other devices: dev, ven:dev */
    movl %edi, %eax
    call puthex
    movb $':', %al
    call putc
    xorl %ecx, %ecx
    call pcicfg
    call puthex
    movb $' ', %al
    call putc
next:
    incl %edi
    cmpl $32, %edi
    jne scan
    movl $nf_msg, %esi
    call puts
    jmp halt

found:
    movl %edi, dev_save       /* barmem dev */
    /* firmware-assigned BARs */
    movl $0x10, %ecx
    call pcicfg
    movl %eax, bar0
    movl $0x14, %ecx
    call pcicfg
    movl %eax, bar1

    /* size BAR0: write all-ones, read the mask back, restore */
    movl dev_save, %edi
    movl $0x10, %ecx
    movl $0xffffffff, %eax
    call pcicfg_write
    movl $0x10, %ecx
    call pcicfg
    movl %eax, sized
    movl bar0, %eax
    movl $0x10, %ecx
    call pcicfg_write           /* restore */

    /* reassign BAR0 to 0xE0000000, enable memory space */
    movl dev_save, %edi
    movl $0x10, %ecx
    movl $0xe0000000, %eax
    call pcicfg_write
    movl $4, %ecx
    call pcicfg
    orl $2, %eax
    movl dev_save, %edi
    movl $4, %ecx
    call pcicfg_write

    /* verify: pattern through the reassigned BAR */
    movl $0x11223344, 0xe0000000
    movl 0xe0000000, %eax
    movl %eax, pat

    /* ctrl BAR magic */
    movl bar1, %eax
    andl $0xfffffff0, %eax
    movl %eax, %ebp
    movl 0(%ebp), %eax
    movl %eax, magic

    movl $ok_msg, %esi
    call puts
    movl bar0, %eax
    call puthex
    movl $sp_bar1, %esi
    call puts
    movl bar1, %eax
    call puthex
    movl $sp_size, %esi
    call puts
    movl sized, %eax
    call puthex
    movl $sp_pat, %esi
    call puts
    movl pat, %eax
    call puthex
    movl $sp_magic, %esi
    call puts
    movl magic, %eax
    call puthex
    movl $nl, %esi
    call puts
    jmp halt

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
bar0:   .long 0
bar1:   .long 0
sized:  .long 0
pat:    .long 0
magic:  .long 0
dev_save: .long 0

    .section .rodata
ok_msg:  .asciz "PCI OK bar0="
nf_msg:  .asciz "PCI FAIL: barmem not found\n"
sp_bar1: .asciz " bar1="
sp_size: .asciz " size="
sp_pat:  .asciz " pat="
sp_magic: .asciz " magic="
nl:      .asciz "\n"
