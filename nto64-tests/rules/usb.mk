# SPDX-License-Identifier: BSD-2-Clause

# usb.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

usbintr: usbintr.S $(BUILD_DEPS) nto64-expect.inc
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

usbfault: usbfault.S $(BUILD_DEPS) nto64-expect.inc
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

USB_KERNEL = -kernel usbfault -append 'NTO64EXP=$(USB_EXP)' -serial stdio -display none -no-reboot

run-usbstoragetest: USB_EXP = 113111111010
run-usbstoragebadtrack: USB_EXP = 123111111010
run-usbstorageerr: USB_EXP = 116111111010
run-usbstoragepersist: USB_EXP = 113211111010
run-usbstoragestall: USB_EXP = 113121111010
run-usbstoragedrop: USB_EXP = 113112111010
run-usbss: USB_EXP = 113111111010
run-usbisoc: USB_EXP = 000000000201
run-usbeject: USB_EXP = 113111211010
run-usbejectinflight: USB_EXP = 113111111020
run-usbwp: USB_EXP = 113111121010
run-usbflushlie: USB_EXP = 113111112010
run-uastest: USB_EXP = 113111000000
run-uabadtrack: USB_EXP = 123111000000
run-uaerr: USB_EXP = 116111000000
run-uapersist: USB_EXP = 113211000000
run-uabad: USB_EXP = 113121000000
run-uadrop: USB_EXP = 113112000000

run-usbstoragetest: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) $(USB_STORAGE) \
	    $(USB_KERNEL)

run-usbstoragebadtrack: usbfault usb-badtrack.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-badtrack.conf) \
	    $(USB_XHCI) $(USB_STORAGE) \
	    $(USB_KERNEL)

run-usbstorageerr: usbfault usb-err.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-err.conf) \
	    $(USB_XHCI) $(USB_STORAGE) \
	    $(USB_KERNEL)

run-usbstoragepersist: usbfault usb-persist.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-persist.conf) \
	    $(USB_XHCI) $(USB_STORAGE) \
	    $(USB_KERNEL)

run-usbstoragestall: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-stall-lba=8000 \
	    $(USB_KERNEL)

run-usbstoragedrop: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-drop-lba=7500 \
	    $(USB_KERNEL)

run-usbss: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    -device qemu-xhci,p3=2 $(USB_STORAGE) \
	    $(USB_KERNEL)

run-usbisoc: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-nto64,id=isocd,bus=xhci.0,port=1,power-ma=100,nto64-isoc=on,nto64-drop-microframe=1 \
	    $(USB_KERNEL)

run-usbeject: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-eject-lba=5000 \
	    $(USB_KERNEL)

run-usbejectinflight: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-eject-inflight-lba=5500 \
	    $(USB_KERNEL)

run-usbwp: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-write-protect=on \
	    $(USB_KERNEL)

run-usbflushlie: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-storage,drive=drive0,nto64-flush-lie=on \
	    $(USB_KERNEL)

run-uastest: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) $(UAS_DEV) $(UAS_HD) \
	    $(USB_KERNEL)

run-uabadtrack: usbfault usb-badtrack.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-badtrack.conf) \
	    $(USB_XHCI) $(UAS_DEV) $(UAS_HD) \
	    $(USB_KERNEL)

run-uaerr: usbfault usb-err.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-err.conf) \
	    $(USB_XHCI) $(UAS_DEV) $(UAS_HD) \
	    $(USB_KERNEL)

run-uapersist: usbfault usb-persist.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-persist.conf) \
	    $(USB_XHCI) $(UAS_DEV) $(UAS_HD) \
	    $(USB_KERNEL)

run-uabad: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-uas,id=uas,nto64-bad-iu-lba=8000 \
	    $(UAS_HD) \
	    $(USB_KERNEL)

run-uadrop: usbfault usb-clean.conf
	truncate -s 4M $(USB_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call USB_DRIVE,usb-clean.conf) \
	    $(USB_XHCI) -device usb-uas,id=uas,nto64-drop-tag=4660 \
	    $(UAS_HD) \
	    $(USB_KERNEL)

USB_RSTSTORM = -device usb-hub,id=hub,ports=4,port-power=on,nto64-reset-storm=on,nto64-reset-storm-port=1,nto64-reset-storm-flaps=4,nto64-reset-storm-period-ms=50,bus=xhci.0,port=1

usbmisbehave: usbmisbehave.S $(BUILD_DEPS) nto64-expect.inc
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

USB_KERNEL27 = -kernel usbmisbehave -append 'NTO64EXP=$(USB_EXP)' -serial stdio -display none -no-reboot

