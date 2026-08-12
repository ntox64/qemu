/* SPDX-License-Identifier: BSD-2-Clause */

/* efiremotetest.S - UEFI (OVMF) test app for nto64-remote: accesses a
 * foreign CPU's RAM through the cross-CPU interconnect and observes
 * the write-behind stale model.
 *
 * Loaded as \EFI\BOOT\BOOTX64.EFI from the FAT image built by
 * fatimg.py.  Runs as a flat 64-bit blob (pewrap.py wraps it in a
 * minimal PE32+ with subsystem EFI_APPLICATION), so it ignores all
 * EFI APIs and just does raw physical accesses + serial output.
 *
 * Test (cpu 0): write own page 0xDF000000 (local, ordered), write
 * foreign page 0xDF001000 via the interconnect (write-behind), read
 * it back immediately -> stale (old) value; wait for the commit-
 * complete IRQ; read again -> new value; print counters.
 *
 * Build: `make efiremotetest`, run: `make run-efiremotetest`.
 */
    .code64
    .text
    .globl _start
_start:
    lea stack_top(%rip), %rsp
    and $-16, %rsp
    call main
1:  hlt
    jmp 1b

main:
    push %rbp
    mov %rsp, %rbp

    /* interconnect control: use the configured delay/jitter
     * (-global nto64-remote.delay-ns=...), irq on commit */
    movl $0xdf100000, %ebp
    movl $4, 0x0c(%ebp)
    movl 0x04(%ebp), %eax
    movl %eax, delay(%rip)

    /* own page: local, ordered */
    movl $0xdf000000, %esi
    movl $0xbeef, (%esi)
    movl (%esi), %eax
    movl %eax, own(%rip)

    /* foreign page (cpu 1) through the interconnect */
    movl $0xdf001000, %edi
    movl $0xcafe, (%edi)
    movl (%edi), %eax
    movl %eax, stale(%rip)

    /* wait for the commit timer: poll the commit counter (the timer
     * fires in QEMU's main loop; IRQ delivery to the guest is a
     * separate nto64 concern) */
wait:
    movl 0x18(%ebp), %eax
    testl %eax, %eax
    jz wait

    /* foreign page after commit */
    movl (%edi), %eax
    movl %eax, final(%rip)

    /* counters */
    movl 0x10(%ebp), %eax
    movl %eax, rd(%rip)
    movl 0x14(%ebp), %eax
    movl %eax, wr(%rip)
    movl 0x18(%ebp), %eax
    movl %eax, cm(%rip)

    /* --- AP bring-up: trampoline to 0x8000, GDT to 0x9000,
     * INIT+SIPI to APIC ID 1, wait for ap_ready ---- */
    lea ap_tramp(%rip), %rsi
    lea ap_tramp_end(%rip), %rcx
    sub %rsi, %rcx
    movl $0x8000, %edi
    rep movsb
    /* patch the trampoline's far-jump targets to their runtime
     * addresses (0x8000 + offset within the trampoline) */
    lea ap_pm(%rip), %rax
    lea ap_tramp(%rip), %rcx
    sub %rcx, %rax
    add $0x8000, %rax
    movw %ax, 0x8016              /* ljmpw offset -> ap_pm */
    lea ap_ljmpl(%rip), %rdx
    sub %rcx, %rdx
    add $0x8000, %rdx
    lea ap_lm64(%rip), %rax
    sub %rcx, %rax
    add $0x8000, %rax
    movl %eax, 1(%rdx)            /* ljmpl offset -> ap_lm64 */
    movl $0x9000, %edi
    movl $0x00000000, 0(%edi)     /* null */
    movl $0x00000000, 4(%edi)
    movl $0x0000ffff, 8(%edi)     /* 0x08 code32: limit/base lo */
    movl $0x00cf9a00, 12(%edi)
    movl $0x0000ffff, 16(%edi)    /* 0x10 data */
    movl $0x00cf9200, 20(%edi)
    movl $0x0000ffff, 24(%edi)    /* 0x18 code64 */
    movl $0x00af9a00, 28(%edi)
    movw $0x1f, 0x9020            /* gdt limit */
    movl $0x9000, 0x9022          /* gdt base */
    mov %cr3, %rax
    movl %eax, 0x9040
    lea ap_main(%rip), %rax
    movl %eax, 0x9050
    /* bring up every AP (LAPIC IDs 1..3) via targeted INIT+SIPI.
     * The INIT/SIPI are physical-destination (no destination
     * shorthand), so the ICR2 APIC ID below is honoured; a broadcast
     * would re-INIT already-started APs.  The ready slot is cleared
     * each round so a stale flag from a previous boot is not taken as
     * this round's completion. */
    movl $1, %r12d               /* apid */
