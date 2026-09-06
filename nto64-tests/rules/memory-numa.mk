# SPDX-License-Identifier: BSD-2-Clause

# memory-numa.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

run-percputest: percputest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -device isa-serial -smp 2 -m 128 \
	    -kernel percputest -serial stdio -display none -no-reboot

run-slicecount: slicecount
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -device isa-serial -smp 2 -m 128 \
	    -kernel slicecount -serial stdio -display none -no-reboot

nodeslice: nodeslice.S $(BUILD_DEPS)
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

#: two vCPUs per node, so node id and cpu_index differ for APIC 1: the
#: AP's own slice must stay uncounted direct RAM while the other node's
#: slice is counted per access (nodeslice.S).
run-nodeslice: nodeslice
	$(QEMU) -machine q35,nto64-per-cpu-ram=on,nto64-numa-cores-per-node=2 \
	    -device isa-serial -smp 4 -m 128 \
	    -kernel nodeslice -serial stdio -display none -no-reboot

#: Same shape as run-nodeslice, with RAM that spills above 4G (-m 3G
#: leaves 2 GiB below 4G while the node slices are 1.5 GiB): the AP's
#: own-node buffer sits in [1G, 1.5G), which a span/nodes division would
#: hand to node 1 even though the SRAT gives it to node 0.  The
#: exact-zero own-node delta fails if the instrumentation splits the low
#: span instead of the machine RAM.
nodeslice-big: nodeslice.S $(BUILD_DEPS)
	gcc -m32 -nostdlib -static -fno-pie -DNTO64_NODESLICE_BIG=1 \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-nodeslicebig: nodeslice-big
	$(QEMU) -machine q35,nto64-per-cpu-ram=on,nto64-numa-cores-per-node=2 \
	    -device isa-serial -smp 4 -m 3G \
	    -kernel nodeslice-big -serial stdio -display none -no-reboot

#: One vCPU per node, so APIC 1 is node 1: the AP proves node 0's RAM is
#: counted for it, then probes the VGA window that lives in that same
#: node 0 range - it has to stay a device window (counted never, and no
#: host abort from treating a region without a RAMBlock as RAM).
nodeslice-mmio: nodeslice.S $(BUILD_DEPS)
	gcc -m32 -nostdlib -static -fno-pie -DNTO64_MMIO_ONLY=1 \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-nodeslicemmio: nodeslice-mmio
	$(QEMU) -machine q35,nto64-per-cpu-ram=on \
	    -device isa-serial -smp 2 -m 128 \
	    -kernel nodeslice-mmio -serial stdio -display none -no-reboot

#: Explicit unequal -numa node capacities (32 MiB for node 0, 96 MiB
#: for node 1, cpu 0 on node 0): the instrumented ranges have to
#: accumulate node_mem like the SRAT does instead of splitting the
#: whole RAM evenly, or node 1's memory below 64 MiB is called local
#: for cpu 0.
run-unevennuma: unevennuma
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -device isa-serial -smp 2 -m 128 \
	    -object memory-backend-ram,size=32M,id=n0 \
	    -object memory-backend-ram,size=96M,id=n1 \
	    -numa node,nodeid=0,memdev=n0,cpus=0 \
	    -numa node,nodeid=1,memdev=n1,cpus=1 \
	    -kernel unevennuma -serial stdio -display none -no-reboot

efiremotetest.bin: efiremotetest.S $(BUILD_DEPS)
	gcc -m64 -nostdlib -ffreestanding -fno-pie -mno-red-zone \
	    -Wl,-Ttext=0x1000 -Wl,--oformat=binary -o $@ $<

BOOTX64.EFI: efiremotetest.bin pewrap.py
	python3 pewrap.py efiremotetest.bin $@

efi-fat.img: BOOTX64.EFI fatimg.py
	python3 fatimg.py BOOTX64.EFI $@

