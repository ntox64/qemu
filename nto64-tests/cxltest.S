/* SPDX-License-Identifier: BSD-2-Clause */

/* cxltest.S - freestanding multiboot test for the CXL.mem tier
 * exposure.
 *
 * With -machine q35,cxl=on (plus a pxb-cxl host bridge, cxl-rp root
 * port and cxl-type3 volatile device) QEMU emits the CXL Early
 * Discovery Table (CEDT) through the stock ACPI builder: a CHBS
 * record for the host bridge and a CFMWS record describing the fixed
 * memory window that maps the type-3 device's volatile memory above
 * 4 GiB as a distinct memory tier (outside the nto64 DRAM slices).
 * This guest reuses 's RSDP sweep + RSDT walk, finds the CEDT
 * and validates the CHBS/CFMWS geometry:
 *
 *   CHBS  uid=12 ver=1 base=0x100000000 len=0x10000
 *   CFMWS base=0x110000000 size=0x20000000 ways=1 gran=0
 *         restrictions=0x0f target=12
 *
 * Run (make run-cxltest): -machine q35,nto64-per-cpu-ram=on,cxl=on,
 *   cxl-fmw.0.targets.0=cxl.0,cxl-fmw.0.size=512M,
 *   cxl-fmw.0.interleave-granularity=256 -m 2G -smp 2
 *   -object memory-backend-ram,size=512M,id=cxlmem0
 *   -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.0
 *   -device cxl-rp,port=0,bus=cxl.0,id=root_port0,chassis=0,slot=0
 *   -device cxl-type3,bus=root_port0,volatile-memdev=cxlmem0,id=cxl0
 *
 * The FM window lives above 4 GiB (q35 always places the CXL range
 * above the 4 GiB boundary), so a 32-bit guest validates the tier via
 * ACPI geometry; accessing the window itself is long-mode/kernel work
 * (the nto64  tiering phase).
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
    movl $0, fail

    /* ram_top from the multiboot MBI (0x9500): mem_upper + 1MB + a
     * 1MB margin over the firmware-reserved top-of-RAM window. */
    movl $0x9500, %esi
    movl (%esi), %eax
    testl $1, %eax
    jz 1f
    movl $0x9508, %esi
    movl (%esi), %eax
    shll $10, %eax
    addl $0x100000, %eax
    movl %eax, ram_top
1:  addl $0x100000, ram_top

    call find_rsdp
    testl %eax, %eax
    jz bad
    movl 16(%eax), %eax          /* RSDT (RSDP v1) */
    movl %eax, rsdt
    testl %eax, %eax
    jz bad

    /* walk the RSDT for CEDT */
    movl rsdt, %ebx
    cmpl $0x54445352, (%ebx)     /* "RSDT" */
    jne bad
    movl 4(%ebx), %ecx
    subl $36, %ecx
    shrl $2, %ecx
    leal 36(%ebx), %esi
cedt_scan:
    testl %ecx, %ecx
    jz bad
    movl (%esi), %eax
    testl %eax, %eax
    jz 1f
    cmpl $0x54444543, (%eax)     /* "CEDT" */
    je cedt_found
1:  addl $4, %esi
    decl %ecx
    jmp cedt_scan
cedt_found:
    movl %eax, cedt

    /* walk the CEDT entries (start at offset 36) */
    movl cedt, %esi
    movl 4(%esi), %ecx           /* table length */
    addl %ecx, %esi
    movl %esi, cedt_end
    movl cedt, %esi
    leal 36(%esi), %esi
entry_loop:
    cmpl cedt_end, %esi
    jae walk_done
    movzbl 0(%esi), %eax          /* record type */
    movzwl 2(%esi), %ebp          /* record length */
    testl %ebp, %ebp
    jz walk_done
    cmpl $0, %eax
    je chbs
    cmpl $1, %eax
    je cfmws
    jmp next_entry
