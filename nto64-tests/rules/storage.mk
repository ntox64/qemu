# SPDX-License-Identifier: BSD-2-Clause

# storage.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

vblktest: vblktest.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

VBLK_IMG = /tmp/vblk-test.img
# format=raw on top of blkdebug: the format driver emits the
# read_aio/write_aio/flush_to_os events onto its file child, which is
# the blkdebug node (blkdebug on top would never see the events).
# werror=report/rerror=report: the default werror=enospc stops the VM
# on ENOSPC instead of reporting it to the guest.
# ioeventfd=off: under TCG, virtio-pci's notify ioeventfd matches the
# legacy QUEUE_NOTIFY write and swallows it (event_notifier_set) without
# a consumer, so the ring is never processed; the guest must use the
# plain ioport notify path.

VBLK_DRIVE = if=none,id=drive0,format=raw,werror=report,rerror=report,file=blkdebug:$(CURDIR)/$1:$(VBLK_IMG)
VBLK_DEV = -device virtio-blk-pci,ioeventfd=off,drive=drive0

run-vblktest: vblktest vblk-clean.conf
	truncate -s 4M $(VBLK_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call VBLK_DRIVE,vblk-clean.conf) \
	    $(VBLK_DEV) \
	    -kernel vblktest -append 'NTO64EXP=0' -serial stdio -display none -no-reboot

run-vblkbadtrack: vblktest vblk-badtrack.conf
	truncate -s 4M $(VBLK_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call VBLK_DRIVE,vblk-badtrack.conf) \
	    $(VBLK_DEV) \
	    -kernel vblktest -append 'NTO64EXP=1' -serial stdio -display none -no-reboot

run-vblkerr: vblktest vblk-err.conf
	truncate -s 4M $(VBLK_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call VBLK_DRIVE,vblk-err.conf) \
	    $(VBLK_DEV) \
	    -kernel vblktest -append 'NTO64EXP=e' -serial stdio -display none -no-reboot

run-vblkpersist: vblktest vblk-persist.conf
	truncate -s 4M $(VBLK_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call VBLK_DRIVE,vblk-persist.conf) \
	    $(VBLK_DEV) \
	    -kernel vblktest -append 'NTO64EXP=10' -serial stdio -display none -no-reboot

#  ring-full fold: a small legacy queue (queue-size=8 -> qn/3 = 2
# descriptor chains) makes the P6 12-request burst genuinely exhaust the
# descriptor table; the driver must drain the used ring and recover.
# Expect a6=21 (10 ring-full waits in each of the write and read bursts).

run-vblkringfull: vblktest vblk-clean.conf
	truncate -s 4M $(VBLK_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call VBLK_DRIVE,vblk-clean.conf) \
	    -device virtio-blk-pci,ioeventfd=off,drive=drive0,queue-size=8 \
	    -kernel vblktest -append 'NTO64EXP=20' -serial stdio -display none -no-reboot

scsitest: scsitest.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

SCSI_IMG = /tmp/scsi-test.img
# Same graph requirement as: format on top of blkdebug, and
# ioeventfd=off (the legacy notify ioeventfd swallows writes under TCG).
SCSI_DRIVE = if=none,id=drv0,format=raw,werror=report,rerror=report,file=blkdebug:$(CURDIR)/$1:$(SCSI_IMG)
SCSI_DEV = -device virtio-scsi-pci,ioeventfd=off,id=scsi0
SCSI_HD = -device scsi-hd,drive=drv0,scsi-id=0,lun=0,bus=scsi0.0

run-scsitest: scsitest scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) $(SCSI_HD) \
	    -kernel scsitest -append 'NTO64EXP=11121111121' -serial stdio -display none -no-reboot

scsiintr: scsiintr.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-scsiintr: scsiintr scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) $(SCSI_HD) \
	    -kernel scsiintr -append 'NTO64EXP=0' \
	    -serial stdio -display none -no-reboot

run-scsiintrinj: scsiintr scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    -device virtio-scsi-pci,ioeventfd=off,id=scsi0,nto64-msix-drop=2 \
	    $(SCSI_HD) \
	    -kernel scsiintr -append 'NTO64EXP=1' \
	    -serial stdio -display none -no-reboot

run-scsifault: scsitest scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) \
	    -device scsi-hd,drive=drv0,scsi-id=0,lun=0,bus=scsi0.0,nto64-drop-sector=4000:4001:4002 \
	    -kernel scsitest -append 'NTO64EXP=11221112221' -serial stdio -display none -no-reboot

run-scsierr: scsitest scsi-err.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-err.conf) \
	    $(SCSI_DEV) $(SCSI_HD) \
	    -kernel scsitest -append 'NTO64EXP=22121111121' -serial stdio -display none -no-reboot

# media-change / write-protect / bring-up shapes.

run-scsibringup: scsitest scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) \
	    -device scsi-hd,drive=drv0,scsi-id=0,lun=0,bus=scsi0.0,nto64-bringup-fail=3 \
	    -kernel scsitest -append 'NTO64EXP=11122111121' -serial stdio -display none -no-reboot

