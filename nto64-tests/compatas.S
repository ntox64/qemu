/* SPDX-License-Identifier: BSD-2-Clause */

/* compatas.S - positive control for the qemu "inspection CR3" (qemu.Cr3)
 * gdbstub extension: prove a software breakpoint in a COMPAT (32-bit) user
 * address space inserts and fires under TCG.
 *
 * Layout (single multiboot kernel, ELF32, loaded by the testbed qemu):
 *   - .code32 bootstrap: build page tables, enable long mode, far-jump to
 *     a 64-bit code segment.
 *   - .code64 kernel: print a marker, copy the embedded 32-bit user blob to
 *     a fixed VA (USER_BASE = 0x1800000), switch CR3 to the USER root, and
 *     iretq into a ring-3 COMPAT (32-bit) user program.
 *   - .data user blob (.code32): the compat code that prints and spins.
 *
 * Two page-table roots, deliberately different:
 *   KPGD: identity-map only 0..16 MiB as supervisor.  The user VA
 *         (0x1800000) is ABSENT, so gdb "Cannot access memory" while the
 *         vCPU is in the kernel -> reproduces the original limitation.
 *   UPGD: identity-map 0..16 MiB (so the iretq instruction is still mapped)
 *         PLUS the 2 MiB user page at 0x1800000 (U/S=1, RW).  This is the
 *         "compat AS" the debugger must be aimed at via `Qqemu.Cr3:<UPGD>`.
 *
 * Run under TCG with -S and -accel tcg,one-insn-per-tb=on; break on the
 * spin VA (USER_BASE + (spin - user_start)) and confirm gdb stops there.
 * Build:  gcc -m32 -nostdlib -static -fno-pie \
 *            -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
 *            -o compatas compatas.S
 */

#define KCODE32_SEL 0x08   /* 32-bit kernel code, DPL0, L=0, D=1 (boot) */
#define KDATA_SEL   0x10   /* kernel data, DPL0 */
#define KCODE64_SEL 0x18   /* 64-bit kernel code, DPL0, L=1 (long mode) */
#define UCODE32_SEL 0x20   /* 32-bit compat user code, DPL3, L=0, D=1 */
#define UDATA_SEL   0x28   /* user data, DPL3 */
#define UCODE_RPL3  0x23   /* 0x20 | 3 */
#define UDATA_RPL3  0x2b   /* 0x28 | 3 */

#define KPGD   0x300000    /* kernel PML4 */
#define KPDP   0x301000    /* kernel PDPT (entry 0, covers 0..1G) */
#define KPD    0x302000    /* kernel PD (2 MiB pages) */
#define UPGD   0x303000    /* user PML4 */
#define UPDP   0x304000
#define UPD    0x305000
#define KSTACK 0x400000    /* kernel stack (grows down) */

#define USER_BASE        0x1800000     /* compat user code/stack 2 MiB page */
#define USER_STACK_TOP   0x1890000
#define USER_PDE_INDEX   12            /* 0x1800000 / 2 MiB = 12 */

    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1badb002       /* magic */
    .long 0                /* flags */
    .long -0x1badb002      /* checksum */

    .section .text
    .code32
    .globl _start
_start:
    cli
    movl $KSTACK, %esp
    lgdt gdt_ptr
    /* Reload CS/DS/SS from MY GDT so the bootloader's selectors cannot
     * land on a descriptor this layout never intended (e.g. a D=0/16-bit
     * segment).  KCODE32_SEL is a flat 32-bit code segment. */
    ljmp $KCODE32_SEL, $boot32
boot32:
    movw $KDATA_SEL, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    /* Copy the embedded compat user blob to USER_BASE while paging is off
     * (VA == PA).  The kernel root does not map USER_BASE, so this must
     * happen before long mode is entered. */
    movl $user_start, %esi
    movl $USER_BASE, %edi
    movl $user_end - user_start, %ecx
    rep movsb

    /* Build the page tables while paging is off (VA == PA). */
    call build_paging

    /* Long-mode enable: PAE, CR3=KPGD, EFER.LME, CR0.PG. */
    movl %cr4, %eax
    orl  $0x20, %eax        /* PAE */
    movl %eax, %cr4

    movl $KPGD, %eax
    movl %eax, %cr3

    movl $0xc0000080, %ecx  /* EFER */
    rdmsr
    orl  $0x100, %eax       /* LME (bit 8) */
    wrmsr

    movl %cr0, %eax
    orl  $0x80000000, %eax  /* PG */
    movl %eax, %cr0

    /* Switch to a 64-bit code segment. */
    ljmp $KCODE64_SEL, $long_mode64

/* ------------------------------------------------------------------ */
/* build_paging: fill KPGD/KPDP/KPD (0..16 MiB supervisor identity) and
 *               UPGD/UPDP/UPD (same + user page at USER_BASE).          */
build_paging:
    /* zero all six 4 KiB page tables. */
    movl $KPGD, %edi
    movl $6144, %ecx        /* 6 pages * 1024 dwords */
    xorl %eax, %eax
    rep stosl

    /* KPGD[0] -> KPDP, KPDP[0] -> KPD. */
    movl $(KPDP | 0x3), %eax
    movl %eax, KPGD
    movl $(KPD  | 0x3), %eax
    movl %eax, KPDP

    /* KPD[0..7] = 2 MiB pages 0..16 MiB, supervisor, RW, present, PS=1. */
    movl $KPD, %edi
    xorl %ebx, %ebx
    movl $8, %ecx
