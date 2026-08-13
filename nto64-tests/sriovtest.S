/* SPDX-License-Identifier: BSD-2-Clause */

/* sriovtest.S - freestanding multiboot test for virtio-net SR-IOV
 * (the composable user-created-VF model, docs/system/sriov.rst).
 *
 * Machine: q35 with a pcie-root-port carrying one virtio-net PF
 * (id=f, addr 0x0.0) and two user-created VFs (sriov-pf=f at
 * 0x0.1 / 0x0.2), in the documented order (VFs first, PF last).
 *
 * The guest's VF-ownership flow:
 *   finds the root port on bus 0 and reads its secondary bus;
 *   finds the virtio-net PF (1af4:1041 modern / 1000 legacy);
 *   VF devfns are NOT present before SR-IOV enable (config reads
 *     return 0xffffffff for a disabled VF);
 *   walks the PF's extended capabilities to the SR-IOV cap (0x10):
 *     TOTAL_VF = 2, VF offset/stride = 1/1, the cap's VF Device ID =
 *     the real virtio id, and a VF BAR size-probe;
 *   writes NUM_VF = 2, then SR-IOV Control VFE|MSE (the Linux
 *     sriov_numvfs flow) and confirms VFE latches in the read-back;
 *   re-reads the VF devfns: now present with VID/DID = ffff per
 *     spec (the VF's own VID/DID fields are unused, so the dword at
 *     0 reads 0xffffffff) and an MSI-X capability in the VF's list.
 *
 * QEMU model gotchas (all observed empirically on this tree):
 *   CF8/CFC only addresses the first 256 config bytes.  The SR-IOV
 *     capability (>= 0x100) must be read/written through ECAM, the
 *     MMIO window at 0xb0000000 (q35 MCH: 0xb0000000 + bus*0x100000
 *     + devfn*0x1000 + offset); a CF8 read at 0x100 wraps to 0 and
 *     returns VID/DID.
 *   QEMU starts the SR-IOV NUM_VF register at 0; the guest must
 *     write it before setting VFE or 0 VFs register.
 *   VF config reads return 0xffffffff until VFE is set (enabled
 *     gates config reads, not just BAR mapping).
 *   The PF is a pure virtio-1.0 device (1af4:1041), not the
 *     transitional 1af4:1000; a modern virtio VF's BARs are regions
 *     1 and 4 (region 0 is unused), and the SR-IOV VF BAR fields
 *     hold the BAR type - size-probe them by writing all-ones.
 * Prints to COM1, halts.  Build: `make sriovtest`,
 * run: `make run-sriovtest`.
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
    movl $stack_top, %esp
    andl $-16, %esp

    /* --- find the root port on bus 0 (1b36:000c) ---- */
    xorl %edi, %edi
rp_scan:
    movl $0, %esi
    xorl %ecx, %ecx
    call cfgread32b
    cmpl $0xffffffff, %eax
    je rp_next
    cmpl $0x000c1b36, %eax
    je rp_found
rp_next:
    incl %edi
    cmpl $32, %edi
    jb rp_scan
    incl devf1
    jmp report
rp_found:
    /* secondary bus number = bits 8-15 of the dword at 0x18
     * (byte 0x19 of config; cfgread32b masks to the aligned dword) */
    movl $0x19, %ecx
    call cfgread32b
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, sec_bus

    /* --- find the virtio-net PF (1af4:1041 modern / 1000 legacy)
     * on the secondary bus ---- */
    movl sec_bus, %esi
    xorl %edi, %edi
pf_scan:
    xorl %ecx, %ecx
    call cfgread32b
    cmpl $0xffffffff, %eax
    je pf_next
    cmpl $0x10001af4, %eax
    je pf_found
    cmpl $0x10411af4, %eax
    je pf_found
pf_next:
    incl %edi
    cmpl $32, %edi
    jb pf_scan
    incl devf2
    jmp report
pf_found:
    movl %edi, pf_dev

    /* --- VFs must NOT be present before SR-IOV enable ---- */
    movl sec_bus, %esi
    movl $1, %edi
    xorl %ecx, %ecx
    call cfgread32b
    cmpl $0xffffffff, %eax
    je 1f
    incl vf_dis
1:
    /* --- walk extended capabilities: the list starts at 0x100.
     * The 32-bit header is [15:0] cap id, [31:20] next offset in bytes
     * (DWORD-aligned, so low 2 bits of the field are zero).  ecamread32
     * clobbers eax/ebx/ecx/esi but not edx/edi/ebp, so edx holds the
     * maximum-cap bound and ebp the running byte offset. */
    movl $0x100, %ebp
    movl $16, %edx            /* bound the walk: no capability list is
                                 longer, and a cycle must terminate */