run-scsimedia: scsitest scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) \
	    -device scsi-hd,drive=drv0,scsi-id=0,lun=0,bus=scsi0.0,nto64-media-change-sector=100 \
	    -kernel scsitest -append 'NTO64EXP=11121211121' -serial stdio -display none -no-reboot

run-scsiwp: scsitest scsi-clean.conf
	truncate -s 4M $(SCSI_IMG)
	$(QEMU) -machine pc -m 64 \
	    -drive $(call SCSI_DRIVE,scsi-clean.conf) \
	    $(SCSI_DEV) \
	    -device scsi-hd,drive=drv0,scsi-id=0,lun=0,bus=scsi0.0,nto64-wp-trigger-sector=500 \
	    -kernel scsitest -append 'NTO64EXP=11121121121' -serial stdio -display none -no-reboot

# polling fallback (nto64-msix-drop on qemu-xhci) ----

ahcitest: ahcitest.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

SATA_IMG = /tmp/sata-test.img
# q35's built-in ICH9 AHCI; the drive attaches to its SATA bus (ide.0).
# Same graph requirement as: format on top of blkdebug, and
# werror=report/rerror=report so backend errors reach the drive instead
# of stopping the VM.

SATA_DRIVE = if=none,id=drive0,format=raw,werror=report,rerror=report,file=blkdebug:$(CURDIR)/$1:$(SATA_IMG)
SATA_DEV = -device ide-hd,drive=drive0,bus=ide.0

run-satatest: ahcitest sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=11111000000000' \
	    -serial stdio -display none -no-reboot

ahciintr: ahciintr.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-ahciintr: ahciintr sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    $(SATA_DEV) \
	    -kernel ahciintr -append 'NTO64EXP=0' \
	    -serial stdio -display none -no-reboot

run-ahciintrdrop: ahciintr sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -global ich9-ahci.nto64-msi-drop=2 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    $(SATA_DEV) \
	    -kernel ahciintr -append 'NTO64EXP=1' \
	    -serial stdio -display none -no-reboot

run-satabadtrack: ahcitest sata-badtrack.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-badtrack.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=21111000000000' \
	    -serial stdio -display none -no-reboot

run-sataerr: ahcitest sata-err.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-err.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=12221000000000' \
	    -serial stdio -display none -no-reboot

run-satapersist: ahcitest sata-persist.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-persist.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=11113100000000' \
	    -serial stdio -display none -no-reboot

run-sataslow: ahcitest sata-slow.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-slow.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=11111011000000' \
	    -serial stdio -display none -no-reboot

run-satastuck: ahcitest sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    -device ide-hd,drive=drive0,bus=ide.0,nto64-stuck-sector=7168 \
	    -kernel ahcitest -append 'NTO64EXP=11111000110000' \
	    -serial stdio -display none -no-reboot

# NCQ + spec-breaking completion FISes.

run-satancq: ahcitest sata-ncq.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-ncq.conf) \
	    $(SATA_DEV) \
	    -kernel ahcitest -append 'NTO64EXP=11111000000100' \
	    -serial stdio -display none -no-reboot

run-satasdblie: ahcitest sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    -device ide-hd,drive=drive0,bus=ide.0,nto64-sdb-lie-tag=0 \
	    -kernel ahcitest -append 'NTO64EXP=11111000000010' \
	    -serial stdio -display none -no-reboot

run-satad2hlie: ahcitest sata-clean.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-clean.conf) \
	    -device ide-hd,drive=drive0,bus=ide.0,nto64-d2h-lie-sector=0x1e10 \
	    -kernel ahcitest -append 'NTO64EXP=11111000000003' \
	    -serial stdio -display none -no-reboot

run-satad2hlie2: ahcitest sata-d2hlie.conf
	truncate -s 4M $(SATA_IMG)
	$(QEMU) -machine q35 -m 64 \
	    -drive $(call SATA_DRIVE,sata-d2hlie.conf) \
	    -device ide-hd,drive=drive0,bus=ide.0,nto64-d2h-lie-sector=0x1e10 \
	    -kernel ahcitest -append 'NTO64EXP=11111000000003' \
	    -serial stdio -display none -no-reboot

nvmetest: nvmetest.S
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

run-nvmetest: nvmetest
	truncate -s 64M /tmp/nvme-test.img
	$(QEMU) -machine q35,nto64-per-cpu-ram=on -smp 2 -m 128 \
	    -device nvme,serial=nvme0,id=nvme0,max_ioqpairs=4,msix_qsize=6 \
	    -drive file=/tmp/nvme-test.img,if=none,id=drv0,format=raw \
	    -device nvme-ns,drive=drv0,nsid=1,bus=nvme0 \
	    -kernel nvmetest -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-ahciintr run-ahciintrdrop run-nvmetest run-satabadtrack run-satad2hlie run-satad2hlie2 run-sataerr run-satancq run-satapersist run-satasdblie run-sataslow run-satastuck run-satatest run-scsibringup run-scsierr run-scsifault run-scsiintr run-scsiintrinj run-scsimedia run-scsitest run-scsiwp run-vblkbadtrack run-vblkerr run-vblkpersist run-vblkringfull run-vblktest