chbs:
    /* Type 0: reserved, len, UID(4), version(4), reserved(4),
     * base(8), length(8). */
    movl 4(%esi), %eax
    movl %eax, chbs_uid
    movl 8(%esi), %eax
    movl %eax, chbs_ver
    movl 12(%esi), %eax
    movl %eax, chbs_resv
    movl 16(%esi), %eax
    movl %eax, chbs_base_lo
    movl 20(%esi), %eax
    movl %eax, chbs_base_hi
    movl 24(%esi), %eax
    movl %eax, chbs_len_lo
    movl 28(%esi), %eax
    movl %eax, chbs_len_hi
    incl chbs_count
    jmp next_entry
cfmws:
    /* Type 1: reserved, len, reserved(4), base HPA(8), size(8),
     * ways(1), arithmetic(1), reserved(2), granularity(4),
     * restrictions(2), QTG(2), target list(4 each). */
    movl 8(%esi), %eax
    movl %eax, cf_base_lo
    movl 12(%esi), %eax
    movl %eax, cf_base_hi
    movl 16(%esi), %eax
    movl %eax, cf_size_lo
    movl 20(%esi), %eax
    movl %eax, cf_size_hi
    movzbl 24(%esi), %eax
    movl %eax, cf_ways
    movl 28(%esi), %eax
    movl %eax, cf_gran
    movzwl 32(%esi), %eax
    movl %eax, cf_rest
    movl 36(%esi), %eax
    movl %eax, cf_tgt
    incl cfmws_count
    jmp next_entry
next_entry:
    addl %ebp, %esi
    jmp entry_loop
walk_done:

    /* validate: one CHBS (uid 12, ver 1, base 0x100000000,
     * len 0x10000) and one CFMWS (base 0x110000000, size
     * 0x20000000, 1-way, gran enc 0, restrictions 0x0f,
     * target bus 12).  Each failure ORs a bit into badmask so the
     * report shows exactly which check failed. */
    movl $0, badmask
    movl chbs_count, %eax
    cmpl $1, %eax
    je 1f
    orl $1, badmask
1:  movl chbs_uid, %eax
    cmpl $12, %eax
    je 2f
    orl $2, badmask
2:  movl chbs_ver, %eax
    cmpl $1, %eax
    je 3f
    orl $4, badmask
3:  movl chbs_base_lo, %eax
    testl %eax, %eax
    jnz 4f
    movl chbs_base_hi, %eax
    cmpl $1, %eax
    je 5f
4:  orl $8, badmask
5:  movl chbs_len_lo, %eax
    cmpl $0x00010000, %eax
    jne 6f
    movl chbs_len_hi, %eax
    testl %eax, %eax
    je 7f
6:  orl $16, badmask
7:  movl cfmws_count, %eax
    cmpl $1, %eax
    je 8f
    orl $32, badmask
8:  movl cf_base_lo, %eax
    cmpl $0x10000000, %eax
    jne 9f
    movl cf_base_hi, %eax
    cmpl $1, %eax
    je 10f
9:  orl $64, badmask
10: movl cf_size_lo, %eax
    cmpl $0x20000000, %eax
    jne 11f
    movl cf_size_hi, %eax
    testl %eax, %eax
    je 12f
11: orl $128, badmask
12: movl cf_ways, %eax
    testl %eax, %eax
    jz 13f
    orl $256, badmask
13: movl cf_gran, %eax
    testl %eax, %eax
    jz 14f
    orl $512, badmask
14: movl cf_rest, %eax
    cmpl $0x000f, %eax
    je 15f
    orl $1024, badmask
15: movl cf_tgt, %eax
    cmpl $12, %eax
    je 16f
    orl $2048, badmask
16:
    movl badmask, %eax
    testl %eax, %eax
    jz 17f
    incl fail
17:
    jmp report
bad:
    incl fail

