# SPDX-License-Identifier: BSD-2-Clause
#
# nto64-expect.inc -- shared multiboot expected-mode reader.
#
# Defines `nto64_expect` (eax = expected-mode bitmask parsed from the
# multiboot cmdline "NTO64EXP=<hex>", 0 if absent) and an internal
# hex-digit helper.  The including freestanding test must:
#   - define `mbi_ptr` in .bss and save EBX (the multiboot info pointer)
#     to it as the first instruction of _start,
#   - .include this file somewhere in .text (before `report` is fine).
#
# `nto64_expect` clobbers eax, ecx, edx, esi, edi.  The test's
# `verify_expect` (not provided here, since the phase names differ) then
# compares the relevant aN fields against the bitmask and increments
# `fail` on a mismatch, so a run cannot silently "pass" when the fault
# the config intended did not actually fire.

    .text
nto64_expect:
    movl mbi_ptr, %eax
    testl %eax, %eax
    jz .Lexp_none
    movl (%eax), %ecx
    testl $0x4, %ecx           /* MULTIBOOT_FLAGS_CMDLINE (bit 2) */
    jz .Lexp_none
    movl 16(%eax), %esi        /* MBI_CMDLINE */
    testl %esi, %esi
    jz .Lexp_none
    xorl %edx, %edx            /* parsed value */
    xorl %edi, %edi            /* 0 = scan marker, 1 = parse digits */
.Lexp_scan:
    movzbl (%esi), %eax
    testb %al, %al
    jz .Lexp_done              /* end of string: return the parsed value */
    testl %edi, %edi
    jnz .Lexp_hex
    cmpb $'N', %al
    jne .Lexp_next
    cmpb $'T', 1(%esi)
    jne .Lexp_next
    cmpb $'O', 2(%esi)
    jne .Lexp_next
    cmpb $'6', 3(%esi)
    jne .Lexp_next
    cmpb $'4', 4(%esi)
    jne .Lexp_next
    cmpb $'E', 5(%esi)
    jne .Lexp_next
    cmpb $'X', 6(%esi)
    jne .Lexp_next
    cmpb $'P', 7(%esi)
    jne .Lexp_next
    cmpb $'=', 8(%esi)
    jne .Lexp_next
    movl $1, %edi
    addl $9, %esi
    jmp .Lexp_scan
.Lexp_next:
    incl %esi
    jmp .Lexp_scan
.Lexp_hex:
    movzbl (%esi), %eax
    call .Lhexval
    cmpl $0x100, %eax
    jae .Lexp_done
    shll $4, %edx
    orl %eax, %edx
    incl %esi
    jmp .Lexp_scan
.Lexp_done:
    movl %edx, %eax
    ret
.Lexp_none:
    xorl %eax, %eax
    ret

.Lhexval:                       /* al -> 0..15, or 0x100 if not hex */
    cmpb $'0', %al
    jb .Lhex_bad
    cmpb $'9', %al
    jbe .Lhex_dig
    movzbl %al, %eax
    orl $0x20, %eax
    cmpb $'a', %al
    jb .Lhex_bad
    cmpb $'f', %al
    ja .Lhex_bad
    subl $('a'-10), %eax
    ret
.Lhex_dig:
    subl $'0', %eax
    ret
.Lhex_bad:
    movl $0x100, %eax
    ret

/* nto64_expect_seq: parse "NTO64EXP=<hex digits>" into `expect[]` (a
 * per-test .bss array).  Returns eax = number of digits stored (0 if the
 * marker is absent).  Clobbers eax, ecx, edx, esi, edi, ebx.
 * Only emitted when the including test sets `.set NTO64_NEEDS_SEQ, 1`;
 * the interrupt tests use the single-value `nto64_expect` instead and do
 * not want (or define) the `expect[]` array. */
.ifdef NTO64_NEEDS_SEQ
nto64_expect_seq:
    movl mbi_ptr, %eax
    testl %eax, %eax
    jz .Lsq_none
    movl (%eax), %ecx
    testl $0x4, %ecx           /* MULTIBOOT_FLAGS_CMDLINE */
    jz .Lsq_none
    movl 16(%eax), %esi        /* MBI_CMDLINE */
    testl %esi, %esi
    jz .Lsq_none
    xorl %ebx, %ebx            /* digit count */
    xorl %edi, %edi            /* 0 = scan marker, 1 = parse digits */
.Lsq_scan:
    movzbl (%esi), %eax
    testb %al, %al
    jz .Lsq_done
    testl %edi, %edi
    jnz .Lsq_hex
    cmpb $'N', %al
    jne .Lsq_next
    cmpb $'T', 1(%esi)
    jne .Lsq_next
    cmpb $'O', 2(%esi)
    jne .Lsq_next
    cmpb $'6', 3(%esi)
    jne .Lsq_next
    cmpb $'4', 4(%esi)
    jne .Lsq_next
    cmpb $'E', 5(%esi)
    jne .Lsq_next
    cmpb $'X', 6(%esi)
    jne .Lsq_next
    cmpb $'P', 7(%esi)
    jne .Lsq_next
    cmpb $'=', 8(%esi)
    jne .Lsq_next
    movl $1, %edi
    addl $9, %esi
    jmp .Lsq_scan
.Lsq_next:
    incl %esi
    jmp .Lsq_scan
.Lsq_hex:
    movzbl (%esi), %eax
    call .Lhexval
    cmpl $0x100, %eax
    jae .Lsq_done
    movl %eax, expect(,%ebx,4)
    incl %ebx
    incl %esi
    jmp .Lsq_scan
.Lsq_done:
    movl %ebx, %eax
    ret
.Lsq_none:
    xorl %eax, %eax
    ret
.endif