cap_loop:
    testl %ebp, %ebp
    jz 2f
    testl %edx, %edx
    jz 2f
    decl %edx
    movl sec_bus, %esi
    movl pf_dev, %edi
    movl %ebp, %ecx
    call ecamread32
    andl $0xff, %eax
    cmpl $0x10, %eax          /* PCI_EXT_CAP_ID_SRIOV */
    je cap_found
    movl sec_bus, %esi        /* ecamread32 clobbered esi - must restate
                                 bus/function before the next read */
    movl pf_dev, %edi
    movl %ebp, %ecx
    call ecamread32
    shrl $20, %eax
    andl $0xffc, %eax         /* next capability, byte offset */
    movl %eax, %ebp
    cmpl $0x100, %ebp
    jb 2f                     /* out of range: no extended cap */
    cmpl $0xfff, %ebp
    ja 2f
    jmp cap_loop
2:  incl devf3
    jmp report
cap_found:
    movl %ebp, sriov_cap

    /* --- SR-IOV capability fields ---- */
    /* TOTAL_VF (cap+0x0e): 16-bit (NUM_VF is 0 until the guest
     * requests VFs - checked after the enable below) */
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x0e(%ebp), %ecx
    call ecamread32
    andl $0xffff, %eax
    cmpl $2, %eax
    je 3f
    incl cap1
3:  /* VF offset (cap+0x14) and stride (cap+0x16) */
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x14(%ebp), %ecx
    call ecamread32
    andl $0xffff, %eax
    cmpl $1, %eax
    je 5f
    incl cap2
5:  movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x16(%ebp), %ecx
    call ecamread32
    andl $0xffff, %eax
    cmpl $1, %eax
    je 6f
    incl cap3
6:  /* VF Device ID (cap+0x1a): the real virtio id (0x1041 modern) */
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x1a(%ebp), %ecx
    call ecamread32
    andl $0xffff, %eax
    cmpl $0x1041, %eax
    je 7f
    incl cap4
7:  /* VF BAR1 (cap+0x28): size-probe it (modern virtio's first BAR
     * is region 1 - the common config; BAR0 region is unused).  The
     * BAR field holds the type, so the real check is the size mask
     * returned by writing all-ones. */
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x28(%ebp), %ecx
    movl $0xffffffff, %ebp
    call ecamwrite32
    movl sriov_cap, %ebp
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x28(%ebp), %ecx
    call ecamread32
    andl $0xfffff000, %eax
    jnz 8f
    incl cap5
8:
    /* --- enable VFs: first write NUM_VF (cap+0x10) = 2 (the Linux
     * sriov_numvfs flow), then control (cap+0x08) |= VFE | MSE ---- */
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x10(%ebp), %ecx
    movl $2, %ebp
    call ecamwrite32
    movl sriov_cap, %ebp
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x08(%ebp), %ecx
    call ecamread32
    orl $9, %eax
    movl %eax, wrval
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x08(%ebp), %ecx
    movl wrval, %ebp
    call ecamwrite32
    /* read the control back: VFE (bit0) must be latched */
    movl sriov_cap, %ebp
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x08(%ebp), %ecx
    call ecamread32
    movl %eax, ctrl_echo
    testl $1, %eax
    jnz 9f
    incl vf_off
9:
    /* NUM_VF (cap+0x10) now reads 2 (written by the guest) */
    movl sriov_cap, %ebp
    movl sec_bus, %esi
    movl pf_dev, %edi
    leal 0x10(%ebp), %ecx
    call ecamread32
    andl $0xffff, %eax
    cmpl $2, %eax
    je 14f
    incl cap6
14:
    /* --- VF config after enable: dword at 0 = ffffffff (the VF's
     * own VID/DID fields are 0xffff per spec), MSI-X present ---- */
    movl sec_bus, %esi
    movl $1, %edi
    xorl %ecx, %ecx
    call cfgread32b
    cmpl $0xffffffff, %eax
    je 10f
    incl vf_bad
10: movl sec_bus, %esi
    movl $1, %edi
    movl $0x34, %ecx
    call cfgread32b
    andl $0xff, %eax
    movl %eax, %ebp
    movl $0, vf_msix
msix_loop:
    testl %ebp, %ebp
    jz 11f
    movl sec_bus, %esi
    movl $1, %edi
    movl %ebp, %ecx
    call cfgread32b
    andl $0xff, %eax
    cmpl $0x11, %eax          /* PCI_CAP_ID_MSIX */
    je 12f
    movl %ebp, %ecx
    call cfgread32b
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, %ebp
    jmp msix_loop
12: incl vf_msix
11: movl sec_bus, %esi
    movl $2, %edi
    xorl %ecx, %ecx
    call cfgread32b
    cmpl $0xffffffff, %eax
    je 13f
    incl vf_bad
13:

