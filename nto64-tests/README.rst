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
``nto64-numa-cores-per-node`` vCPUs per node (default one).  The
``nto64-remote`` device owns the window: a foreign slice is reached
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

Run ``make run-slicecount`` for the counters and the delay gate, and ``make run-efiremotetest`` to touch a foreign
CPU's memory from a long-mode EFI application with the secondary CPUs
brought up through ``INIT``/``SIPI``.

.. note::
   The delay is a host busy-wait, so it models relative timing rather
   than bandwidth.  Write-behind is not a coherence protocol: there is no
   snooping, ownership or partial-line state to corrupt.  The EFI case
   exists because it is the only way to exercise the window while
   firmware, and not our own boot code, owns the page tables.
