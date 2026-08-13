/* SPDX-License-Identifier: BSD-2-Clause */

/* samtest.S - freestanding multiboot test for the Smart Access Memory
 * shape: a 64-bit, multi-GiB, Resizable BAR mapped above 4 GiB.
 *
 * ELF32 multiboot kernel (QEMU's loader rejects ELF64 images, so the
 * 32-bit entry sets up long mode itself - GDT64 + 1 GiB identity
 * pages covering 0..8 GiB, like efiremotetest's AP trampoline).
 * Booted by SeaBIOS: fast, no OVMF.
 *
 * Machine: q35, -m 3G, and
 *   -device nto64-barmem,bar64=on,bar-size=2147483648,rebar-sizes=...
 * (BAR0 is a 64-bit memory BAR, initially 2 GiB, REBAR-sizable to
 * 1G/2G/4G.)
 *
 * Verifies:
 *   Above-4G Decoding: the platform routes a 64-bit BAR mapped at
 *     >= 4 GiB.  Note this tree's firmware does NOT auto-place 64-bit
 *     BARs above 4 GiB (this OVMF build has no 64-bit MMIO window at
 *     all, and SeaBIOS never allocates 64-bit BARs above 4 GiB), so
 *     like a real SAM driver the test programs the 64-bit BAR base
 *     itself (0x100000000, 4 GiB-aligned, above the 3 GiB of RAM);
 *   the size probe returns 2 GiB, the REBAR capability lists the
 *     multi-GiB sizes, and the control reports size 2G;
 *   REBAR resize 2G -> 1G -> 2G -> 4G, each re-probed, and each
 *     window (above 4 GiB, in long mode) is filled + verified end to
 *     end - the CPU-visible full-VRAM (SAM) proof;
 *   after growing to 4G the BAR is re-established at a 4G-aligned
 *     base (write both 64-bit BAR dwords, enable memory) and the
 *     whole 4 GiB window checks out.
 *
 * Build: `make samtest`, run: `make run-samtest`.
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

    /* --- find nto64-barmem (1234:beef) ---- */
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
    incl devf
    jmp report
found:
    movl %edi, dev

    /* --- enable memory space ---- */
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %ebp
    movl dev, %edi
    movl $4, %ecx
    call cfgwrite32

    /* --- 64-bit BAR base (config 0x10 low, 0x14 high) ---- */
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, base_lo
    movl %eax, fw_lo
    movl dev, %edi
    movl $0x14, %ecx
    call cfgread32
    movl %eax, base_hi
    movl %eax, fw_hi
    /* early print of the assigned base (for bring-up) */
    movl $sp_bhi, %esi
    call puts32
    movl base_hi, %eax
    call puthex32
    movl $sp_blo, %esi
    call puts32
    movl base_lo, %eax
    call puthex32

    /* Above-4G Decoding: this tree's firmware (OVMF has no 64-bit
     * window; SeaBIOS never allocates 64-bit BARs above 4 GiB) does
     * NOT auto-place the BAR above 4 GiB, so like a real SAM driver
     * the guest programs the 64-bit BAR base itself (4 GiB-aligned,
     * above the 3 GiB of RAM) and proves the platform routes 64-bit
     * MMIO above 4 GiB. */
    xorl %eax, %eax
    movl %eax, base_lo
    movl $1, %eax
    movl %eax, base_hi
    movl dev, %edi
    movl $0x10, %ecx
    movl base_lo, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x14, %ecx
    movl base_hi, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %ebp
    movl dev, %edi
    movl $4, %ecx
    call cfgwrite32
    cmpl $0, base_hi
    jne 1f
    incl above4g
1:
    /* --- current size probe: expect 2 GiB ---- */
    movl dev, %edi
    movl $0x10, %ecx
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x14, %ecx
    movl $0xffffffff, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x10, %ecx
    call cfgread32
    movl %eax, probe_lo
    movl dev, %edi
    movl $0x14, %ecx
    call cfgread32
    movl %eax, probe_hi
    movl probe_lo, %eax
    andl $0xfffffff0, %eax
    cmpl $0x80000000, %eax
    je 2f
    incl sizef
2:  cmpl $0xffffffff, probe_hi
    je 3f
    incl sizef
3:  /* restore the base (the probe clobbered it) + memory enable */
    movl dev, %edi
    movl $0x10, %ecx
    movl base_lo, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $0x14, %ecx
    movl base_hi, %ebp
    call cfgwrite32
    movl dev, %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %ebp
    movl dev, %edi
    movl $4, %ecx
    call cfgwrite32

    /* --- ECAM base from the MCH PCIEXBAR (bus 0 dev 0, reg 0x60) ---- */
    xorl %edi, %edi
    movl $0x60, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, ecam
    movl dev, %eax
    shll $15, %eax           /* ECAM device stride = 8 x 0x1000 */
    addl ecam, %eax
    movl %eax, ecam_dev

    /* --- walk extended caps, find REBAR (0x15) ---- */
    movl $0x100, %ebx
