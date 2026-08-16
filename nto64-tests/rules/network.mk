# SPDX-License-Identifier: BSD-2-Clause

# network.mk -- one subsystem of the testbed;
# README.rst says what each run target proves.

netfault: netfault.S $(BUILD_DEPS) nto64-expect.inc
	# --build-id=none: see the numatest comment (multiboot span trap).
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

NET_KERNEL = -kernel netfault -serial stdio -display none -no-reboot

run-netfault: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 $(NET_DEV) \
	    $(NET_KERNEL) -append 'NTO64EXP=0'

run-netrxdrop: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,ioeventfd=off,nto64-rx-drop=2 \
	    $(NET_KERNEL) -append 'NTO64EXP=1'

run-nettxstall: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,ioeventfd=off,nto64-tx-stall=3 \
	    $(NET_KERNEL) -append 'NTO64EXP=2'

run-netctrlfail: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,ioeventfd=off,nto64-ctrl-fail=2 \
	    $(NET_KERNEL) -append 'NTO64EXP=4'

run-netlinkflap: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,ioeventfd=off,nto64-link-flap-ms=1000 \
	    $(NET_KERNEL) -append 'NTO64EXP=8'

run-netmsidrop: netfault
	$(QEMU) -machine pc -m 64 \
	    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,ioeventfd=off,nto64-msix-drop=1 \
	    $(NET_KERNEL) -append 'NTO64EXP=10'


EXTRA_BUILT +=
RUNTARGETS += run-netctrlfail run-netfault run-netlinkflap run-netmsidrop run-netrxdrop run-nettxstall
