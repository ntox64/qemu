/* SPDX-License-Identifier: BSD-2-Clause */

/* numatest.S - freestanding multiboot test for the ACPI NUMA exposure
 *: with -machine nto64-per-cpu-ram=on, QEMU auto-derives one
 * NUMA node per vCPU from the whole-RAM slice shape and emits SRAT +
 * SLIT through the stock ACPI builder (firmware only installs the
 * tables).  This guest finds RSDP by sweeping the full low 1MB
 * (EBDA, the 0xE0000-0xFFFFF FSEG zone where QEMU's ACPI linker
 * loader installs the RSDP, BIOS area, ...) and then the rest of
 * low memory up to the multiboot-reported RAM top, walks RSDT to
 * SRAT/SLIT, and validates the topology for the standard invocation:
 *
 *   -machine q35,nto64-per-cpu-ram=on -smp 2 -m 128
 *
 * Expected: 2 nodes; cpu 0 -> node 0, cpu 1 -> node 1; memory
 * affinity node 0 = [0,0xA0000) + [0x100000,0x4000000) (the 640K hole
 * cuts node 0's slice, low/BIOS memory is node 0's slice) and node 1 =
 * [0x4000000,0x8000000); SLIT 10 / EXPECT_REMOTE (default 20, built
 * with -DEXPECT_REMOTE for the distance-variant run).  Zero-length
 * padding entries and disabled affinities are skipped.
 * Prints to COM1, halts.  Build: `make numatest`, run:
 * `make run-numatest` (or numadisttest with nto64-numa-distance=40).
 */
#ifndef EXPECT_REMOTE
#define EXPECT_REMOTE 20
#endif

    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002          /* multiboot magic */
    .long 0                   /* flags */
    .long -0x1BADB002         /* checksum */

    .section .text
    .globl _start
_start:
    movl $0, fail
    /* ram_top from the multiboot info (MBI at 0x9500, e820 at 0x9000):
     * mem_upper is in KB above the 1MB mark (flags bit 0 = memory
     * fields valid) and EXCLUDES the firmware-reserved window at the
     * top of RAM where SeaBIOS places the ACPI tables, so extend the
     * scan by a 1MB margin.  Guards the RSDP scan range. */
    movl $0x9500, %esi
    movl (%esi), %eax
    testl $1, %eax
    jz 91f
    movl $0x9508, %esi
    movl (%esi), %eax
    shll $10, %eax
    addl $0x100000, %eax
    movl %eax, ram_top
91: addl $0x100000, ram_top
    call find_rsdp
    testl %eax, %eax
    jz 90f                    /* no RSDP -> fail and report */
    movl 16(%eax), %eax       /* RSDT physical address (RSDP v1) */
    movl %eax, rsdt
    testl %eax, %eax
    jz 90f
    /* walk the RSDT entries for SRAT and SLIT */
    movl rsdt, %ebx
    cmpl $0x54445352, (%ebx)  /* "RSDT" */
    jne 90f
    movl 4(%ebx), %ecx        /* table length */
    subl $36, %ecx
    shrl $2, %ecx             /* entry count */
    leal 36(%ebx), %esi
walk_loop:
    testl %ecx, %ecx
    jz walk_done
    movl (%esi), %eax         /* entry: physical address of a table */
    testl %eax, %eax
    jz 2f
    cmpl $0x54415253, (%eax)  /* "SRAT" */
    jne 1f
    movl %eax, srat
1:  cmpl $0x54494c53, (%eax)  /* "SLIT" */
    jne 2f
    movl %eax, slit
2:  addl $4, %esi
    decl %ecx
    jmp walk_loop
walk_done:
    cmpl $0, srat
    je 90f
    cmpl $0, slit
    je 90f
    call parse_srat
    call parse_slit
    jmp report
90: incl fail

