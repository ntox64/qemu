# SPDX-License-Identifier: BSD-2-Clause

# usb.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

usbintr: usbintr.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

USBINTR_DEV = -device usb-nto64,id=comp,bus=xhci.0,port=1,power-ma=100,composite=on

run-usbintr: usbintr
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USBINTR_DEV) \
	    -kernel usbintr -append 'NTO64EXP=0' \
	    -serial stdio -display none -no-reboot

run-usbintrdrop: usbintr
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci,nto64-msix-drop=1 $(USBINTR_DEV) \
	    -kernel usbintr -append 'NTO64EXP=1' \
	    -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-usbintr run-usbintrdrop
