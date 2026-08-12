# SPDX-License-Identifier: BSD-2-Clause

# interrupts.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

QEMU ?= ../build/qemu-system-x86_64

run-irqtest: irqtest
	$(QEMU) -device nto64-irqgen -kernel irqtest -serial stdio \
	    -display none -no-reboot

msix-fat.img: BOOTX64-msix.EFI fatimg.py
	python3 fatimg.py BOOTX64-msix.EFI $@


EXTRA_BUILT += msix-fat.img
RUNTARGETS += run-irqtest