report:
    movl $msg, %esi
    call puts
    movl $sp_nodes, %esi
    call puts
    movl n_cpu, %eax
    call putdec
    movl $sp_cpu, %esi
    call puts
    /* print "apic:node,apic:node" */
    movl $0, %ebp
1:  cmpl n_cpu, %ebp
    jae 2f
    movl cpu_apic(,%ebp,4), %eax
    call putdec
    movl $sp_colon, %esi
    call puts
    movl cpu_node(,%ebp,4), %eax
    call putdec
    incl %ebp
    cmpl n_cpu, %ebp
    jae 2f
    movl $sp_comma, %esi
    call puts
    jmp 1b
2:  movl $sp_mem, %esi
    call puts
    movl n_mem, %eax
    call putdec
    movl $sp_slit, %esi
    call puts
    movl slit00, %eax
    call putdec
    movl $sp_comma, %esi
    call puts
    movl slit01, %eax
    call putdec
    movl $sp_comma, %esi
    call puts
    movl slit10, %eax
    call putdec
    movl $sp_comma, %esi
    call puts
    movl slit11, %eax
    call putdec
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* find_rsdp: sweep the full low 1MB (16-byte aligned - covers the
 * EBDA, the FSEG zone where QEMU's ACPI linker loader installs the
 * RSDP, and the BIOS area), then the rest of low memory up to
 * ram_top, for "RSD PTR ".  Returns the RSDP address in eax (0 if
 * not found). */
find_rsdp:
    xorl %esi, %esi
1:  cmpl $0x00100000, %esi
    jae 2f
    cmpl $0x20445352, (%esi)  /* "RSD PTR " */
    je 10f
    addl $16, %esi
    jmp 1b
2:  /* scan the rest of low memory (0x100000 .. ram_top) */
    cmpl ram_top, %esi
    jae 8f
    cmpl $0x20445352, (%esi)
    je 10f
    addl $16, %esi
    jmp 2b
10: /* candidate: verify "PTR " and the ACPI 1.0 checksum (bytes 0-19
     * must sum to zero, ACPI 6.6 Table 5.3) before accepting it. */
    cmpl $0x20525450, 4(%esi)  /* "PTR " */
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

/* parse_srat: walk the SRAT entries; type 0 (LAPIC affinity, 16 B) and
 * type 1 (memory affinity, 40 B) with the enabled flag set are
 * validated against the -smp 2 -m 128 layout; type 2 (x2APIC) enabled
 * entries are unexpected at < 255 APIC ids and fail.  Counts land in
 * n_cpu / n_mem, pairs in cpu_apic[]/cpu_node[]. */
parse_srat:
    movl srat, %esi
    movl 4(%esi), %ecx        /* table length */
    leal 48(%esi), %esi       /* 36-byte header + 12 reserved bytes */
    addl %ecx, %esi
    movl %esi, srat_end
    movl srat, %esi
    leal 48(%esi), %esi
    xorl %edi, %edi           /* enabled cpu affinity count */
    xorl %ebx, %ebx           /* enabled memory entry index */
loop:
    cmpl srat_end, %esi
    jae done
    movzbl 0(%esi), %eax
    movzbl 1(%esi), %ebp      /* entry length (preserved across types) */
    testl %ebp, %ebp
    jz done                   /* malformed zero-length entry: stop */
    cmpl $0, %eax
    je lapic
    cmpl $1, %eax
    je mem
    cmpl $2, %eax
    je x2
    jmp skip
mem:
    movl 28(%esi), %eax       /* flags */
    testl $1, %eax
    jz skip
    movl 16(%esi), %eax       /* length low */
    testl %eax, %eax
    jz skip                   /* zero-length padding */
    cmpl $0, %ebx
    je mem0
    cmpl $1, %ebx
    je mem1
    cmpl $2, %ebx
    je mem2
    incl fail                 /* more memory entries than expected */
    jmp mem_next
