# SPDX-License-Identifier: BSD-2-Clause

# dma.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

run-iommutest: iommutest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -smp 2 -m 512 \
	    -device intel-iommu \
	    -device nto64-dma,iommu=on \
	    -kernel iommutest -serial stdio -display none -no-reboot

run-p2ptest: p2ptest
	$(QEMU) -machine q35 -m 128 \
	    -device nto64-barmem,id=vram \
	    -device nto64-dma,peer=vram,queues=1 \
	    -kernel p2ptest -serial stdio -display none -no-reboot

run-pritest: pritest
	$(QEMU) -machine q35 -m 128 \
	    -device nto64-dma,queues=1 \
	    -kernel pritest -serial stdio -display none -no-reboot

aertest: aertest.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-aertest: aertest
	$(QEMU) -machine q35 -m 64 \
	    -device nto64-dma,queues=1 \
	    -kernel aertest -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-aertest run-iommutest run-p2ptest run-pritest
