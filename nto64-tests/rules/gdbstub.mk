# SPDX-License-Identifier: BSD-2-Clause

# gdbstub.mk -- the qemu "inspection CR3" (qemu.Cr3) positive control.
# README.rst: what this testcase proves and what it cannot.

# --build-id=none: see the numatest comment (a build-id note becomes a high
# PT_LOAD that the multiboot loader writes over RAM).
compatas: compatas.S $(BUILD_DEPS)
	gcc -m32 -nostdlib -static -fno-pie \
	    -Wl,--build-id=none \
	    -Wl,-Ttext=0x101000 -Wl,--section-start=.multiboot=0x100000 \
	    -o $@ $<

# Plain serial boot: proves the guest reaches long mode and the compat user
# spin loop (COMPATAS-KERNEL then COMPATAS-ENTER), then spins.
run-compatas: compatas
	$(QEMU) -machine pc -m 64 -kernel compatas -serial stdio \
	    -display none -no-reboot

# gdb-drive: proves a software breakpoint in a compat (32-bit) user AS
# inserts and fires under TCG (-S + one-insn-per-tb).  The script first
# reproduces "Cannot access memory" (live kernel CR3 does not map the compat
# VA), then shows the Qqemu.Cr3 override makes the same VA readable, then
# continues and stops on the breakpoint.
run-compatas-gdb: compatas
	@$(QEMU) -machine pc -m 64 -kernel compatas \
	    -accel tcg,one-insn-per-tb=on -s -S \
	    -serial file:/tmp/compatas.serial -display none -no-reboot & \
	sleep 2; \
	PID=$$!; \
	gdb-multiarch -q -batch -x compatas.gdb compatas; \
	rc=$$?; \
	kill -9 $$PID 2>/dev/null; \
	cat /tmp/compatas.serial; \
	exit $$rc

EXTRA_BUILT += compatas
RUNTARGETS += run-compatas run-compatas-gdb