mem0:
    cmpl $0x00000000, 8(%esi) /* base low */
    jne mem_bad
    cmpl $0x000a0000, 16(%esi) /* length low */
    jne mem_bad
    cmpl $0, 2(%esi)          /* proximity domain */
    jne mem_bad
    jmp mem_next
mem1:
    cmpl $0x00100000, 8(%esi)
    jne mem_bad
    cmpl $0x03f00000, 16(%esi)
    jne mem_bad
    cmpl $0, 2(%esi)
    jne mem_bad
    jmp mem_next
mem2:
    cmpl $0x04000000, 8(%esi)
    jne mem_bad
    cmpl $0x04000000, 16(%esi)
    jne mem_bad
    cmpl $1, 2(%esi)
    jne mem_bad
    jmp mem_next
mem_bad:
    incl fail
mem_next:
    incl %ebx
    jmp skip
x2:
    movl 12(%esi), %eax        /* flags */
    testl $1, %eax
    jz skip
    incl fail                  /* x2APIC affinity unexpected here */
    jmp skip
lapic:
    movl 4(%esi), %eax         /* flags */
    testl $1, %eax
    jz skip
    cmpl $8, %edi
    jae lapic_bad
    movzbl 3(%esi), %eax       /* apic id */
    movzbl 2(%esi), %edx       /* proximity domain */
    movl %eax, cpu_apic(,%edi,4)
    movl %edx, cpu_node(,%edi,4)
    cmpl %edi, %eax
    jne lapic_bad
    cmpl %edi, %edx
    jne lapic_bad
    jmp lapic_next
lapic_bad:
    incl fail
lapic_next:
    incl %edi
skip:
    addl %ebp, %esi
    jmp loop
done:
    movl %edi, n_cpu
    movl %ebx, n_mem
    cmpl $2, %edi
    je 1f
    incl fail
1:  cmpl $3, %ebx
    je 2f
    incl fail
2:  ret

/* parse_slit: expect 2 nodes; validate and save the 2x2 matrix
 * (10 / EXPECT_REMOTE). */
parse_slit:
    movl slit, %esi
    movl 36(%esi), %eax       /* number of nodes (low 32 bits) */
    cmpl $2, %eax
    je 1f
    incl fail
1:  leal 44(%esi), %esi
    movzbl 0(%esi), %eax
    movl %eax, slit00
    movzbl 1(%esi), %eax
    movl %eax, slit01
    movzbl 2(%esi), %eax
    movl %eax, slit10
    movzbl 3(%esi), %eax
    movl %eax, slit11
    cmpl $10, slit00
    jne 2f
    cmpl $EXPECT_REMOTE, slit01
    jne 2f
    cmpl $EXPECT_REMOTE, slit10
    jne 2f
    cmpl $10, slit11
    je 3f
2:  incl fail
3:  ret

/* puts: esi = string */
puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %esi
    jmp puts
2:  ret

/* putdec: eax as unsigned decimal */
putdec:
    movl %eax, %ecx
    xorl %edi, %edi           /* digit count */
    testl %ecx, %ecx
    jnz 1f
    movl $'0', %eax
    call putc
    ret
1:  xorl %edx, %edx
    movl $10, %ebx
    divl %ebx                 /* edx = digit, eax = quotient */
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

/* puthex: eax as 8 hex digits */
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
fail: .long 0
rsdt: .long 0
srat: .long 0
slit: .long 0
srat_end: .long 0
ram_top: .long 0
n_cpu: .long 0
n_mem: .long 0
cpu_apic: .fill 8,4,0
cpu_node: .fill 8,4,0
slit00: .long 0
slit01: .long 0
slit10: .long 0
slit11: .long 0

    .section .rodata
msg: .asciz "NUMA"
sp_nodes: .asciz " nodes="
sp_cpu: .asciz " cpu="
sp_colon: .asciz ":"
sp_comma: .asciz ","
sp_mem: .asciz " mem="
sp_slit: .asciz " slit="
sp_f: .asciz " f="
nl: .asciz "\n"
