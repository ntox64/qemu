# SPDX-License-Identifier: BSD-2-Clause

# memory-numa.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

run-percputest: percputest
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -smp 2 -m 128 \
	    -kernel percputest -serial stdio -display none -no-reboot

run-slicecount: slicecount
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -smp 2 -m 128 \
	    -kernel slicecount -serial stdio -display none -no-reboot

efiremotetest.bin: efiremotetest.S
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


EXTRA_BUILT += BOOTX64.EFI efi-fat.img efiremotetest.bin
RUNTARGETS += run-efiremotetest run-percputest run-slicecount
