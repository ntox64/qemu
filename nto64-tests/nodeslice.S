/* SPDX-License-Identifier: BSD-2-Clause */

/* nodeslice.S - freestanding multiboot test for a node's own slice
 * staying direct RAM when a node holds more than one vCPU, and for the
 * slice boundaries following the ACPI node ranges when RAM spills
 * above 4G.
 *
 *   (default) -machine q35,nto64-per-cpu-ram=on,nto64-numa-cores-per-node=2 \
 *             -smp 4 -m 128
 *
 * Two nodes of 64 MiB each: node 0 owns [0, 64M) (so the low RAM the
 * AP boots in), node 1 owns [64M, 128M).  APIC 1 is a vCPU of node 0,
 * which puts node id and cpu_index out of step - the case the slice
 * ownership has to get right.  The AP hammers its own node first and
 * the other node second, and the BSP reads the interconnect's slice
 * counters (ctrl 0x28/0x2c) around each pass:
 *   - own node: both deltas must be exactly 0 (direct RAM, no hook);
 *   - other node: both deltas must cover the AP's 4096 accesses;
 *   - a non-RAM MMIO window *inside* the slice range (the VGA low
 *     window at 0xA0000-0xBFFFF, well inside node 0's slice): it has to
 *     stay a device window.  Turning it into instrumented RAM is wrong,
 *     and with nothing behind the region to hand back
 *     (memory_region_get_ram_ptr() asserts on a region with no RAMBlock)
 *     it aborts the host.
 * A test that only ran on the BSP could not see this: cpu 0 is node 0,
 * where the node id is the cpu_index and both spellings agree.
 *
 * NTO64_NODESLICE_BIG (-DNTO64_NODESLICE_BIG, `make run-nodeslicebig`)
 * keeps the same shape but makes RAM spill above 4G: -m 3G leaves 2 GiB
 * below 4G, while the node slices are 1.5 GiB.  node 0's own memory
 * therefore reaches past one span/2 slice ([0, 1.5G) of the ACPI
 * tables, not [0, 1G)), and the AP's own-node buffer sits in the window
 * where dividing the low span instead of the RAM shifts the boundary -
 * the exact-count assertion then catches a node 0 access being called
 * remote (and node 1's memory local).
 *
 * NTO64_MMIO_ONLY (-DNTO64_MMIO_ONLY, `make run-nodeslicemmio`) runs
 * with one vCPU per node (-smp 2), so APIC 1 is node 1.  The AP first
 * touches node 0's RAM - which must be counted, proving the range
 * lookup really does see node 0 as another node for this vCPU - and
 * then reads the VGA window at 0xB8000, which lies in that same node 0
 * range and must stay plain MMIO: no slice access, no host abort.  In
 * the default build APIC 1 is node 0 and both windows are local, so
 * that pass proves nothing there.
 *
 * Prints 'NODESLICE lrd=... lwr=... rrd=... rwr=... mrd=... mwr=...
 * srd=... swr=... mv=... f=...' (srd/swr are the deltas the AP itself
 * measured around the MMIO reads) to COM1 and halts.  Build:
 * `make nodeslice` (also `nodeslice-big`, `nodeslice-mmio`), run:
 * `make run-nodeslice` (also `run-nodeslicebig`, `run-nodeslicemmio`).
 */
    .code32
    .section .multiboot,"ax",@progbits
    .align 4
    .long 0x1BADB002
    .long 0
    .long -0x1BADB002

#define TRAMP       0x8000
#define AP_GDT      0x8040
#define AP_GDTD     0x8060
#define AP_SLOT     0x9100      /* handshake flags */
#define AP_READY    0x9100
#define AP_GO       0x9104
#define AP_LOCAL    0x9108
#define AP_REMOTE   0x910c
#define AP_MMIO     0x9110
#define AP_SRD      0x9114      /* slice-read delta the AP measured */
#define AP_SWR      0x9118      /* slice-write delta the AP measured */
#define IDT_BASE    0x8800
#define IDT_DESC    0x9800
#define LAPIC       0xfee00000
#define CTRL        0xdf100000  /* interconnect control registers */
#define CTRL_SRD    0x28
#define CTRL_SWR    0x2c
#if defined(NTO64_NODESLICE_BIG)
/* -m 3G, 2 nodes: node 0 = [0, 1.5G), node 1 = [1.5G, 2G) below 4G.
 * The own-node buffer sits above the old span/2 = 1G boundary, in the
 * window a low-span division would hand to node 1. */