ap_loop:
    movl %r12d, %eax
    shll $4, %eax
    addl $0x9100, %eax
    movl %eax, %r13d             /* result slot */
    movl $0, 0(%r13d)            /* clear ready flag (re-init handshake) */
    movl $0, 4(%r13d)            /* clear own/remote too, so a stale value
                                    from a previous round cannot be reported */
    movl $0, 8(%r13d)
    movl %r12d, %eax
    shll $16, %eax
    addl $0x100000, %eax         /* AP stack top = 0x100000 + id*0x10000 */
    movl %eax, 0x9060
    movl %r12d, %eax
    shll $24, %eax
    movl $0xfee00310, %edx
    movl %eax, (%edx)            /* ICR2: dest APIC ID */
    movl $0xfee00300, %edx
    movl $0x00004500, (%edx)     /* INIT (targeted, physical dest) */
    movl $2000000, %ecx
1:  decl %ecx
    jnz 1b
    movl %r12d, %eax
    shll $24, %eax
    movl $0xfee00310, %edx
    movl %eax, (%edx)
    movl $0xfee00300, %edx
    movl $0x00004608, (%edx)     /* SIPI: vector 8 -> 0x8000 */
    movl $100000000, %ecx        /* bounded wait for ap_ready */
ap_wait:
    cmpl $0, 0(%r13d)
    jne ap_done
    decl %ecx
    jnz ap_wait
ap_done:
    cmpl $0, 0(%r13d)            /* still 0 -> the AP never came up */
    jne 1f
    incl fail(%rip)              /* record the timeout as a failure */
