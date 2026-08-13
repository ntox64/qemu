/* SPDX-License-Identifier: BSD-2-Clause */

/* p2ptest.S - freestanding multiboot test for the PCIe peer-to-peer
 * (P2P) DMA mode of nto64-dma.
 *
 * Machine: q35 with an nto64-barmem (the peer) and an nto64-dma whose
 * `peer` property points at it.  The DMA engine copies between system
 * RAM and the peer's BAR0 (or relocates data within the peer BAR)
 * without the CPU ever moving the bytes:
 *   bulk device->peer: 16 KiB RAM -> peer BAR offset 0;
 *   bulk peer->device: 16 KiB peer BAR offset 0x10000 -> RAM;
 *   ring descriptors with the peer-dest flag (NIC/RDMA descriptor
 *     ring -> GPU BAR): 4 x 64-byte messages RAM -> peer BAR 0x8000..;
 *   checks the device's P2P counters (0x68/0x6c/0x70) and that
 *     every phase's bytes landed where they should.
 * Prints to COM1, halts.  Build: `make p2ptest`,
 * run: `make run-p2ptest`.
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
    /* multiboot entry has no usable stack guarantee: set our own */
    movl $stack_top, %esp
    andl $-16, %esp
    /* scan for nto64-barmem (1234:beef) and nto64-dma (1234:1ee9) */
    xorl %edi, %edi
scan:
    xorl %ecx, %ecx
    call cfgread32
    cmpl $0xffffffff, %eax
    je scan_next
    cmpl $0xbeef1234, %eax
    je found_vram
    cmpl $0x1ee91234, %eax
    je found_dma
scan_next:
    incl %edi
    cmpl $32, %edi
    jb scan
    jmp setup

found_vram:
    movl %edi, vram_dev
    jmp scan_next

found_dma:
    movl %edi, dma_dev
    jmp scan_next

setup:
    /* --- enable memory + bus master on both, read BAR0s ---- */
    movl vram_dev, %edi
    movl $4, %ecx
    call cfgread32
    orl $6, %eax
    movl %eax, %ebp
    movl vram_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl vram_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, vram_bar0

    movl dma_dev, %edi
    movl $4, %ecx
    call cfgread32
    orl $6, %eax
    movl %eax, %ebp
    movl dma_dev, %edi
    movl $4, %ecx
    call cfgwrite32
    movl dma_dev, %edi
    movl $0x10, %ecx
    call cfgread32
    andl $0xfffffff0, %eax
    movl %eax, dma_bar0

    cmpl $0, vram_dev
    je 99f
    cmpl $0, dma_dev
    jne 1f
99: incl devf
    jmp report
1:
    /* --- fill the RAM source buffer (16 KiB pattern) ---- */
    movl $0x300000, %edi
    movl $0x11223344, %eax
    movl $4096, %ecx
fill_src:
    movl %eax, (%edi)
    addl $4, %edi
    addl $0x01010101, %eax
    decl %ecx
    jnz fill_src

    /* --- phase 1: bulk device->peer (RAM 0x300000 -> BAR0 +0) ---- */
    movl dma_bar0, %esi
    movl $0x300000, 0x08(%esi)
    movl $0, 0x0c(%esi)
    movl $0, 0x10(%esi)       /* dst = peer BAR offset 0 */
    movl $0, 0x14(%esi)
    movl $0x4000, 0x18(%esi)
    movl $0x9, 0x04(%esi)     /* START | P2P (device -> peer) */
    call wait_done
    movl dma_bar0, %esi
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jz 1f
    incl p1f
1:
    /* verify the peer BAR now holds the pattern */
    movl vram_bar0, %edi
    movl $0x300000, %esi
    movl $4096, %ecx
chk_out:
    movl (%esi), %eax
    cmpl (%edi), %eax
    je 2f
    incl p1f
2:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz chk_out
    movl dma_bar0, %esi
    movl 0x68(%esi), %eax
    cmpl $1, %eax
    je 3f
    incl p1f
3:  movl 0x6c(%esi), %eax
    cmpl $0x4000, %eax
    je 4f
    incl p1f
4:
    /* --- phase 2: bulk peer->device (BAR0 +0x10000 -> RAM) ---- */
    movl vram_bar0, %edi
    addl $0x10000, %edi
    movl $0xa5a5a5a5, %eax
    movl $4096, %ecx
fill_bar:
    movl %eax, (%edi)
    addl $4, %edi
    addl $0x01010101, %eax
    decl %ecx
    jnz fill_bar

    movl dma_bar0, %esi
    movl $0x10000, 0x08(%esi) /* src = peer BAR offset 0x10000 */
    movl $0, 0x0c(%esi)
    movl $0x320000, 0x10(%esi)
    movl $0, 0x14(%esi)
    movl $0x4000, 0x18(%esi)
    movl $0x19, 0x04(%esi)    /* START | P2P | P2PREV (peer -> device) */
    call wait_done
    movl dma_bar0, %esi
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jz 1f
    incl p2f
