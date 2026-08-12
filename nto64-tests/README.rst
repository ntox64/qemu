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