run-usbmisbehave: USB_EXP = 41111011111
run-usbbaddesc: USB_EXP = 42111011111
run-usbstallintr: USB_EXP = 41211011111
run-usbbadreport: USB_EXP = 41211011111
run-usboc: USB_EXP = 41121011111
run-usbocpersist: USB_EXP = 41121011111
run-usboclevel: USB_EXP = 41121011111
run-usbocchange: USB_EXP = 41121011111
run-usbocstatus: USB_EXP = 41121011111
run-usbocclear: USB_EXP = 41121011111
run-usbdisconnect: USB_EXP = 41111021111
run-usbstorm: USB_EXP = 41111012111
run-usbocmid: USB_EXP = 41111021211
run-usbresetstorm: USB_EXP = 41111011121
run-usbsuspend: USB_EXP = 41111011112
run-usbdead: USB_EXP = 41112011111
run-usbenum: USB_EXP = 31111411111
run-usbpower: USB_EXP = 41111111111

run-usbmisbehave: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbbaddesc: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) $(USB_NTO64) \
	    -device usb-mouse,id=ms,bus=xhci.0,port=2,nto64-bad-report-desc=on \
	    $(USB_KERNEL27)

run-usbstallintr: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) $(USB_NTO64) \
	    -device usb-mouse,id=ms,bus=xhci.0,port=2,nto64-stall-intr=on \
	    $(USB_KERNEL27)

run-usbbadreport: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) $(USB_NTO64) \
	    -device usb-mouse,id=ms,bus=xhci.0,port=2,nto64-bad-report=on \
	    $(USB_KERNEL27)

run-usboc: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbocpersist: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,nto64-oc-persistent=on,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usboclevel: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,nto64-oc-edge=off,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbocchange: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,nto64-oc-status=off,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbocstatus: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,nto64-oc-change=off,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbocclear: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,oc-port=2,nto64-oc-self-clear-reads=3,bus=xhci.0,port=1 \
	    $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbdisconnect: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_DISC) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbstorm: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_STORM) $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbocmid: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci \
	    -device usb-hub,id=hub,ports=4,port-power=on,nto64-oc-mid-transfer=on,nto64-oc-mid-port=1,nto64-oc-mid-ms=10,bus=xhci.0,port=1 \
	    $(USB_DISC) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

#: hub-port RESET storm - the downstream port NEVER
# disconnects, but the hub keeps re-signaling PORT RESET (the C_RESET
# change bit re-asserts and the child is reset, losing its
# address/config) storm-flaps times.  The driver bounds its wait for
# the first C_RESET, settles past the storm and re-enumerates
# (phase a10=2; clean targets a10=1).

run-usbresetstorm: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_RSTSTORM) $(USB_COMP) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

#: USB suspend/resume + remote wakeup.  The composite is armed
# (nto64-wakeup + guest vendor 0x5b); the driver sets
# DEVICE_REMOTE_WAKEUP on the composite AND the hub, suspends the hub
# port + the xHCI root port (PORTSC PLS=U3), and the device's wake
# timer signals a remote wakeup that propagates through the hub to the
# root port (PLS=Resume + PLC event).  The driver completes the resume
# and re-verifies the echo (phase a11=2; clean targets a11=1).
USB_WAKE = -device usb-nto64,id=comp,bus=xhci.0,port=1.1,power-ma=100,composite=on,nto64-wakeup=on,nto64-wakeup-ms=100

run-usbsuspend: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_WAKE) $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbdead: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) \
	    -device usb-nto64,id=comp,bus=xhci.0,port=1.1,power-ma=100,composite=on,kill-iface=1 \
	    $(USB_NTO64) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbenum: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) \
	    $(USB_BADESC) $(USB_NOCFG) $(USB_RHANG) $(USB_SCFG) $(USB_MOUSE) \
	    $(USB_KERNEL27)

run-usbpower: usbmisbehave
	$(QEMU) -machine pc -m 64 \
	    -device qemu-xhci,p3=0,id=xhci $(USB_HUB) $(USB_COMP) $(USB_NTO64) \
	    $(USB_PWR) $(USB_MOUSE) \
	    $(USB_KERNEL27)


EXTRA_BUILT +=
RUNTARGETS += run-uabad run-uabadtrack run-uadrop run-uaerr run-uapersist run-uastest run-usbbaddesc run-usbbadreport run-usbdead run-usbdisconnect run-usbeject run-usbejectinflight run-usbenum run-usbflushlie run-usbintr run-usbintrdrop run-usbisoc run-usbmisbehave run-usboc run-usbocchange run-usbocclear run-usboclevel run-usbocmid run-usbocpersist run-usbocstatus run-usbpower run-usbresetstorm run-usbss run-usbstallintr run-usbstoragebadtrack run-usbstoragedrop run-usbstorageerr run-usbstoragepersist run-usbstoragestall run-usbstoragetest run-usbstorm run-usbsuspend run-usbwp