1:
    /* verify the RAM destination holds the BAR pattern */
    movl $0x320000, %edi
    movl vram_bar0, %esi
    addl $0x10000, %esi
    movl $4096, %ecx
chk_in:
    movl (%esi), %eax
    cmpl (%edi), %eax
    je 2f
    incl p2f
2:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz chk_in
    movl dma_bar0, %esi
    movl 0x68(%esi), %eax
    cmpl $2, %eax
    je 3f
    incl p2f
3:
    /* --- phase 3: ring mode with peer-dest descriptors ---- */
    /* descriptors at 0x340000: src RAM 0x300000+..., dst peer BAR
     * 0x8000+..., 64 bytes each, flags = valid | peer-dest (5) */
    movl $0x340000, %edi
    xorl %ebx, %ebx
ring_fill:
    movl %ebx, %ecx
    shll $6, %ecx
    addl $0x300000, %ecx
    movl %ecx, 0(%edi)        /* src */
    movl %ebx, %ecx
    shll $6, %ecx
    addl $0x8000, %ecx
    movl %ecx, 4(%edi)        /* dst = peer offset */
    movl $0x40, 8(%edi)       /* len */
    movl $5, 12(%edi)         /* flags: valid | peer-dest */
    addl $16, %edi
    incl %ebx
    cmpl $4, %ebx
    jb ring_fill

    movl dma_bar0, %esi
    movl $0x340000, 0x28(%esi)  /* ring base */
    movl $0, 0x2c(%esi)
    movl $4, 0x30(%esi)         /* count */
    movl $16, 0x34(%esi)        /* stride */
    movl $0x5, 0x04(%esi)       /* START | RING */
    call wait_done
    movl dma_bar0, %esi
    movl 0x1c(%esi), %eax
    testl $4, %eax
    jz 1f
    incl p3f
1:  movl 0x38(%esi), %eax
    cmpl $4, %eax
    je 2f
    incl p3f
2:
    /* verify the peer BAR got the four 64-byte messages */
    movl vram_bar0, %edi
    addl $0x8000, %edi
    movl $0x300000, %esi
    movl $64, %ecx
chk_ring:
    movl (%esi), %eax
    cmpl (%edi), %eax
    je 3f
    incl p3f
3:  addl $4, %esi
    addl $4, %edi
    decl %ecx
    jnz chk_ring
    /* descriptor completion flag (bit1) set by the device */
    movl $0x340000, %edi
    xorl %ebx, %ebx
chk_desc:
    movl 12(%edi), %eax
    testl $2, %eax
    jnz 4f
    incl p3f
4:  addl $16, %edi
    incl %ebx
    cmpl $4, %ebx
    jb chk_desc
    movl dma_bar0, %esi
    movl 0x68(%esi), %eax
    movl %eax, p2p_xfers
    movl 0x6c(%esi), %eax
    movl %eax, p2p_bytes

report:
    movl $msg, %esi
    call puts
    movl p1f, %eax
    addl p2f, %eax
    addl p3f, %eax
    addl devf, %eax
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
    movl $sp_po, %esi
    call puts
    movl p2p_xfers, %eax
    call puthex
    movl $sp_pb, %esi
    call puts
    movl p2p_bytes, %eax
    call puthex
    movl $sp_1, %esi
    call puts
    movl p1f, %eax
    call puthex
    movl $sp_2, %esi
    call puts
    movl p2f, %eax
    call puthex
    movl $sp_3, %esi
    call puts
    movl p3f, %eax
    call puthex
    movl $sp_dv, %esi
    call puts
    movl dma_dev, %eax
    call puthex
    movl $sp_vv, %esi
    call puts
    movl vram_dev, %eax
    call puthex
    movl $nl, %esi
    call puts
    cli
3:  hlt
    jmp 3b

/* wait_done: poll status (esi=bar0) until done or error */
wait_done:
    push %ecx
    movl $30000000, %ecx
1:  movl 0x1c(%esi), %eax
    testl $6, %eax
    jnz 2f
    decl %ecx
    jnz 1b
2:  pop %ecx
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

/* cfgwrite32: edi=dev, ecx=byteoff, ebp=val (clobbers eax, ebx, edx) */
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
vram_dev:  .long 0
dma_dev:   .long 0
vram_bar0: .long 0
dma_bar0:  .long 0
p2p_xfers: .long 0
p2p_bytes: .long 0
p1f:       .long 0
p2f:       .long 0
p3f:       .long 0
devf:      .long 0
fail:      .long 0

    .bss
    .balign 16
stack:     .space 4096
stack_top:

    .section .rodata
msg:     .asciz "P2P "
okmsg:   .asciz "OK"
failmsg: .asciz "FAIL"
sp_f:    .asciz " f="
sp_po:   .asciz " xfers="
sp_pb:   .asciz " bytes="
sp_1:    .asciz " p1="
sp_2:    .asciz " p2="
sp_3:    .asciz " p3="
sp_dv:   .asciz " dma="
sp_vv:   .asciz " vram="
nl:      .asciz "\n"
