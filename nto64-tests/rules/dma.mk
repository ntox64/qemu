# SPDX-License-Identifier: BSD-2-Clause

# dma.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

run-iommutest: iommutest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -smp 2 -m 512 \
	    -device intel-iommu \
	    -device nto64-dma,iommu=on \
	    -kernel iommutest -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-iommutest
