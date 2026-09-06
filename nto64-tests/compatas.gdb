# SPDX-License-Identifier: BSD-2-Clause
#
# gdb drive for the compatas positive-control: prove a software breakpoint
# in a compat (32-bit) user AS inserts and fires under TCG.
#
# Run:
#   ../build/qemu-system-x86_64 -machine pc -m 64 -kernel compatas \
#       -accel tcg,one-insn-per-tb=on -s -S -serial stdio \
#       -display none -no-reboot &
#   gdb-multiarch -q -x compatas.gdb compatas
#
# flow: attach at reset, aim the debugger at the USER page-table root
# (UPGD = 0x303000) so it can read the compat AS even though the live
# vCPU root at reset does not map it, disassemble it, set a software
# breakpoint on the spin loop, continue, and confirm the vCPU stops there.

set pagination off
set confirm off
set arch i386:x86-64
set $_fail = 0

target remote :1234

# Break in the 64-bit kernel as soon as long mode is entered.  At this
# point the live CR3 is the KERNEL root (KPGD), which maps only 0..16 MiB.
break *long_mode64

# Break on the compat user spin loop.
break *0x1800020

continue

# Hit #1: kernel, CR3 = KPGD.  The compat user VA is ABSENT here -> this is
# the original "Cannot access memory" symptom.  If the read unexpectedly
# succeeds, the kernel root maps the compat AS and the override is unproven,
# so this is an explicit failure, not a silent pass.
printf "\n=== KERNEL (live CR3 = kernel root). read compat AS w/o override ===\n"
python
try:
    gdb.execute("x/2i 0x1800020", to_string=True)
    gdb.write("FAIL: KPGD mapped the compat AS (read of 0x1800020 succeeded)\n")
    gdb.set_convenience_variable("_fail", 1)
except gdb.error as e:
    gdb.write("EXPECTED: " + str(e) + "\n")
end

# Aim debug VA->PA translation at the compat page-table root (UPGD) so the
# same VA resolves.  This is the qemu.Cr3 inspection-AS extension.
maintenance packet Qqemu.Cr3:0x303000
printf "\n=== after Qqemu.Cr3:0x303000 (UPGD) ===\n"
python
try:
    gdb.execute("x/4i 0x1800020", to_string=True)
except gdb.error as e:
    gdb.write("FAIL: UPGD did not map the compat AS: " + str(e) + "\n")
    gdb.set_convenience_variable("_fail", 1)
end

# Drop the kernel breakpoint and run to the compat user spin.
disable 1
continue

printf "\n=== COMPAT USER: software breakpoint fired at the spin loop ===\n"
info registers rip cs eflags
x/4i $rip

# Verify the stop reason, instruction address and code segment: the
# debugger must stop at the compat-user spin (0x1800020, CS = 0x23), not
# merely print "fired".  Carry the result out as a non-zero exit on fail.
if $rip != 0x1800020
    printf "FAIL: stopped at rip=0x%lx, expected 0x1800020\n", $rip
    set $_fail = 1
end
if ($cs & 0xffff) != 0x23
    printf "FAIL: stopped at cs=0x%lx, expected 0x23 (compat user)\n", $cs
    set $_fail = 1
end
if $_fail != 0
    printf "FAIL: compat-AS positive-control did not hold; see above.\n"
    quit 1
end
printf "PASS: compat-AS debug override verified.\n"

detach
quit
