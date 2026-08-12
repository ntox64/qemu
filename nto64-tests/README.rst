=========================================
The ``nto64-tests`` QEMU testbed
=========================================

Introduction
------------

This tree carries the devices, machine options and guest tests used to
develop ``nto64`` bring-up code: the pieces of a platform that a kernel
or driver has to handle but that a stock emulator will not produce on
demand.  Its purpose is to make a behaviour *reproducible* - foreign-node
memory, asymmetric cores, a lost interrupt, page-faulting DMA, a resized
BAR, a hub that contradicts itself - so that code can be written against
a case that has already been shown to exist.

Stock QEMU remains the regression baseline for anything ordinary.  It is
not the reference for the capabilities listed here; when one of them is
missing, that is stated under the feature rather than left to a guess.

Building and running
--------------------

::

  ../configure --target-list=x86_64-softmmu
  ninja -C ../build qemu-system-x86_64
  cd nto64-tests
  make run-percputest

``make clean`` removes the built guests.  Building requires ``gcc -m32``
multilib, and the firmware-booted cases require ``bzip2`` to decompress
the OVMF pflash image.

Test shape
~~~~~~~~~~

One assembly source per case: a multiboot header at ``0x100000``, code at
``0x101000``, no libc, and exactly one distinctive ``... VERIFIED`` line
written to COM1 before the guest faults.  A passing test therefore prints
its line and a failing one prints nothing, so the whole matrix is a grep
and no host-side framework sits between a run and its result.

Cases that need firmware are linked as binaries, wrapped as ``PE32+`` by
``pewrap.py``, placed on a FAT16 image by ``fatimg.py`` and booted
through OVMF.

.. note::
   ``-bios`` is not usable with the shipped OVMF image, which is not
   64 KiB aligned; it is only loaded as pflash.  Likewise the guests are
   linked with no build-id note: the default note becomes a sparse high
   ``PT_LOAD`` and the multiboot loader writes its whole span over RAM,
   which erases the ACPI tables.

Run targets are grouped per subsystem under ``rules/``, one makefile per
section below.  ``clean`` and ``.PHONY`` derive from the sources, so
adding a test does not mean editing a list.


Memory and CPU locality
-----------------------

The unit here is the node rather than the CPU: a CPU can only be close to
memory if some memory is somebody's local memory first.

Per-CPU RAM views
~~~~~~~~~~~~~~~~~

``-machine nto64-per-cpu-ram=on`` gives every vCPU its own address space
root: an alias of the whole system memory plus a private 4 KiB page per
CPU in the window at ``nto64-per-cpu-ram-base`` (default ``0xDF000000``).
A test can then distinguish an access to its own page from an access into
another CPU's page, on the CPU side rather than only for a device.

Run ``make run-percputest``.

.. note::
   The private pages are plain RAM at this point and carry no latency or
   coherency model; the shared system-memory alias, firmware and low
   memory are untouched, so a PC guest still boots normally.


Instrumented RAM
~~~~~~~~~~~~~~~~

A RAM region can register a per-access hook
(``memory_region_register_instrument_range()``).  The translation lookaside
buffer entry keeps its direct RAM addend, gains ``TLB_INSTRUMENT``, and
resolves the hook from a parallel ``instr_table`` slot at fill time; the
call itself is emitted inline at translation time, so there is no extra
branch, no basic-block split and no disturbance to translator temporaries.
An access can be counted and optionally delayed by a host busy-wait.

This is what the node slices and ``nto64-barmem`` below use; there is no
standalone run target.

.. note::
   Routing foreign memory through an MMIO trap region instead would also
   count accesses, at a dispatch and a ``cpu_io_recompile`` per access -
   tens of seconds of wall clock per firmware boot, which measures
   nothing.  Instruction fetch is deliberately not instrumented, and the
   exact-count gate is compiled out: the hooks are a latency model, so a
   test should assert a minimum number of deliveries and verify completion
   by data rather than by an exact total.


Node slices and the interconnect
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Machine RAM is partitioned into one slice per node, with
``nto64-numa-cores-per-node`` vCPUs per node (default one); an explicit
``-numa`` topology replaces that shape, including node capacities that
differ from each other.  The ``nto64-remote`` device owns the window: a
foreign slice is reached
through the trap region and is write-behind, so a read immediately after a
remote write returns the previous value, while the node's own page stays
direct RAM.  The ``ccnuma`` control bit makes shared RAM coherent by
construction instead, which is the split a real machine draws between
cache-coherent cross-node traffic and device or peer memory.  Per-node
counters and a configurable ``slice-delay-ns`` sit on the instrumentation
above.

The device is a sysbus device at ``/machine/nto64-remote`` with regions
0 (window), 1 (direct RAM) and 2 (control); the commit-complete interrupt
is wired to ISA line 9.

.. code-block:: text

  ctrl offset  meaning
  0x00         magic
  0x04/0x08    commit delay / jitter, ns
  0x0c         control: bit0 bypass, bit1 write-through,
               bit2 irq-on-commit, bit4 ccnuma
  0x10-0x1c    reads, writes, commits, pending
  0x20         interrupt status (write to clear)
  0x24         last commit latency
  0x28/0x2c    slice read / write counters
  0x3c         slice delay, ns

