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


EXTRA_BUILT +=
RUNTARGETS += run-vblkbadtrack run-vblkerr run-vblkpersist run-vblkringfull run-vblktest
