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


EXTRA_BUILT +=
RUNTARGETS += run-iommutest run-p2ptest