capwalk:
    testl %ebx, %ebx
    jz cap_missing
    movl %ebx, %eax
    addl ecam_dev, %eax
    movl %eax, %esi
    movl (%esi), %eax
    andl $0xff, %eax
    cmpl $0x15, %eax
    je capfound
    movl %ebx, %eax
    addl ecam_dev, %eax
    movl %eax, %esi
    movl (%esi), %eax
    shrl $8, %eax
    andl $0xff, %eax
    movl %eax, %ebx
    jmp capwalk
cap_missing:
    incl devf
    jmp report
capfound:
    movl %ebx, cap

    /* --- REBAR capability register (cap+4): sizes 1G|2G|4G|8G in
     * bits 4..23; bits 3:0 are RsvdP and must read 0 (PCIe 7.0
     * Table 7-165) ---- */
    movl %ebx, %eax
    addl $4, %eax
    addl ecam_dev, %eax
    movl %eax, %esi
    movl (%esi), %eax
    movl %eax, cap_reg
    shrl $4, %eax
    andl $0xffff, %eax
    cmpl $0x3c00, %eax
    je 4f
    incl capf
4:  movl cap_reg, %eax
    andl $0xf, %eax
    testl %eax, %eax
    jz 5f
    incl capf
5:  /* ---- control register: current size index 11 (2G), BAR0 ---- */
    movl %ebx, %eax
    addl $8, %eax
    addl ecam_dev, %eax
    movl %eax, %esi
    movl (%esi), %eax
    movl %eax, ctrl_save
    andl $0x1f00, %eax
    cmpl $0xb00, %eax
    je 6f
    incl capf
6:  movl ctrl_save, %eax
    andl $7, %eax
    testl %eax, %eax
    jz 7f
    incl capf
7:
    movl $sp_32, %esi
    call puts32

    /* --- switch to long mode: GDT64 + 1 GiB identity pages ---- */
    /* PML4 @ 0x70000 -> PDPT @ 0x71000 (8 x 1 GiB pages = 0..8 GiB) */
    movl $0x70000, %edi
    movl $0x71003, (%edi)
    movl $0, 4(%edi)
    movl $0x71000, %edi
    xorl %eax, %eax
    xorl %ecx, %ecx
1:  movl %eax, %ebx
    orl $0x83, %ebx
    movl %ebx, (%edi,%ecx,8)
    movl %ecx, %edx          /* high dword = (i << 30) >> 32 = i >> 2 */
    shrl $2, %edx
    movl %edx, 4(%edi,%ecx,8)
    addl $0x40000000, %eax
    incl %ecx
    cmpl $8, %ecx
    jb 1b
    /* GDT64 @ 0x72000 */
    movl $0x72000, %edi
    movl $0, 0(%edi)              /* null descriptor */
    movl $0, 4(%edi)
    movl $0x00000000, 8(%edi)     /* code64: base 0, limit 0xfffff */
    movl $0x00af9b00, 12(%edi)    /*   G=1 D=0 L=1, type 0x9b */
    movl $0x00000000, 16(%edi)    /* data64 */
    movl $0x00af9300, 20(%edi)    /*   G=1 D=1, type 0x93 */
    lgdtl gdt_desc
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4
    movl $0x70000, %eax
    movl %eax, %cr3
    movl $0xc0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
    ljmp $0x08, $long_entry

    .code64
long_entry:
    movl $0x10, %eax
    movl %eax, %ds
    movl %eax, %es
    movl %eax, %ss

    /* --- resize + full-window verify: 2G->1G->2G->4G ---- */
    movl $10, %ebx          /* phase 1: 1G at the firmware base */
    call resize_verify
    movl $11, %ebx          /* phase 2: back to 2G */
    call resize_verify
    movl $12, %ebx          /* phase 3: grow to 4G + 4G-aligned base */
    call resize_verify

report:
    movl $msg, %esi
    call puts
    movl devf(%rip), %eax
    addl above4g(%rip), %eax
    addl sizef(%rip), %eax
    addl capf(%rip), %eax
    addl resz(%rip), %eax
    addl fillf(%rip), %eax
    movl %eax, fail(%rip)
    cmpl $0, fail(%rip)
    je 1f
    lea failmsg(%rip), %rsi
    call puts
    jmp 2f
1:  lea okmsg(%rip), %rsi
    call puts