run-efiremotetest: efi-fat.img /tmp/ovmf-nto64.fd
	$(QEMU) -machine pc,nto64-per-cpu-ram=on -smp 4 -m 512 \
	    -drive file=efi-fat.img,format=raw,if=ide \
	    -drive if=pflash,format=raw,unit=0,file=/tmp/ovmf-nto64.fd,readonly=on \
	    -serial stdio -display none -no-reboot

numatest: numatest.S $(BUILD_DEPS)
	# --build-id=none: keep the ELF's LOAD segments tight.  The default
	# GNU build-id note lands at ~0x8048000, which makes QEMU's multiboot
	# loader DMA the whole elf_low..elf_high span over the RAM top and
	# wipes the ACPI tables (RSDT/SRAT/SLIT at 0x7fdf000+) before the
	# guest can read them.
	gcc -m32 -nostdlib -static -fno-pie -DEXPECT_REMOTE=20 \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

numadisttest: numatest.S $(BUILD_DEPS)
	gcc -m32 -nostdlib -static -fno-pie -DEXPECT_REMOTE=40 \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-numatest: numatest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -device isa-serial -smp 2 -m 128 \
	    -kernel numatest -serial stdio -display none -no-reboot

run-numadisttest: numadisttest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on,nto64-numa-distance=40 -device isa-serial \
	    -smp 2 -m 128 \
	    -kernel numadisttest -serial stdio -display none -no-reboot

cxltest: cxltest.S $(BUILD_DEPS)
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-cxltest: cxltest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on,cxl=on,cxl-fmw.0.targets.0=cxl.0,cxl-fmw.0.size=512M,cxl-fmw.0.interleave-granularity=256 -device isa-serial \
	    -m 2G -smp 2 \
	    -object memory-backend-ram,size=512M,id=cxlmem0 \
	    -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.0 \
	    -device cxl-rp,port=0,bus=cxl.0,id=root_port0,chassis=0,slot=0 \
	    -device cxl-type3,bus=root_port0,volatile-memdev=cxlmem0,id=cxl0 \
	    -kernel cxltest -serial stdio -display none -no-reboot

cpuidtest: cpuidtest.S $(BUILD_DEPS)
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-cpuidtest: cpuidtest
	$(QEMU) -machine 'pc,nto64-per-cpu-cpuid=1:-avx2,nto64-per-cpu-core-type=0:0x40;1:0x20,nto64-per-cpu-tsc-scale=0:1;1:2,nto64-per-cpu-pause-ns=0:0;1:20' \
	    -cpu max \
	    -smp 2 -m 64 \
	    -kernel cpuidtest -serial stdio -display none -no-reboot

#: same-class run: both vCPUs report core type 0x40, so the core-class
# bit alone cannot separate their translated code - only the effective
# per-CPU feature set can.  CPU 1 loses AVX2, so its vpaddd must still
# #UD (the hybrid run proves the same thing, but with the classes also
# differing, which used to be enough on its own).
cpuidtest-same: cpuidtest.S $(BUILD_DEPS)
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie -DNTO64_SAME_CLASS=1 \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-cpuidtestsame: cpuidtest-same
	$(QEMU) -machine 'pc,nto64-per-cpu-cpuid=1:-avx2,nto64-per-cpu-core-type=0:0x40;1:0x40,nto64-per-cpu-tsc-scale=0:1;1:2' \
	    -cpu max \
	    -smp 2 -m 64 \
	    -kernel cpuidtest-same -serial stdio -display none -no-reboot


EXTRA_BUILT += BOOTX64.EFI efi-fat.img efiremotetest.bin numadisttest cpuidtest-same nodeslice-big nodeslice-mmio
RUNTARGETS += run-cpuidtest run-cpuidtestsame run-cxltest run-efiremotetest run-nodeslice run-nodeslicebig run-nodeslicemmio run-numadisttest run-numatest run-percputest run-slicecount run-unevennuma