Run ``make run-slicecount`` for the counters and the delay gate,
``make run-nodeslice`` for the ownership rule that survives more than
one vCPU per node (``nto64-numa-cores-per-node=2``: APIC 1's own slice
must stay uncounted direct RAM while the other node's slice is counted
per access - with one vCPU per node the node id and the ``cpu_index``
happen to agree and a wrong comparison still looks right), plus
``make run-nodeslicebig`` for the same rule when RAM spills above 4G
(``-m 3G`` leaves 2 GiB below 4G while the node slices are 1.5 GiB, so
slicing the low span instead of the machine RAM would move the boundary
out from under node 0's own memory), ``make run-nodeslicemmio`` for a
node 1 vCPU probing the VGA window inside node 0's slice (it first
proves node 0's RAM is counted for it, then reads the window: a device
page inside a foreign range has to stay plain MMIO), and
``make run-unevennuma`` for the range boundaries under an explicit
32 MiB / 96 MiB ``-numa`` topology (the split has to accumulate
``node_mem``; an even ``ram_size / num_nodes`` split would call node
1's 32-64 MiB local for cpu 0), and
``make run-efiremotetest`` to touch a foreign CPU's memory from a
long-mode EFI application with the secondary CPUs brought up through
``INIT``/``SIPI``.

.. note::
   The delay is a host busy-wait, so it models relative timing rather
   than bandwidth.  Write-behind is not a coherence protocol: there is no
   snooping, ownership or partial-line state to corrupt.  The EFI case
   exists because it is the only way to exercise the window while
   firmware, and not our own boot code, owns the page tables.

.. note::
   The instrumented ranges are the node ranges the ``SRAT`` describes,
   clipped to the RAM the machine actually has below 4G (the ranges
   accumulate each node's ``node_mem`` in address order: the implicit
   shape fills equal slices into it and an explicit ``-numa`` topology
   may size the nodes unevenly, so on a machine whose RAM spills above 4G
   the last range can be short and a node whose range starts past the low
   window has no range down here at all).  RAM above 4G stays direct and
   uninstrumented - it is RAM for every vCPU, so it is not part of the
   cross-node model.


Topology through firmware tables
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With ``nto64-per-cpu-ram`` enabled and no ``-numa`` option given, the
derived nodes fill the machine's stock NUMA state, so QEMU's own ACPI
builder emits ``SRAT`` (each RAM range with its proximity domain) and
``SLIT`` (cross-node distance from ``nto64-numa-distance``, default 20).
An explicit ``-numa`` topology always wins and is left untouched.

Run ``make run-numatest`` to walk ``RSDP`` to ``SRAT``/``SLIT`` and check
the ranges and the distance matrix, and ``make run-cxltest`` to validate
the ``CEDT`` ``CHBS`` and ``CFMWS`` entries against the window the machine
builds.

.. note::
   Nothing here defines a new table format - the point is that a topology
   parser is exercised rather than a private channel.  There is no
   runtime node hot-add, and no CXL memory interleave or striping: the
   tables are exposed and checked, not managed.


Per-CPU CPUID and hybrid enumeration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``env->features`` is already per-CPU state, so the machine can vary it per
``cpu_index``: per-CPU CPUID and feature overrides, the Intel hybrid
enumeration leaves (``0x1A`` core type, the hybrid flag), TSC scaling, and
a per-translation-block pause hook that slows the "little" side of the
part.

Run ``make run-cpuidtest`` (BSP + APIC 1, ``-smp 2``): the test asserts
each vCPU's core type (0x40/0x20), AVX2 (BSP only), the hybrid flag and
the max leaf, the TSC scale ratio measured over one shared wall-clock
window, and the #UD the translator must raise for the AP's ``vpaddd``.
The window is a two-way handshake: the BSP opens it, then waits (with a
bound) for the ``tsc_apdone`` flag the AP sets after publishing its own
span, so a vCPU thread that is late to ``tsc_stop`` cannot be read as a
zero span and blamed on the scaling.
``make run-cpuidtestsame`` repeats it with *both* cores in the 0x40
class: there the core-class bit in the TB key cannot separate them, so
only the effective per-CPU feature set keeps the AP from running the
BSP's AVX2 code (its #UD is the regression).

.. note::
   Stock x86 TCG is homogeneous, so a test that assumes every CPU matches
   proves nothing, and a kernel that caches CPUID once merely looks
   correct.  Only x86 is covered: this tree's ARM ``virt`` machine
   enumerates one CPU type for every slot, so mixed-core ARM is a later
   QEMU problem, and the per-CPU override is the portable stand-in rather
   than an ARM test.


Interrupts
----------

Interrupt delivery is only observable if a device-side count can be
compared against a guest-side handler count, so every source here reports
how many times it fired.

On-demand interrupt source
~~~~~~~~~~~~~~~~~~~~~~~~~~

``nto64-irqgen`` (PCI ``1234:1ee7``) raises an interrupt on an MMIO write
with the delivery path selectable: legacy ``INTx`` through the PIC or the
I/O APIC, or MSI from its own capability at configuration offset ``0x60``;
edge or level; with an auto-repeat timer for storms.  BAR0 is the control
region: ``0x00`` magic, ``0x04`` control (bit0 enable, bit1 edge, bit2
msi, bit3 storm), ``0x08`` delivered count, ``0x0c`` period in
microseconds, ``0x10`` trigger, ``0x14`` status.

Run ``make run-irqtest``.

.. note::
   Without a device-side count, "the interrupt was slow" and "the
   interrupt never arrived" are the same observation, and every interrupt
   case in this tree depends on telling them apart.  One source per
   device: several devices storming at once is only as interesting as the
   I/O APIC makes it.