#define LOCAL_BUF   0x50000000  /* 1.25 GiB: node 0, past the 1G mark */
#define REMOTE_BUF  0x70000000  /* 1.75 GiB: node 1 */
#elif defined(NTO64_MMIO_ONLY)
/* -m 128, one vCPU per node: the AP is node 1, so node 0's slice is
 * the foreign one (and holds the VGA window probed below). */
#define REMOTE_BUF  0x02000000  /* 32 MiB: node 0, foreign to the AP */
#define LOCAL_BUF   0x04000000  /* 64 MiB: node 1, the AP's own */
#else
#define LOCAL_BUF   0x00200000  /* node 0 (the AP's own node) */
#define REMOTE_BUF  0x04000000  /* node 1's slice with 2 x 64 MiB */
#endif
#define MMIO_VGA    0x000b8000  /* vga-lowmem: i/o, not RAM, in node 0 */
#define PASSES      4096

    .section .text
    .globl _start
_start:
    movl $stack_top, %esp
    andl $-16, %esp
    call build_idt
    lidt IDT_DESC
    call ap_bringup
    cmpl $0, AP_READY
    jne 1f
    incl fail                       /* timeout already counted by bringup */
    jmp report

#ifndef NTO64_MMIO_ONLY
    /* pass 1: the AP touches its own node.  Snapshot the counters, let
     * the AP run, and require that nothing moved: for a vCPU of node 0
     * the whole low slice is direct RAM. */
1:  movl CTRL+CTRL_SRD, %eax
    movl %eax, rd0
    movl CTRL+CTRL_SWR, %eax
    movl %eax, wr0
    movl $1, AP_GO
    movl $1000000000, %ecx
2:  cmpl $0, AP_LOCAL
    jne 3f
    decl %ecx
    jnz 2b
    incl fail                       /* AP never finished its own-node pass */
    jmp report
3:  movl CTRL+CTRL_SRD, %eax
    subl rd0, %eax
    movl %eax, rd_local
    movl CTRL+CTRL_SWR, %eax
    subl wr0, %eax
    movl %eax, wr_local
#endif

    /* pass 2: the AP touches a slice that is not its own.  Every one of
     * its accesses has to be counted (and delayed) by the hook.  In the
     * MMIO_ONLY build (the AP is node 1) this is node 0's RAM, and it is
     * also the control that makes pass 3 meaningful: it shows the same
     * range resolution calls the region holding the VGA window foreign
     * for this vCPU. */
1:
    movl CTRL+CTRL_SRD, %eax
    movl %eax, rd1
    movl CTRL+CTRL_SWR, %eax
    movl %eax, wr1
    movl $2, AP_GO
    movl $1000000000, %ecx
4:  cmpl $0, AP_REMOTE
    jne 5f
    decl %ecx
    jnz 4b
    incl fail
    jmp report
5:  movl CTRL+CTRL_SRD, %eax
    subl rd1, %eax
    movl %eax, rd_remote
    movl CTRL+CTRL_SWR, %eax
    subl wr1, %eax
    movl %eax, wr_remote

    /* pass 3: a device window that lives inside a slice range.  The AP
     * reads the VGA text window (0xB8000, i/o space in node 0's slice):
     * reading it must not crash the host (there is no RAMBlock behind
     * it) and must not be counted as a slice access, per access or at
     * all - unlike the 4096 counted accesses pass 2 requires.  The
     * window is bracketed by the AP itself (ctrl reads are MMIO and do
     * not count): its own delta is exactly 0, while the BSP-side delta
     * would also pick up the AP's flag polls in the builds where those
     * are foreign. */
    movl CTRL+CTRL_SRD, %eax
    movl %eax, rd2
    movl CTRL+CTRL_SWR, %eax
    movl %eax, wr2
    movl $3, AP_GO
    movl $1000000000, %ecx
6:  cmpl $0, AP_MMIO
    jne 7f
    decl %ecx
    jnz 6b
    incl fail
    jmp report
7:  movl CTRL+CTRL_SRD, %eax
    subl rd2, %eax
    movl %eax, rd_mmio
    movl CTRL+CTRL_SWR, %eax
    subl wr2, %eax
    movl %eax, wr_mmio

    /* the data the AP wrote has to be visible to the BSP (the slice
     * hook counts and delays; the access itself stays coherent RAM) */
#ifndef NTO64_MMIO_ONLY
    cmpl $0x11111111, LOCAL_BUF
    je 8f
    incl fail
