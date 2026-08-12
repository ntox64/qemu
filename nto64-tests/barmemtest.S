/* SPDX-License-Identifier: BSD-2-Clause */

/* barmemtest.S - freestanding multiboot test for nto64-barmem.
 *
 * Scans PCI for 1234:beef, checks the control MMIO (magic "NTO6",
 * BAR0 size), exercises the big memory BAR: writes a 64 KiB pattern
 * from guest RAM into BAR0 (rdtsc-timed), reads it back and verifies
 * byte-for-byte, then rings the doorbell 3 times and checks the
 * counter.  Prints results to COM1, halts.
 * Build: `make barmemtest`, run: `make run-barmemtest` against the
 * local qemu/build/qemu-system-x86_64.
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
    /* find the device: vendor 0x1234, device 0xbeef */
    xorl %edi, %edi           /* dev */
scan:
    movl %edi, %ecx
    xorl %ecx, %ecx           /* reg 0 */
    call pcicfg
    cmpl $0xffffffff, %eax
    je next
    cmpl $0xbeef1234, %eax
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

    /* BAR0 (big memory), BAR1 (control MMIO) */
    movl $0x10, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, bar0_save
    movl $0x14, %ecx
    call pcicfg
    andl $0xfffffff0, %eax
    movl %eax, bar1_save

    /* control MMIO: magic, size */
    movl bar1_save, %esi
    movl 0(%esi), %eax
    cmpl $0x4e544f36, %eax    /* "NTO6" */
    je magic_ok
    movl $magic_msg, %esi
    call puts
    jmp halt
magic_ok:
    movl bar1_save, %esi
    movl 8(%esi), %eax
    movl %eax, size_save

    /* doorbell: expect 0, ring 3 times, expect 3 */
    movl bar1_save, %esi
    movl 4(%esi), %eax
    movl %eax, db0_save
    movl $1, 4(%esi)
    movl $2, 4(%esi)
    movl $3, 4(%esi)
    movl 4(%esi), %eax
    movl %eax, db1_save

    /* fill guest buffer with a pattern, checksum it */
    movl $buf, %esi
    movl $16384, %ecx         /* 64 KiB / 4 */
    xorl %ebx, %ebx           /* index */
    xorl %edx, %edx
fill:
    movl %ebx, %eax
    imull $2654435761, %eax, %eax
    movl %eax, (%esi)
    addl %eax, %edx
    addl $4, %esi
    incl %ebx
    decl %ecx
    jnz fill
    movl %edx, cksum_save

    /* timed copy: guest RAM -> BAR0 */
    rdtsc
    movl %eax, t0_save
    movl $buf, %esi
    movl bar0_save, %edi
    movl $16384, %ecx
wr:
    movl (%esi), %eax
    movl %eax, (%edi)
    addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz wr
    rdtsc
    subl t0_save, %eax
    movl %eax, cyc_save

    /* read BAR0 back into a second buffer */
    movl bar0_save, %esi
    movl $buf2, %edi
    movl $16384, %ecx
rd:
    movl (%esi), %eax
    movl %eax, (%edi)
    addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz rd

    /* verify buf2 == buf; count mismatched words */
    movl $buf, %esi
    movl $buf2, %edi
    movl $16384, %ecx
    xorl %edx, %edx
cmp:
    movl (%esi), %eax
    cmpl %eax, (%edi)
    je 1f
    incl %edx
1:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz cmp
    movl %edx, mm_save

    movl $ok_msg, %esi
    call puts
    movl size_save, %eax
    call puthex
    movl $spc_db, %esi
    call puts
    movl db0_save, %eax
    call puthex
    movl $spc_slash, %esi
    call puts
    movl db1_save, %eax
    call puthex
    movl $spc_cyc, %esi
    call puts
    movl cyc_save, %eax
    call puthex
    movl $spc_mm, %esi
    call puts
    movl mm_save, %eax
    call puthex
    movl $spc_ck, %esi
    call puts
    movl cksum_save, %eax
    call puthex
    movl $nl, %esi
    call puts

    /* --- MMIO path: switch BAR0 to trap-based MMIO, redo the copy */
    movl bar1_save, %esi
    movl 0x0c(%esi), %eax
    orl $1, %eax
    movl %eax, 0x0c(%esi)

    rdtsc
    movl %eax, t0_save
    movl $buf, %esi
    movl bar0_save, %edi
    movl $16384, %ecx
wr2:
    movl (%esi), %eax
    movl %eax, (%edi)
    addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz wr2
    rdtsc
    subl t0_save, %eax
    movl %eax, cyc2_save

    movl bar0_save, %esi
    movl $buf2, %edi
    movl $16384, %ecx
rd2:
    movl (%esi), %eax
    movl %eax, (%edi)
    addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz rd2

    movl $buf, %esi
    movl $buf2, %edi
    movl $16384, %ecx
    xorl %edx, %edx
cmp2:
    movl (%esi), %eax
    cmpl %eax, (%edi)
    je 1f
    incl %edx
1:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz cmp2
    movl %edx, mm2_save

    /* --- doorbell IRQ: enable, ring 3x, check the irq counter */
    movl bar1_save, %esi
    movl 0x0c(%esi), %eax
    orl $2, %eax
    movl %eax, 0x0c(%esi)
    movl 0x10(%esi), %eax
    movl %eax, irq0_save
    movl $1, 4(%esi)
    movl $2, 4(%esi)
    movl $3, 4(%esi)
    movl 0x10(%esi), %eax
    movl %eax, irq1_save

    movl $ok2_msg, %esi
    call puts
    movl cyc2_save, %eax
    call puthex
    movl $spc_mm2, %esi
    call puts
    movl mm2_save, %eax
    call puthex
    movl $spc_irq, %esi
    call puts
    movl irq0_save, %eax
    call puthex
    movl $spc_slash, %esi
    call puts
    movl irq1_save, %eax
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

    .section .rodata
ok_msg:  .asciz "BARMEM OK size="
ok2_msg: .asciz "BARMEM2 OK mmio_cyc="
magic_msg: .asciz "BARMEM FAIL: bad magic\n"
fail_msg: .asciz "BARMEM FAIL: device not found\n"
spc_db:  .asciz " db="
spc_slash: .asciz "/"
spc_cyc: .asciz " cyc="
spc_mm:  .asciz " mm="
spc_ck:  .asciz " cksum="
spc_mm2: .asciz " mmio_mm="
spc_irq: .asciz " irq="
nl:      .asciz "\n"

    .section .bss
    .balign 16
bar0_save: .long 0
bar1_save: .long 0
size_save: .long 0
db0_save:  .long 0
db1_save:  .long 0
cyc_save:  .long 0
mm_save:   .long 0
cksum_save: .long 0
t0_save:   .long 0
cyc2_save: .long 0
mm2_save:  .long 0
irq0_save: .long 0
irq1_save: .long 0
buf:   .space 65536
buf2:  .space 65536
