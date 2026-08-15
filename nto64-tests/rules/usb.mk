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

USB_IMG = /tmp/usb-test.img
# Same graph requirement as the storage steps: format on top of
# blkdebug, and werror=report/rerror=report so backend errors reach the
# device instead of stopping the VM.

USB_DRIVE = if=none,id=drive0,format=raw,werror=report,rerror=report,file=blkdebug:$(CURDIR)/$1:$(USB_IMG)
USB_XHCI = -device qemu-xhci,p3=0
USB_STORAGE = -device usb-storage,drive=drive0
UAS_DEV = -device usb-uas,id=uas
UAS_HD = -device scsi-hd,drive=drive0,scsi-id=0,lun=0,bus=uas.0
USB_HUB = -device usb-hub,id=hub,ports=4,port-power=on,bus=xhci.0,port=1
USB_MOUSE = -device usb-mouse,id=ms,bus=xhci.0,port=2
USB_COMP = -device usb-nto64,id=comp,bus=xhci.0,port=1.1,power-ma=100,composite=on
USB_NTO64 = -device usb-nto64,id=nt64,bus=xhci.0,port=1.2,power-ma=100
USB_BADESC = -device usb-nto64,id=bd,bus=xhci.0,port=1.3,power-ma=100,bad-desc=on
USB_NOCFG = -device usb-nto64,id=nc,bus=xhci.0,port=1.4,power-ma=100,no-config=on
USB_RHANG = -device usb-nto64,id=rh,bus=xhci.0,port=3,power-ma=100,reset-hang=on
USB_SCFG = -device usb-nto64,id=sc,bus=xhci.0,port=4,power-ma=100,stall-config=on
USB_PWR = -device usb-nto64,id=pw,bus=xhci.0,port=3,power-ma=600
USB_DISC = -device usb-nto64,id=comp,bus=xhci.0,port=1.1,power-ma=100,composite=on,nto64-disconnect=on,nto64-replug-ms=2000
USB_STORM = -device usb-hub,id=hub,ports=4,port-power=on,nto64-port-storm=on,nto64-storm-port=1,nto64-storm-flaps=4,nto64-storm-period-ms=50,bus=xhci.0,port=1
NET_DEV = -device virtio-net-pci,netdev=n0,ioeventfd=off


EXTRA_BUILT +=
RUNTARGETS += run-usbintr run-usbintrdrop