#endif
8:  cmpl $0x22222222, REMOTE_BUF
    je 9f
    incl fail

    /* the assertions: the AP's own node = not counted at all, the other
     * node = counted per access (the exact-count gate is off, so a few
     * extra first-touch counts are allowed on the foreign side only),
     * and the foreign node's MMIO window = never a slice access */
#ifndef NTO64_MMIO_ONLY
9:
    cmpl $0, rd_local
    je 10f
    incl fail
10: cmpl $0, wr_local
    je 11f
    incl fail
#else
9:
#endif
11: cmpl $PASSES, rd_remote
    jae 12f
    incl fail
12: cmpl $PASSES, wr_remote
    jae 13f
    incl fail
13: cmpl $0xcafe, AP_MMIO
    je 14f
    incl fail
14: cmpl $0, AP_SRD
    je 15f
    incl fail
15: cmpl $0, AP_SWR
    je report
    incl fail

report:
    movl $msg, %esi
    call puts
    movl $sp_lrd, %esi
    call puts
    movl rd_local, %eax
    call puthex
    movl $sp_lwr, %esi
    call puts
    movl wr_local, %eax
    call puthex
    movl $sp_rrd, %esi
    call puts
    movl rd_remote, %eax
    call puthex
    movl $sp_rwr, %esi
    call puts
    movl wr_remote, %eax
    call puthex
    movl $sp_mrd, %esi
    call puts
    movl rd_mmio, %eax
    call puthex
    movl $sp_mwr, %esi
    call puts
    movl wr_mmio, %eax
    call puthex
    movl $sp_srd, %esi
    call puts
    movl AP_SRD, %eax
    call puthex
    movl $sp_swr, %esi
    call puts
    movl AP_SWR, %eax
    call puthex
    movl $sp_mv, %esi
    call puts
    movl AP_MMIO, %eax
    call puthex
    movl $sp_loc, %esi
    call puts
    movl LOCAL_BUF, %eax
    call puthex
    movl $sp_rem, %esi
    call puts
    movl REMOTE_BUF, %eax
    call puthex
    movl $sp_bad, %esi
    call puts
    movl bad_exc, %eax
    call puthex
    movl $sp_f, %esi
    call puts
    movl fail, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
12: hlt
    jmp 12b

/* ap_bringup: copy the trampoline to 0x8000, build the GDT, INIT +
 * SIPI to APIC 1, wait for AP_READY. */
ap_bringup:
    movl $ap_tramp, %esi
    movl $TRAMP, %edi
    movl $ap_tramp_end, %ecx
    subl $ap_tramp, %ecx
1:  movb (%esi), %al
    movb %al, (%edi)
    incl %esi
    incl %edi
    decl %ecx
    jnz 1b

    movl $0, AP_GDT
    movl $0, AP_GDT+4
    movl $0x0000ffff, AP_GDT+8
    movl $0x00cf9a00, AP_GDT+12
    movl $0x0000ffff, AP_GDT+16
    movl $0x00cf9200, AP_GDT+20
    movw $23, AP_GDTD
    movl $AP_GDT, AP_GDTD+2
    movl $0, AP_GDTD+6

    movl $LAPIC, %eax
    movl $1 << 24, 0x310(%eax)
    movl $0x00004500, 0x300(%eax)
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax)
    call ap_delay
    movl $1 << 24, 0x310(%eax)
    movl $0x00004608, 0x300(%eax)

    movl $1000000000, %ecx
1:  movl AP_READY, %eax
    testl %eax, %eax
    jnz 2f
    decl %ecx
    jnz 1b
    movl $msg_ap, %esi
    call puts
    incl fail
2:  ret

ap_delay:
    movl $100000, %ecx
1:  decl %ecx
    jnz 1b
    ret

/* AP trampoline: 16-bit real mode -> protected mode 32, then the two
 * access passes.  The BSP opens each pass through AP_GO so the counter
 * snapshots bracket exactly one pass. */
    .code16
ap_tramp:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7f00, %sp
    lgdtl AP_GDTD
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long ap_entry32
    .word 0x08
ap_tramp_end:
    .code32

ap_entry32:
    movl $0x10, %eax
    movl %eax, %ds
    movl %eax, %es
    movl %eax, %ss
    lidt IDT_DESC
    movl $0, AP_GO
    movl $0, AP_LOCAL
    movl $0, AP_REMOTE
    movl $0, AP_MMIO
    movl $1, AP_READY