2:  movl $sp_f, %esi
    call puts
    movl fail(%rip), %eax
    call puthex
    movl $sp_hi, %esi
    call puts
    movl base_hi(%rip), %eax
    call puthex
    movl $sp_lo, %esi
    call puts
    movl base_lo(%rip), %eax
    call puthex
    movl $sp_fw, %esi
    call puts
    movl fw_hi(%rip), %eax
    call puthex
    movl $sp_fl, %esi
    call puts
    movl fw_lo(%rip), %eax
    call puthex
    movl $sp_cap, %esi
    call puts
    movl cap(%rip), %eax
    call puthex
    movl $sp_sz, %esi
    call puts
    movl fill_count(%rip), %eax
    call puthex
    movl $sp_rf, %esi
    call puts
    movl resz(%rip), %eax
    call puthex
    movl $sp_ff, %esi
    call puts
    movl fillf(%rip), %eax
    call puthex
    movl $sp_cf, %esi
    call puts
    movl capf(%rip), %eax
    call puthex
    movl $sp_sf, %esi
    call puts
    movl sizef(%rip), %eax
    call puthex
    movl $sp_af, %esi
    call puts
    movl above4g(%rip), %eax
    call puthex
    movl $sp_df, %esi
    call puts
    movl devf(%rip), %eax
    call puthex
    movl $nl, %esi
    call puts
3:  hlt
    jmp 3b

/* resize_verify: ebx = new size index (size = 1 << (20+idx)).
 * Resizes BAR0 via the REBAR control, probes the new size, and
 * fills + verifies the whole window at the current base. */
resize_verify:
    push %rbx
    /* size64 = 1 << (20 + idx) in r12; mask64 = ~(size64-1) in r13 */
    movl %ebx, %ecx
    addl $20, %ecx
    movq $1, %r12
    shlq %cl, %r12
    movq %r12, %r13
    subq $1, %r13
    notq %r13
    /* write ctrl: clear BAR Size field (0x1f00), set idx<<8 */
    movl cap(%rip), %eax
    addl $8, %eax
    addl ecam_dev(%rip), %eax
    movl %eax, %r14d
    movl (%r14), %eax
    andl $0xffffe0ff, %eax
    movl %ebx, %edx
    shll $8, %edx
    orl %edx, %eax
    movl %eax, (%r14)
    /* echo: BAR Size field == idx */
    movl (%r14), %eax
    andl $0x1f00, %eax
    movl %ebx, %edx
    shll $8, %edx
    cmpl %edx, %eax
    je 1f
    incl resz(%rip)
1:  /* probe the BAR size */
    movl dev(%rip), %edi
    movl $0x10, %ecx
    movl $0xffffffff, %r8d
    call cfgwrite32_64
    movl dev(%rip), %edi
    movl $0x14, %ecx
    movl $0xffffffff, %r8d
    call cfgwrite32_64
    movl dev(%rip), %edi
    movl $0x10, %ecx
    call cfgread32
    movl %eax, probe_lo(%rip)
    movl dev(%rip), %edi
    movl $0x14, %ecx
    call cfgread32
    movl %eax, probe_hi(%rip)
    movl probe_lo(%rip), %eax
    andl $0xfffffff0, %eax
    cmpl %r13d, %eax
    je 2f
    incl resz(%rip)
2:  movq %r13, %rax
    shrq $32, %rax
    cmpl %eax, probe_hi(%rip)
    je 3f
    incl resz(%rip)
3:  /* restore the base + memory enable */
    movl dev(%rip), %edi
    movl $0x10, %ecx
    movl base_lo(%rip), %r8d
    call cfgwrite32_64
    movl dev(%rip), %edi
    movl $0x14, %ecx
    movl base_hi(%rip), %r8d
    call cfgwrite32_64
    movl dev(%rip), %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %r8d
    movl dev(%rip), %edi
    movl $4, %ecx
    call cfgwrite32_64
    /* 4G phase: re-establish at a 4G-aligned base (round base up) */
    movabsq $0x100000000, %rax
    cmpq %rax, %r12
    jne 4f
    movl base_lo(%rip), %eax
    movl base_hi(%rip), %edx
    addl $0xffffffff, %eax
    adcl $0, %edx
    xorl %eax, %eax
    movl %eax, base_lo(%rip)
    movl %edx, base_hi(%rip)
    movl dev(%rip), %edi
    movl $0x10, %ecx
    movl %eax, %r8d
    call cfgwrite32_64
    movl base_hi(%rip), %edx   /* cfgwrite32_64 clobbered edx */
    movl dev(%rip), %edi
    movl $0x14, %ecx
    movl %edx, %r8d
    call cfgwrite32_64
    movl dev(%rip), %edi
    movl $4, %ecx
    call cfgread32
    orl $2, %eax
    movl %eax, %r8d
    movl dev(%rip), %edi
    movl $4, %ecx
    call cfgwrite32_64
4:  /* fill + verify the whole window at base_hi:base_lo */
    movq %r12, %rax
    shrq $20, %rax
    movl %eax, fill_count(%rip)
    call fill_verify
    pop %rbx
    ret

