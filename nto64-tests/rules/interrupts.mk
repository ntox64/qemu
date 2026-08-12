# SPDX-License-Identifier: BSD-2-Clause

# interrupts.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

QEMU ?= ../build/qemu-system-x86_64

run-irqtest: irqtest
	$(QEMU) -device nto64-irqgen -kernel irqtest -serial stdio \
	    -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-irqtest
