# SPDX-License-Identifier: BSD-2-Clause

# pci-bar.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

run-barmemtest: barmemtest
	$(QEMU) -device nto64-barmem -kernel barmemtest -serial stdio \
	    -display none -no-reboot

run-rebartest: rebar
	$(QEMU) -machine q35 -m 128 \
	    -device nto64-barmem \
	    -kernel rebar -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-barmemtest run-rebartest