report:
    movl $msg, %esi
    call puts
    movl devf1, %eax
    addl devf2, %eax
    addl devf3, %eax
    addl cap1, %eax
    addl cap2, %eax
    addl cap3, %eax
    addl cap4, %eax
    addl cap5, %eax
    addl cap6, %eax
    addl vf_dis, %eax
    addl vf_off, %eax
    addl vf_bad, %eax
    movl %eax, fail
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
    movl $sp_pf, %esi
    call puts
    movl pf_dev, %eax
    call puthex
    movl $sp_ca, %esi
    call puts
    movl sriov_cap, %eax
    call puthex
    movl $sp_ms, %esi
    call puts
    movl vf_msix, %eax
    call puthex
    movl $sp_ce, %esi
    call puts
    movl ctrl_echo, %eax
    call puthex
    movl $sp_sb, %esi
    call puts
    movl sec_bus, %eax
    call puthex
    movl $sp_d1, %esi
    call puts
    movl devf1, %eax
    call puthex
    movl $sp_d2, %esi
    call puts
    movl devf2, %eax
    call puthex
    movl $sp_d3, %esi
    call puts
    movl devf3, %eax
    call puthex
    movl $sp_vd, %esi
    call puts
    movl vf_dis, %eax
    call puthex
    movl $sp_cb, %esi
    call puts
    movl cap1, %eax
    call puthex
    movl $sp_c2, %esi
    call puts
    movl cap2, %eax
    call puthex
    movl $sp_c3, %esi
    call puts
    movl cap3, %eax
    call puthex
    movl $sp_c4, %esi
    call puts
    movl cap4, %eax
    call puthex
    movl $sp_c5, %esi
    call puts
    movl cap5, %eax
    call puthex
    movl $sp_c6, %esi
    call puts
    movl cap6, %eax
    call puthex
    movl $sp_vo, %esi
    call puts
    movl vf_off, %eax
    call puthex
    movl $sp_vb, %esi
    call puts
    movl vf_bad, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* cfgread32b: esi=bus, edi=devfn, ecx=byteoff -> eax
 * (clobbers ebx, ecx, edx) */
cfgread32b:
    movl $0x80000000, %eax
    movl %esi, %ebx
    shll $16, %ebx
    orl %ebx, %eax
    movl %edi, %ebx
    shll $8, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    inl %edx, %eax
    ret

/* cfgwrite32b: esi=bus, edi=devfn, ecx=byteoff, ebp=val
 * (clobbers eax, ebx, edx) */
cfgwrite32b:
    movl $0x80000000, %eax
    movl %esi, %ebx
    shll $16, %ebx
    orl %ebx, %eax
    movl %edi, %ebx
    shll $8, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    movl %ebp, %eax
    outl %eax, %edx
    ret

/* ecamread32: esi=bus, edi=devfn, ecx=byteoff -> eax.  The CF8/CFC
 * mechanism only addresses the first 256 config bytes; extended
 * config (>= 0x100, e.g. the SR-IOV capability) is read through the
 * ECAM MMIO window at 0xb0000000 (q35 MCH). */
ecamread32:
    movl $0xb0000000, %eax
    movl %esi, %ebx
    shll $20, %ebx
    orl %ebx, %eax
    movl %edi, %ebx
    shll $12, %ebx
    orl %ebx, %eax
    andl $0xfff, %ecx
    orl %ecx, %eax
    movl %eax, %esi
    movl (%esi), %eax
    ret

/* ecamwrite32: esi=bus, edi=devfn, ecx=byteoff, ebp=val */
ecamwrite32:
    movl $0xb0000000, %eax
    movl %esi, %ebx
    shll $20, %ebx
    orl %ebx, %eax
    movl %edi, %ebx
    shll $12, %ebx
    orl %ebx, %eax
    andl $0xfff, %ecx
    orl %ecx, %eax
    movl %eax, %esi
    movl %ebp, (%esi)
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
sec_bus:   .long 0
pf_dev:    .long 0
sriov_cap: .long 0
vf_msix:   .long 0
ctrl_echo: .long 0
wrval:     .long 0
cap1:      .long 0
cap2:      .long 0
cap3:      .long 0
cap4:      .long 0
cap5:      .long 0
cap6:      .long 0
devf1:     .long 0
devf2:     .long 0
devf3:     .long 0
vf_dis:    .long 0
vf_off:    .long 0
vf_bad:    .long 0
fail:      .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:     .asciz "SRIOV "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_pf:   .asciz " pf="
sp_ca:   .asciz " cap="
sp_ms:   .asciz " msix="
sp_ce:   .asciz " ctrl="
sp_sb:   .asciz " sec="
sp_d1:   .asciz " d1="
sp_d2:   .asciz " d2="
sp_d3:   .asciz " d3="
sp_vd:   .asciz " vdis="
sp_cb:   .asciz " c1="
sp_c2:   .asciz " c2="
sp_c3:   .asciz " c3="
sp_c4:   .asciz " c4="
sp_c5:   .asciz " c5="
sp_c6:   .asciz " c6="
sp_vo:   .asciz " voff="
sp_vb:   .asciz " vbad="
nl:      .asciz "\n"
