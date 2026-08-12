# SPDX-License-Identifier: BSD-2-Clause

#
# nto64-tests: freestanding guests for this tree's qemu-system-x86_64.
#
# Every test is one .S file: a multiboot header at 0x100000, the kernel
# linked at 0x101000, no libc, no linker build-id note (a note segment
# becomes a high PT_LOAD that the loader would DMA over our RAM).  It
# prints exactly one distinctive "... VERIFIED" line and exits by triple
# fault, so a run is a grep.  Per-subsystem targets live in rules/*.mk;
# README.rst says what each one proves and what it cannot.

QEMU ?= ../build/qemu-system-x86_64
CC   ?= gcc

# Rebuild every kernel when the build recipe (this file, or a rules/*.mk
# that may add per-target link flags) changes.  Otherwise a stale binary
# that was linked before a flag change stays "up to date" because only
# the .S mtime is compared against.
BUILD_DEPS := $(MAKEFILE_LIST) $(wildcard rules/*.mk)

# Extension-less multiboot kernels: one pattern rule covers every test.
%: %.S $(BUILD_DEPS)
	$(CC) -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

# OVMF only runs as pflash: the .fd is not 64K-aligned, so -bios is not an
# option; the decompressed copy is shared by every EFI target.
/tmp/ovmf-nto64.fd: ../pc-bios/edk2-x86_64-code.fd.bz2
	bzip2 -dkc $< > $@

# Every .S is one extension-less multiboot kernel; the rules files add only
# the artifacts a pattern rule cannot name (EFI wrappers, FAT images).
KERNELS := $(patsubst %.S,%,$(wildcard *.S))

include $(wildcard rules/*.mk)

clean:
	rm -f $(KERNELS) $(EXTRA_BUILT)

.PHONY: clean $(RUNTARGETS)
