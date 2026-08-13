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

run-sriovtest: sriovtest
	$(QEMU) -machine q35 -m 128 \
	    -netdev user,id=n -netdev user,id=o -netdev user,id=p \
	    -device pcie-root-port,id=b \
	    -device virtio-net-pci,bus=b,addr=0x0.0x1,netdev=o,sriov-pf=f \
	    -device virtio-net-pci,bus=b,addr=0x0.0x2,netdev=p,sriov-pf=f \
	    -device virtio-net-pci,bus=b,addr=0x0.0x0,netdev=n,id=f \
	    -kernel sriovtest -serial stdio -display none -no-reboot

run-samtest: samtest
	$(QEMU) -machine q35 -m 3G \
	    -device nto64-barmem,bar64=on,bar-size=2147483648,rebar-sizes=0x3c00 \
	    -kernel samtest -serial stdio -display none -no-reboot


EXTRA_BUILT +=
RUNTARGETS += run-barmemtest run-rebartest run-samtest run-sriovtest