1:  movl %ebx, %eax
    orl  $0x83, %eax
    movl %eax, (%edi)
    addl $8, %edi
    addl $0x200000, %ebx
    decl %ecx
    jnz  1b

    /* UPGD[0] -> UPDP, UPDP[0] -> UPD.  U/S=1 at the top two levels too,
     * otherwise the whole subtree is supervisor-gated and the user page
     * faults with a protection violation even though its PDE has US=1. */
    movl $(UPDP | 0x7), %eax
    movl %eax, UPGD
    movl $(UPD  | 0x7), %eax
    movl %eax, UPDP

    /* UPD[0..7] = same supervisor identity (so iretq stays mapped). */
    movl $KPD, %esi
    movl $UPD, %edi
    movl $8, %ecx
2:  movl (%esi), %eax
    movl %eax, (%edi)
    addl $8, %esi
    addl $8, %edi
    decl %ecx
    jnz  2b

    /* UPD[USER_PDE_INDEX] = USER_BASE 2 MiB page, user, RW, present, PS=1. */
    movl $(USER_BASE | 0x87), %eax
    movl %eax, UPD + (USER_PDE_INDEX * 8)
    ret

/* ------------------------------------------------------------------ */
    .code64
long_mode64:
    /* Reload data/stack selectors (now 64-bit long mode, paging on). */
    movw $KDATA_SEL, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    movq $KSTACK, %rsp

    /* Kernel marker so a serial-only run proves it reached here. */
    movl $kernel_msg, %esi
    call puts64

    /* Switch to the USER page table, then iretq to ring-3 compat code. */
    movq $UPGD, %rax
    mov  %rax, %cr3

    pushq $UDATA_RPL3          /* SS */
    pushq $USER_STACK_TOP      /* RSP */
    pushq $0x3002              /* RFLAGS: IOPL=3 | IF=0 | bit1  (no timer IRQ) */
    pushq $UCODE_RPL3          /* CS (32-bit compat user, DPL3) */
    pushq $USER_BASE           /* RIP (32-bit compat entry) */
    iretq

/* puts64: %esi = string (zero-extended 32-bit addr) -> COM1 */
puts64:
    movzbl (%esi), %eax
    testb %al, %al
    jz 1f
    call putc64
    incl %esi
    jmp puts64
1:  ret

putc64:                       /* al -> COM1 */
    push %rcx
    movzbl %al, %ecx
    movw $0x3fd, %dx
2:  inb %dx, %al
    testb $0x20, %al
    jz 2b
    movw $0x3f8, %dx
    movb %cl, %al
    outb %al, %dx
    pop %rcx
    ret

/* ------------------------------------------------------------------ */
    .section .data
    .align 4
    .code32
user_start:
    /* Ring-3 compat (32-bit) code.  Runs at USER_BASE; labels are copied
     * by offset, so compute a runtime VA as USER_BASE + (label - user_start). */
    movw $UDATA_RPL3, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs

    /* print "COMPATAS-ENTER\n" */
    movl $USER_BASE + (user_msg - user_start), %esi
putsin:
    movzbl (%esi), %eax
    testb %al, %al
    jz 3f
    call putc32
    incl %esi
    jmp putsin
3:
    /* Spin forever at a fixed VA (the breakpoint target). */
spin:
    pause
    jmp spin

putc32:                       /* al -> COM1 (IOPL=3 in RFLAGS) */
    push %ecx
    movzbl %al, %ecx
    movw $0x3fd, %dx
4:  inb %dx, %al
    testb $0x20, %al
    jz 4b
    movw $0x3f8, %dx
    movb %cl, %al
    outb %al, %dx
    pop %ecx
    ret

user_msg:
    .asciz "COMPATAS-ENTER\n"
user_end:

/* Runtime VA of the spin loop, computed by offset. */
    .globl spin_va
spin_va = USER_BASE + (spin - user_start)

    .section .rodata
gdt:
    .word 0x0000; .word 0x0000; .byte 0x00, 0x00, 0x00, 0x00   /* 0x00 null */
    .word 0xffff; .word 0x0000; .byte 0x00, 0x9a, 0xcf, 0x00   /* 0x08 32-bit kcode */
    .word 0xffff; .word 0x0000; .byte 0x00, 0x92, 0xcf, 0x00   /* 0x10 kernel data  */
    .word 0xffff; .word 0x0000; .byte 0x00, 0x9a, 0xaf, 0x00   /* 0x18 64-bit kcode */
    .word 0xffff; .word 0x0000; .byte 0x00, 0xfa, 0xcf, 0x00   /* 0x20 compat user code */
    .word 0xffff; .word 0x0000; .byte 0x00, 0xf2, 0xcf, 0x00   /* 0x28 user data    */
gdt_end:

gdt_ptr:
    .word gdt_end - gdt - 1
    .long gdt

kernel_msg:
    .asciz "COMPATAS-KERNEL\n"