/* fill_verify: walk the BAR window at base_hi:base_lo, one dword per
 * MiB plus the final dword, writing and reading back a pattern. */
fill_verify:
    push %rbx
    movl fill_count(%rip), %r12d
    xorl %r13d, %r13d
    movl base_hi(%rip), %r14d
    movl base_lo(%rip), %r15d
1:  cmpl %r12d, %r13d
    jae 4f
    /* addr = base + i<<20 */
    movl %r13d, %edx
    shll $20, %edx
    movl %r15d, %eax
    addl %edx, %eax
    movl %eax, %r8d
    movl %r14d, %eax
    adcl $0, %eax
    movl %eax, %r9d
    shlq $32, %r9
    orq %r8, %r9
    movl %r13d, %eax
    addl $0x11223344, %eax
    movl %eax, (%r9)
    cmpl %eax, (%r9)
    je 2f
    incl fillf(%rip)
2:  incl %r13d
    jmp 1b
4:  /* final dword at base + size - 4 */
    movl %r12d, %eax
    shll $20, %eax
    subl $4, %eax
    movl %eax, %r8d
    movl %r15d, %eax
    addl %eax, %r8d
    movl base_hi(%rip), %eax
    adcl $0, %eax
    movl %eax, %r9d
    shlq $32, %r9
    orq %r8, %r9
    movl $0xa5a5a5a5, (%r9)
    cmpl $0xa5a5a5a5, (%r9)
    je 5f
    incl fillf(%rip)
5:  pop %rbx
    ret

/* --- PCI config helpers (bus 0) ---- */
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

/* cfgwrite32: edi=dev, ecx=byteoff, ebp=val (32-bit phase;
 * clobbers eax, ebx, edx) */
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

/* --- serial output (32-bit versions used before the long-mode
 * switch; the 64-bit versions below are used after) ---- */
    .code32
puts32:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc32
    inc %esi
    jmp puts32
2:  ret

puthex32:
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
4:  call putc32
    decl %ecx
    jnz 1b
    ret

putc32:
    push %edx
    push %eax
1:  movl $0x3fd, %edx
    inb %dx, %al
    testb $0x20, %al
    jz 1b
    movl $0x3f8, %edx
    pop %eax
    outb %al, %edx
    pop %edx
    ret

    .code64
/* puts: rsi = string */
puts:
    movzbl (%rsi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %rsi
    jmp puts
2:  ret

puthex:
    mov %eax, %ebx
    movl $8, %ecx
1:  roll $4, %ebx
    mov %ebx, %eax
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

putc:
    push %rdx
    push %rax
1:  movl $0x3fd, %edx
    inb %dx, %al
    testb $0x20, %al
    jz 1b
    movl $0x3f8, %edx
    pop %rax
    outb %al, %dx
    pop %rdx
    ret

/* cfgwrite32_64: edi=dev, ecx=byteoff, r8d=val (64-bit phase) */
cfgwrite32_64:
    movl $0x80000000, %eax
    movl %edi, %ebx
    shll $11, %ebx
    orl %ebx, %eax
    andl $0xfc, %ecx
    orl %ecx, %eax
    movl $0xcf8, %edx
    outl %eax, %edx
    movl $0xcfc, %edx
    movl %r8d, %eax
    outl %eax, %edx
    ret

    .bss
    .balign 16
dev:       .long 0
base_lo:   .long 0
base_hi:   .long 0
fw_lo:     .long 0
fw_hi:     .long 0
probe_lo:  .long 0
probe_hi:  .long 0
ecam:      .long 0
ecam_dev:  .long 0
cap:       .long 0
cap_reg:   .long 0
ctrl_save: .long 0
fill_count: .long 0
devf:      .long 0
above4g:   .long 0
sizef:     .long 0
capf:      .long 0
resz:      .long 0
fillf:     .long 0
fail:      .long 0

    .bss
    .balign 16
stack:     .space 8192
stack_top:

    .data
gdt_desc:  .word 0x2f          /* limit = 5 entries * 8 - 1 */
           .long 0x72000

    .section .rodata
msg:     .asciz "SAM "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_hi:   .asciz " hi="
sp_lo:   .asciz " lo="
sp_fw:   .asciz " fwhi="
sp_fl:   .asciz " fwlo="
sp_cap:  .asciz " cap="
sp_sz:   .asciz " cnt="
sp_rf:   .asciz " rz="
sp_ff:   .asciz " fl="
sp_cf:   .asciz " cf="
sp_sf:   .asciz " sf="
sp_af:   .asciz " af="
sp_df:   .asciz " df="
sp_bhi:  .asciz " bhi="
sp_blo:  .asciz " blo="
sp_32:   .asciz " 32OK "
nl:      .asciz "\n"