1:
    incl %r12d
    cmpl $4, %r12d
    jb ap_loop

    /* BSP re-reads AP1's page: its local write bypassed the
     * interconnect, so this must still show the committed value */
    movl $0xdf001000, %edi
    movl (%edi), %eax
    movl %eax, bsp_re(%rip)
    movl 0x9114, %eax
    movl %eax, ap1_own(%rip)
    movl 0x9118, %eax
    movl %eax, ap1_rem(%rip)
    movl 0x9124, %eax
    movl %eax, ap2_own(%rip)
    movl 0x9128, %eax
    movl %eax, ap2_rem(%rip)
    movl 0x9134, %eax
    movl %eax, ap3_own(%rip)
    movl 0x9138, %eax
    movl %eax, ap3_rem(%rip)
    movl 0x24(%ebp), %eax
    movl %eax, lat(%rip)

    lea ok(%rip), %rsi
    call puts
    movl own(%rip), %eax
    call puthex
    lea sp_stale(%rip), %rsi
    call puts
    movl stale(%rip), %eax
    call puthex
    lea sp_final(%rip), %rsi
    call puts
    movl final(%rip), %eax
    call puthex
    lea sp_cnt(%rip), %rsi
    call puts
    movl rd(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl wr(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl cm(%rip), %eax
    call puthex
    lea sp_delay(%rip), %rsi
    call puts
    movl delay(%rip), %eax
    call puthex
    lea sp_lat(%rip), %rsi
    call puts
    movl lat(%rip), %eax
    call puthex
    lea sp_ap1(%rip), %rsi
    call puts
    movl ap1_own(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl ap1_rem(%rip), %eax
    call puthex
    lea sp_ap2(%rip), %rsi
    call puts
    movl ap2_own(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl ap2_rem(%rip), %eax
    call puthex
    lea sp_ap3(%rip), %rsi
    call puts
    movl ap3_own(%rip), %eax
    call puthex
    lea sp_slash(%rip), %rsi
    call puts
    movl ap3_rem(%rip), %eax
    call puthex
    lea sp_re(%rip), %rsi
    call puts
    movl bsp_re(%rip), %eax
    call puthex
    /* ccNUMA mode: coherent - a foreign write is visible immediately */
    movl $0x14, 0x0c(%ebp)       /* IRQ | CCNUMA */
    movl $0xdf001000, %edi
    movl $0x9999, (%edi)
    movl (%edi), %eax
    movl %eax, ccnuma(%rip)
    lea sp_cc(%rip), %rsi
    call puts
    movl ccnuma(%rip), %eax
    call puthex
    lea sp_f(%rip), %rsi
    call puts
    movl fail(%rip), %eax
    call puthex
    lea nl(%rip), %rsi
    call puts

    pop %rbp
    ret

/* --- AP trampoline (copied to 0x8000) ---- */
    .code16
ap_tramp:
    cli
    xor %ax, %ax
    mov %ax, %ds
    lgdtl 0x9020
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmpw $0x08, $0x8020
ap_pm:
    .code32
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    movl 0x9040, %eax
    mov %eax, %cr3
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4
    mov $0xc0000080, %ecx       /* EFER */
    rdmsr
    or $0x100, %eax             /* LME */
    wrmsr
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0
ap_ljmpl:
    ljmpl $0x18, $0x8040
ap_lm64:
    .code64
    /* load the per-AP stack top the BSP stored at 0x9060 (instead of
     * pointing rsp AT the control block, which the call/push below
     * would overwrite and which every AP would share) */
    movl 0x9060, %esp
    movabs 0x9050, %rax
    call *%rax
1:  hlt
    jmp 1b
ap_tramp_end:

/* --- AP main (runs on CPU 1, long mode, BSP's page tables) ---- */
ap_main:
    push %rbp
    mov %rsp, %rbp
    movl $0xfee00020, %esi
    movl (%esi), %eax
    shrl $24, %eax                /* my LAPIC ID */
    movl %eax, %r12d
    movl %r12d, %eax
    shll $12, %eax
    addl $0xdf000000, %eax        /* my own page */
    movl %eax, %esi
    lea 0xaaaa(%r12d), %ebx       /* marker = 0xaaaa + id */
    movl %ebx, (%esi)
    movl (%esi), %eax
    movl %eax, %r14d              /* own read-back */
    movl $0xdf000000, %edi        /* BSP's page: remote for me */
    movl (%edi), %eax
    movl %eax, %r15d
    movl %r12d, %eax
    shll $4, %eax
    addl $0x9100, %eax
    movl %eax, %r13d              /* result slot: [0]=ready [4]=own [8]=remote */
    movl %r14d, 4(%r13d)
    movl %r15d, 8(%r13d)
    movl $1, 0(%r13d)             /* publish ready last, after both results */
    pop %rbp
1:  hlt
    jmp 1b

/* puts: rsi = string */
puts:
    movzbl (%rsi), %eax
    testb %al, %al
    jz 2f
    call putc
    inc %rsi
    jmp puts
2:  ret

/* puthex: eax (8 hex digits) */
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

/* putc: al */
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

    .balign 16
own:     .long 0
stale:   .long 0
final:   .long 0
rd:      .long 0
wr:      .long 0
cm:      .long 0
ap1_own: .long 0
ap1_rem: .long 0
ap2_own: .long 0
ap2_rem: .long 0
ap3_own: .long 0
ap3_rem: .long 0
bsp_re:  .long 0
lat:     .long 0
delay:   .long 0
ccnuma:  .long 0
fail:    .long 0
ok:      .asciz "REMOTE EFI OK own="
sp_stale: .asciz " stale="
sp_final: .asciz " final="
sp_cnt:  .asciz " r/w/c="
sp_delay: .asciz " delay="
sp_lat:  .asciz " lat="
sp_ap1:  .asciz " ap1="
sp_ap2:  .asciz " ap2="
sp_ap3:  .asciz " ap3="
sp_re:   .asciz " re="
sp_cc:   .asciz " ccnuma="
sp_slash: .asciz "/"
sp_f:    .asciz " f="
nl:      .asciz "\n"
    .balign 16
    .space 0x4000, 0
stack_top:
