/* SPDX-License-Identifier: BSD-2-Clause */

/* rebar.S - freestanding multiboot test for the PCIe Resizable BAR
 * (REBAR) capability on nto64-barmem.
 *
 * q35 only (the REBAR cap lives in PCIe extended config space, reached
 * through the ECAM window whose base the MCH publishes in PCIEXBAR).
 * Steps:
 *   find nto64-barmem (1234:beef), enable memory space, read BAR0;
 *   probe BAR0: 256 MiB by default;
 *   walk the extended capability list, find REBAR (0x000F), verify
 *     the capability register (sizes 64M/128M/256M/512M) and the
 *     control register's BAR size mask;
 *   resize to 64 MiB via the control BAR Size field, re-probe
 *     (mask 0xFC000000), reassign to base+64M, fill + verify the new
 *     range;
 *   grow to 128 MiB (mask 0xF8000000) and 256 MiB (0xF0000000) at
 *     the original base, filling + verifying each time; the control
 *     BAR Size field must track the current size.
 * Prints to COM1, halts.  Build: `make rebar`, run: `make run-rebartest`.
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
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0xbeef1234, %eax
    je found
scan_next:
    incl %edi
    cmpl $32, %edi
    jb scan
    incl fail
    jmp report
found:
    movl %edi, dev

    /* enable memory space, read BAR0 base */
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %ebp
    movl dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, bar_base

    /* probe BAR0: expect the 256 MiB mask (0xF0000000) */
    movl dev, %edi
    movl $0x10, %ecx
    movl $0, %ebp
    call cfgwrite32
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    movl %eax, probe_val
    cmpl $0xf0000000, %eax
    je 1f
    incl fail
1:  movl dev, %edi
    movl $0x10, %ecx
    movl bar_base, %ebp
    call cfgwrite32

    /* ECAM base from the MCH PCIEXBAR (bus 0 dev 0, reg 0x60) */
    xorl %edi, %edi
    movl $0x60, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, ecam

    /* walk the extended caps from 0x100, find REBAR (0x0015) */
    movl ecam, %esi
    movl dev, %eax
    shll $15, %eax
    addl %eax, %esi
    movl $0x100, %edi
capwalk:
    movl (%esi,%edi), %eax
    andl $0xffff, %eax
    cmpl $0x0015, %eax
    je capfound
    movl (%esi,%edi), %eax
    shrl $20, %eax
    testl %eax, %eax
    jz capmissing
    movl %eax, %edi
    jmp capwalk
capmissing:
    incl fail
    jmp report
capfound:
    movl %edi, cap
    /* capability register: sizes 64M/128M/256M/512M in bits 4..23;
     * bits 3:0 are RsvdP and must read 0 (PCIe 7.0 Table 7-165) */
    movl 4(%esi,%edi), %eax
    cmpl $0x3c00, %eax
    je 1f
    incl fail
1:  /* control register: BAR0 (RO), NBAR=1, BAR Size = 8 (256M) */
    movl 8(%esi,%edi), %eax
    movl %eax, ctrl_save
    andl $0x1f00, %eax
    cmpl $0x800, %eax
    je 2f
    incl fail
2:  /* reserved bits 31:14 must read 0 (RsvdP) */
    movl ctrl_save, %eax
    andl $0xffffc000, %eax
    testl %eax, %eax
    jz 3f
    incl fail
3:

    /* resize to 64 MiB (BAR Size field = 6), re-probe */
    movl ctrl_save, %eax
    andl $0xffffe0ff, %eax
    orl $0x600, %eax
    movl %eax, %ebp
    movl ecam, %esi
    movl dev, %eax
    shll $15, %eax
    addl %eax, %esi
    movl cap, %edi
    movl %ebp, 8(%esi,%edi)
    movl 8(%esi,%edi), %eax
    andl $0x1f00, %eax
    cmpl $0x600, %eax
    je 1f
    incl fail
1:  movl dev, %edi
    movl $0x10, %ecx
    movl $0, %ebp
    call cfgwrite32
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    cmpl $0xfc000000, %eax
    je 2f
    incl fail
2:  movl %eax, probe64
    /* reassign to the (all-sizes-aligned) base and verify the
     * 64 MiB window - the resize -> mapping teardown/re-establish
     * case (the ~0 probe unmaps, this write re-maps). */
    movl dev, %edi
    movl $0x10, %ecx
    movl bar_base, %ebp
    call cfgwrite32
    movl bar_base, %eax
    movl %eax, cur_base
    movl $0x04000000, bar_size
    movl $0x5a5a5a5a, %eax
    call fillbar
    call checkbar

    /* grow to 128 MiB (BAR Size 7) at the original base */
    movl ecam, %esi
    movl dev, %eax
    shll $15, %eax
    addl %eax, %esi
    movl cap, %edi
    movl 8(%esi,%edi), %eax
    andl $0xffffe0ff, %eax
    orl $0x700, %eax
    movl %eax, 8(%esi,%edi)
    movl dev, %edi
    movl $0x10, %ecx
    movl $0, %ebp
    call cfgwrite32
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    cmpl $0xf8000000, %eax
    je 1f
    incl fail
1:  movl %eax, probe128
    movl dev, %edi
    movl $0x10, %ecx
    movl bar_base, %ebp
    call cfgwrite32
    movl bar_base, %eax
    movl %eax, cur_base
    movl $0x08000000, bar_size
    movl $0x6b6b6b6b, %eax
    call fillbar
    call checkbar

    /* grow to 256 MiB (BAR Size 8) at the original base */
    movl ecam, %esi
    movl dev, %eax
    shll $15, %eax
    addl %eax, %esi
    movl cap, %edi
    movl 8(%esi,%edi), %eax
    andl $0xffffe0ff, %eax
    orl $0x800, %eax
    movl %eax, 8(%esi,%edi)
    movl dev, %edi
    movl $0x10, %ecx
    movl $0, %ebp
    call cfgwrite32
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    cmpl $0xf0000000, %eax
    je 1f
    incl fail
1:  movl %eax, probe256
    movl dev, %edi
    movl $0x10, %ecx
    movl bar_base, %ebp
    call cfgwrite32
    movl bar_base, %eax
    movl %eax, cur_base
    movl $0x10000000, bar_size
    movl $0x7c7c7c7c, %eax
    call fillbar
    call checkbar

report:
    movl $msg, %esi
    call puts
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
    movl $sp_base, %esi
    call puts
    movl bar_base, %eax
    call puthex
    movl $sp_ecam, %esi
    call puts
    movl ecam, %eax
    call puthex
    movl $sp_probe, %esi
    call puts
    movl probe_val, %eax
    call puthex
    movl $sp_p64, %esi
    call puts
    movl probe64, %eax
    call puthex
    movl $sp_p128, %esi
    call puts
    movl probe128, %eax
    call puthex
    movl $sp_p256, %esi
    call puts
    movl probe256, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* fillbar: fill the whole current BAR (cur_base..+bar_size) with eax */
fillbar:
    push %edi
    push %ecx
    movl cur_base, %edi
    movl bar_size, %ecx
    shrl $2, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 1b
    pop %ecx
    pop %edi
    ret

/* checkbar: verify pattern dwords across the current BAR:
 * first, last, and 7 sample points (k*bar_size/8); pattern in eax */
checkbar:
    push %edi
    push %ecx
    push %ebx
    push %edx
    movl %eax, %ebx
    movl cur_base, %edi
    cmpl %ebx, (%edi)
    je 1f
    incl fail
1:  movl cur_base, %edi
    addl bar_size, %edi
    subl $4, %edi
    cmpl %ebx, (%edi)
    je 2f
    incl fail
2:  movl $7, %ecx
    movl bar_size, %eax
    shrl $3, %eax               /* step = bar_size / 8 */
    movl %eax, %edx             /* offset = k * step */
3:  movl cur_base, %edi
    addl %edx, %edi
    cmpl %ebx, (%edi)
    je 4f
    incl fail
4:  addl %eax, %edx
    decl %ecx
    jnz 3b
    pop %edx
    pop %ebx
    pop %ecx
    pop %edi
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

/* cfgwrite32: edi=dev, ecx=byteoff, r8d=val (clobbers eax, ebx, edx) */
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
dev:        .long 0
bar_base:   .long 0
cur_base:   .long 0
bar_size:   .long 0
ecam:       .long 0
cap:        .long 0
ctrl_save:  .long 0
probe_val:  .long 0
probe64:    .long 0
probe128:   .long 0
probe256:   .long 0
fail:       .long 0

    .section .rodata
msg:     .asciz "REBAR "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_base: .asciz " base="
sp_ecam: .asciz " ecam="
sp_probe: .asciz " probe="
sp_p64:   .asciz " p64="
sp_p128:  .asciz " p128="
sp_p256:  .asciz " p256="
nl:      .asciz "\n"