#ifndef NTO64_MMIO_ONLY
    /* pass 1: own node - must be plain direct RAM for this vCPU */
1:  cmpl $1, AP_GO
    je 2f
    cmpl $2, AP_GO
    je 5f                    /* the BSP gave up on pass 1 */
    jmp 1b
2:  movl $LOCAL_BUF, %edi
    movl $PASSES, %ecx
    movl $0x11111111, %eax
3:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 3b
    movl $1, AP_LOCAL

    /* pass 2: the other node's slice - every access must be hooked */
4:  cmpl $2, AP_GO
    je 5f
    jmp 4b
#else
    /* the AP is a vCPU of node 1 here, so its handshake writes are
     * foreign and the pass-1 exact-zero rule cannot hold; run only the
     * foreign-node pass and the MMIO probe, both opened by the BSP */
1:  cmpl $2, AP_GO
    je 5f
    jmp 1b
#endif
5:  movl $REMOTE_BUF, %edi
    movl $PASSES, %ecx
    movl $0x22222222, %eax
6:  movl %eax, (%edi)
    addl $4, %edi
    decl %ecx
    jnz 6b
    movl $REMOTE_BUF, %edi
    movl $PASSES, %ecx
7:  movl (%edi), %eax
    addl $4, %edi
    decl %ecx
    jnz 7b
    movl $1, AP_REMOTE

    /* pass 3: a device window inside node 0's slice (read only: it is
     * the VGA text buffer, and this guest has no VGA state to disturb) */
8:  cmpl $3, AP_GO
    je 9f
    jmp 8b
9:  movl CTRL+CTRL_SRD, %ebx     /* the AP's own before/after window */
    movl CTRL+CTRL_SWR, %ebp
    movl $PASSES, %ecx
10: movl MMIO_VGA, %eax
    decl %ecx
    jnz 10b
    movl CTRL+CTRL_SRD, %eax
    movl CTRL+CTRL_SWR, %edx     /* both samples before either store */
    subl %ebx, %eax
    subl %ebp, %edx
    movl %eax, AP_SRD
    movl %edx, AP_SWR
    movl $0xcafe, AP_MMIO
1:  hlt
    jmp 1b

/* build_idt: 256 entries at IDT_BASE, all -> bad_handler, with the
 * pseudo-descriptor at IDT_DESC.  Any exception in the AP's access
 * passes (a #PF would mean the slice is not mapped) reports instead of
 * triple-faulting. */
build_idt:
    movl $IDT_BASE, %edi
    movl $bad_handler, %eax
    movl $256, %ecx
1:  movw %ax, 0(%edi)
    movw $0x08, 2(%edi)
    movl $0, 4(%edi)
    movb $0x8e, 5(%edi)
    shrl $16, %eax
    movw %ax, 6(%edi)
    movl $bad_handler, %eax
    addl $8, %edi
    decl %ecx
    jnz 1b
    movw $0x7ff, IDT_DESC
    movl $IDT_BASE, IDT_DESC+2
    movl $0, IDT_DESC+6
    ret

bad_handler:
    movl $1, bad_exc
    incl fail
    jmp report

/* puts / puthex / putc - same console helpers as the other tests */
puts:
    movzbl (%esi), %eax
    testb %al, %al
    jz 2f
    call putc
    incl %esi
    jmp puts
2:  ret

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
rd0:       .long 0
wr0:       .long 0
rd1:       .long 0
wr1:       .long 0
rd_local:  .long 0
wr_local:  .long 0
rd_remote: .long 0
wr_remote: .long 0
rd2:       .long 0
wr2:       .long 0
rd_mmio:   .long 0
wr_mmio:   .long 0
bad_exc:   .long 0
fail:      .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:       .asciz "NODESLICE"
msg_ap:    .asciz " AP-TIMEOUT"
sp_lrd:    .asciz " lrd="
sp_lwr:    .asciz " lwr="
sp_rrd:    .asciz " rrd="
sp_rwr:    .asciz " rwr="
sp_mrd:    .asciz " mrd="
sp_mwr:    .asciz " mwr="
sp_srd:    .asciz " srd="
sp_swr:    .asciz " swr="
sp_mv:     .asciz " mv="
sp_loc:    .asciz " loc="
sp_rem:    .asciz " rem="
sp_bad:    .asciz " bad="
sp_f:      .asciz " f="
nl:        .asciz "\n"