report:
    movl $msg_cxl, %esi
    call puts
    movl $sp_uid, %esi
    call puts
    movl chbs_uid, %eax
    call putdec
    movl $sp_nch, %esi
    call puts
    movl chbs_count, %eax
    call putdec
    movl $sp_ncf, %esi
    call puts
    movl cfmws_count, %eax
    call putdec
    movl $sp_hbb, %esi
    call puts
    movl chbs_base_hi, %eax
    call puthex
    movl chbs_base_lo, %eax
    call puthex
    movl $sp_cfb, %esi
    call puts
    movl cf_base_hi, %eax
    call puthex
    movl cf_base_lo, %eax
    call puthex
    movl $sp_size, %esi
    call puts
    movl cf_size_hi, %eax
    call puthex
    movl cf_size_lo, %eax
    call puthex
    movl $sp_ways, %esi
    call puts
    movl cf_ways, %eax
    call putdec
    movl $sp_gran, %esi
    call puts
    movl cf_gran, %eax
    call putdec
    movl $sp_tgt, %esi
    call puts
    movl cf_tgt, %eax
    call putdec
    movl $sp_bad, %esi
    call puts
    movl badmask, %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
1:  hlt
    jmp 1b

/* find_rsdp: sweep the full low 1MB + reported RAM top for
 * "RSD PTR " (full 8-byte signature + ACPI 1.0 checksum over bytes
 * 0-19).  Returns the RSDP address in eax (0 if not found). */
find_rsdp:
    xorl %esi, %esi
1:  cmpl $0x00100000, %esi
    jae 2f
    cmpl $0x20445352, (%esi)  /* "RSD " */
    je 10f
    addl $16, %esi
    jmp 1b
2:  cmpl ram_top, %esi
    jae 8f
    cmpl $0x20445352, (%esi)
    je 10f
    addl $16, %esi
    jmp 2b
10: cmpl $0x20525450, 4(%esi)  /* "PTR " */
    jne 11f
    movl %esi, %edi
    xorl %eax, %eax
    movl $20, %ecx
12: addb (%edi), %al
    incl %edi
    decl %ecx
    jnz 12b
    testb %al, %al
    jz 9f
11: addl $16, %esi
    jmp 1b
8:  xorl %eax, %eax
    ret
9:  movl %esi, %eax
    ret

/* console helpers */
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

putdec:
    movl %eax, %ecx
    xorl %edi, %edi
    testl %ecx, %ecx
    jnz 1f
    movl $'0', %eax
    call putc
    ret
1:  xorl %edx, %edx
    movl $10, %ebx
    divl %ebx
    pushl %edx
    incl %edi
    testl %eax, %eax
    jnz 1b
2:  popl %eax
    addl $'0', %eax
    call putc
    decl %edi
    jnz 2b
    ret

    .bss
    .balign 16
fail: .long 0
badmask: .long 0
ram_top: .long 0
rsdt: .long 0
cedt: .long 0
cedt_end: .long 0
chbs_count: .long 0
chbs_uid: .long 0
chbs_ver: .long 0
chbs_resv: .long 0
chbs_base_lo: .long 0
chbs_base_hi: .long 0
chbs_len_lo: .long 0
chbs_len_hi: .long 0
cfmws_count: .long 0
cf_base_lo: .long 0
cf_base_hi: .long 0
cf_size_lo: .long 0
cf_size_hi: .long 0
cf_ways: .long 0
cf_gran: .long 0
cf_rest: .long 0
cf_tgt: .long 0

    .section .rodata
msg_cxl: .asciz "CXL"
sp_uid: .asciz " uid="
sp_nch: .asciz " ch="
sp_ncf: .asciz " cf="
sp_hbb: .asciz " hbb="
sp_cfb: .asciz " cfb="
sp_size: .asciz " size="
sp_ways: .asciz " ways="
sp_gran: .asciz " gran="
sp_tgt: .asciz " tgt="
sp_bad: .asciz " bad="
sp_f: .asciz " f="
nl: .asciz "\n"
