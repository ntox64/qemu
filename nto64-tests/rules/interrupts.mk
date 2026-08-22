# SPDX-License-Identifier: BSD-2-Clause

# interrupts.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

QEMU ?= ../build/qemu-system-x86_64

run-irqtest: irqtest
	$(QEMU) -device nto64-irqgen -kernel irqtest -serial stdio \
	    -display none -no-reboot

msix-fat.img: BOOTX64-msix.EFI fatimg.py
	python3 fatimg.py BOOTX64-msix.EFI $@

msixtest.bin: msixtest.S $(BUILD_DEPS)
	gcc -m64 -nostdlib -ffreestanding -fno-pie -mno-red-zone \
	    -Wl,-Ttext=0x1000 -Wl,--oformat=binary -o $@ $<

BOOTX64-msix.EFI: msixtest.bin pewrap.py
	python3 pewrap.py msixtest.bin $@

run-msixtest: msix-fat.img /tmp/ovmf-nto64.fd
	$(QEMU) -machine pc,nto64-per-cpu-ram=on -smp 4 -m 512 \
	    -device nto64-irqgen -device nto64-msix -device nto64-dma \
	    -drive file=msix-fat.img,format=raw,if=ide \
	    -drive if=pflash,format=raw,unit=0,file=/tmp/ovmf-nto64.fd,readonly=on \
	    -serial stdio -display none -no-reboot


EXTRA_BUILT += BOOTX64-msix.EFI msix-fat.img msixtest.bin
RUNTARGETS += run-irqtest run-msixtest
