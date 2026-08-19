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


MSI-X with per-vector destinations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``nto64-msix`` (PCI ``1234:1ee8``, ``vectors`` default 4) carries its
MSI-X table and PBA in an exclusive BAR1, with BAR0 controls ``0x00``
magic, ``0x04`` control (bit0 enable), ``0x08`` fire count, ``0x0c``
vector select, ``0x10`` trigger, ``0x14`` fire mask and ``0x18`` onwards
per-vector counts.

Run ``make run-msixtest``, which brings up the secondary CPUs under OVMF,
aims four vectors at four local APICs with distinct masks, fires them
individually and as a burst, and compares each APIC's handler count
against the device's per-vector counters.

.. note::
   An exclusive BAR for the table is deliberate: a mapping error cannot
   hide behind a neighbouring register file.  A destination the guest did
   not arm is dropped rather than delivered somewhere convenient.  Under
   TCG, same-vector edge messages fired rapidly coalesce in the IRR, as
   edge-triggered semantics require, so a case asserts a minimum
   delivery count and proves completion by data.


DMA
---

Node binding, address translation, peer targets and faulting all change
what one engine sees, so they are one device with orthogonal controls
rather than several devices.

Node-bound DMA engine
~~~~~~~~~~~~~~~~~~~~~

``nto64-dma`` (PCI ``1234:1ee9``) roots its DMA address space at the
``node`` vCPU's view, so device DMA follows the same per-CPU shape as a
CPU access: the node's own window page is direct RAM, a foreign page
traverses the interconnect, plain RAM is the normal system alias.  Its
completion is an MSI-X vector the guest targets at that node's CPU.
``max-xfer`` reaches 1 GiB and ``queues`` (default 4) binds queue *i* to
vCPU *i* with completion vector *i*.

.. code-block:: text

  BAR0  0x00  magic
        0x04  control: bit0 start, bit1 irq-on-done, bit2 ring mode
        0x08/0x10/0x18  source, destination, size
        0x1c  status;  0x20/0x24  transfers, bytes
        0x28-0x38  legacy ring (base, count, stride, done) - aliases queue 0
        0x3c-0x50  queue count, select, ring base/count/stride, start
        0x58-0x64  per-queue done, transfers, bytes

Descriptor ring entries are source, destination, length and flags (bit0
valid, bit1 completed by the device, bit2 peer destination, bit3 peer
source).  Bulk transfers are chunked and both modes run from a bottom
half.  Run ``make run-msixtest`` for the completion and locality checks.

.. note::
   Doing the copy inside the MMIO write handler would hold the BQL and
   re-enter other regions mid-handler, so transfers are always
   asynchronous - and ordering between two queues is then QEMU's
   scheduling, not a hardware queue's.  Errors are never reported as
   success: starting while busy latches an error status and a ring whose
   last entry is not valid completes with an error, because a test device
   that quietly succeeds hides precisely the driver bugs this tree exists
   to find.


Spurious raises and the masked-vector path
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Writing the ``SPR`` magic to ``nto64-msix`` BAR0 offset ``0x60`` raises
the selected vector ignoring the device enable bit, and leaves it pending
in the PBA when the vector is masked.  The fire counters do not move; a
separate spurious counter at ``0x64`` does.  This is part of
``make run-msixtest``: an unmasked raise advances exactly the targeted
APIC's handler count, a masked one arrives at unmask, and neither changes
what the device claims to have sent.

.. note::
   Only one unexpected-delivery shape is modelled - a raise with no
   doorbell behind it.  A device that raises the *wrong* vector number is a
   different fault and is not produced here.  This case shares the
   ``msixtest`` harness with the DMA completion phases below, so it lands
   just after them.


IOMMU-rooted DMA
~~~~~~~~~~~~~~~~

``nto64-dma,iommu=on`` roots the DMA address space at
``pci_device_iommu_address_space()`` instead of the vCPU view, so guest
IOVAs are translated by the guest's own tables and node binding becomes a
property of an IOMMU domain.

Run ``make run-iommutest``, which builds VT-d root, context and an L2
with 2 MiB pages from scratch and then shows the translated path through
the IOMMU against the bypassing path of the node-bound device.

.. note::
   Only the DMA-remapping half of VT-d is exercised: no interrupt
   remapping, no queued invalidation, no PASID.  The contrast between the
   two roots is the point - it is the only way a test can show which path
   a transfer actually took.


Peer-to-peer DMA
~~~~~~~~~~~~~~~~

With ``peer=<dev>`` and ``peer-bar=<n>``, control bit3 selects peer mode
and bit4 the direction, and the ring flags mark an entry's source or
destination as the peer.  The peer's BAR becomes an address space, so a
transfer moves RAM to device BAR, device BAR to RAM, or within the BAR,
with neither a CPU nor guest RAM in the middle.  Separate peer counters
(``0x68``, ``0x6c``, ``0x70``) record what went through the link.

Run ``make run-p2ptest`` with two endpoints on one bus.

.. note::
   Fabric behaviour around a peer transaction - relaxed ordering, ACS, an
   IOMMU's peer window rules - is not modelled, since both endpoints hang
   off the same root bus.  What is covered is the failure a driver
   actually sees: a BAR mapped into another BAR reading back zeros
   without an error.


Device page faults
~~~~~~~~~~~~~~~~~~

``nto64-dma`` can fault on a guest translation: a window at BAR0
``0x88``/``0x8c``/``0x90`` (base, limit, enable), inject-on-next /
resolve-retry / fault-IRQ-enable at ``0x74``, fault status ``0x78``,
faulting address ``0x7c``/``0x80``, fault count ``0x84`` and status bit3,
with one extra MSI-X vector carrying the fault interrupt.

Run ``make run-pritest``: arm the window, take the fault on its own
vector, read back the address and status, fix the mapping, write resolve
and verify that the interrupted transfer is retried to completion.

.. note::
   This is PRI-like, not PRI: there is no page request queue, no group
   response and no invalidation semantics beyond the retry.  The detail
   that matters for a driver is partial progress - a chunk overlapping the
   window faults *after* the earlier chunks have completed and been
   counted, so a fault does not mean "nothing happened".


AER error injection
~~~~~~~~~~~~~~~~~~~

``nto64-dma`` is an express device with a PCIe endpoint capability and
the Advanced Error Reporting extended capability; writing to BAR0
``0x94`` arms a correctable, an uncorrectable non-fatal or a fatal error
and injects it through ``pcie_aer_inject_error()``.

Run ``make run-aertest``, which walks the extended capability list via
ECAM, checks the status bits, the big-endian TLP header log, the injection
count and the write-1-to-clear behaviour, and confirms a fatal error is
distinguishable from a non-fatal one in the log a driver would print.

.. note::
   Injection only.  There is no link training state machine, so a real
   downstream-port containment and recovery sequence is out of reach.
   Reaching the capability at all is part of the test: ``CF8``/``CFC``
   only addresses the first 256 bytes and wraps above that, so anything
   from ``0x100`` on has to go through ECAM.


PCI BARs
--------

Big-BAR device memory
~~~~~~~~~~~~~~~~~~~~~

``nto64-barmem`` (PCI ``1234:beef``) is the device class at the end of
the hierarchy: BAR0 is a large memory region backed by a host memory
backend, switchable between a RAM fast path and trapped MMIO, and BAR1
carries the controls - ``0x00`` magic, ``0x04`` doorbell, ``0x08`` size,
``0x0c`` mode/irq, ``0x10`` interrupt count, ``0x14``/``0x18`` BAR access
counters and ``0x1c`` BAR delay.  The fast path is instrumented, so a BAR
touch counts and delays exactly like a foreign-node RAM access.

Run ``make run-barmemtest``.

.. note::
   A doorbell that raises ``INTx`` or MSI is what proves a write landed
   where the interrupt claims it did.  Aliasing a memory backend is not a
   device with a queue, a doorbell FIFO or write-combining behaviour, and
   the delays are relative rather than host-speed.  One layout rule is
   enforced here because it is easy to get wrong: a 64-bit BAR0 must be
   followed by region 2, since ``pci_bar()`` places region *N* at
   ``0x10 + N*4`` and a region-1 control BAR clobbers BAR0's high write
   mask.


Resizable BAR
~~~~~~~~~~~~~

``nto64-barmem`` exposes the Resizable BAR extended capability as the
first entry in the extended list at ECAM offset ``0x100``, in a 4 KiB
configuration space.  ``rebar-sizes`` lists the supported sizes (64M,
128M, 256M, 512M by default) and BAR0 resizes in place; the capability is
omitted entirely when the initial ``bar-size`` is not one of them.

Run ``make run-rebartest``, which walks the size list, resizes down and up
while writing and reading across the new boundary, and confirms the
mapping was torn down and re-established rather than left stale.

.. note::
   The BAR configuration write mask and the guest's size probe follow
   every resize, otherwise the probe keeps reporting the old size and the
   test proves nothing.  Only one BAR is resizable, and there is no
   negotiation with a hypervisor.


Multi-GiB BAR and SR-IOV enumeration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The resizable list also covers the several-GiB 64-bit BAR mapped above
4G, the shape device memory that a CPU pointer-chases actually ships in.
Run ``make run-samtest`` to map it, write and read back across the top.
Run ``make run-sriovtest`` against a stock SR-IOV layout to walk the
capability, read the VF device ID, stride and offset, enable VF memory
space and check that the VFs appear where the capability says they
should.

.. note::
   Both fail at range or width rather than at logic: a 32-bit-only
   mapping breaks at the top of a multi-GiB BAR, and anything at ``0x100``
   and above is unreachable through ``CF8``/``CFC``.  The VFs come from a
   stock device, so VF flavour heterogeneity, per-VF PRI and ATS
   invalidation are not covered.  Guest-side walks keep their pointers in
   callee-saved registers, because the print helpers clobber
   caller-saved ones between a configuration read and its comparison.


Enumeration and placement from the guest
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

No device is needed for these two, only a bus: ``make run-pcitest``
enumerates, sizes each BAR by writing all-ones, picks a free hole,
reassigns, enables memory space and confirms the device answers at the new
address; ``make run-numapcitest`` then places a BAR near the memory its
CPU owns and checks the assignment landed inside that window.

.. note::
   Firmware assigns BARs during POST, so the assignment protocol is only
   visible to a guest that reassigns afterwards.  Both run at ``-smp``
   with the per-CPU views, because a placement test on one CPU is not a
   placement test.  Host-bridge refusals - bus number windows, an
   above-4G prefetchable limit already programmed by firmware - are only
   partly reachable on q35.


Storage
-------

Transport-level interrupt loss
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``nto64-msix-drop=N`` on any virtio-pci device suppresses the *N*th
notification's interrupt once: the used-ring entry still lands, delivery
resumes on the next notification, and a device reset re-arms the counter.

.. note::
   The knob lives in the transport so every virtio device shares it
   instead of carrying its own copy.  It is one-shot by design - a device
   that stops interrupting forever is a different failure with a different
   recovery.  First users are virtio-scsi (``run-scsiintr``) and
   virtio-net (``run-netmsidrop``).


virtio-blk bring-up and ring exhaustion
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Run ``make run-vblktest`` for the clean path and
``run-vblkbadtrack``, ``run-vblkerr``, ``run-vblkpersist`` for the
``blkdebug`` profiles in ``vblk-*.conf``, plus ``run-vblkringfull`` for a
ring that stops consuming.

.. note::
   Bring-up order (submission before the device is ready), a ring that
   stops consuming, and an over-long descriptor chain are the three shapes
   a block driver gets wrong without noticing.  ``blkdebug`` injects at
   the block layer, so it cannot express a device that fails a request and
   then *lies about why* on the retry; the persisting-error profile is the
   closest available approximation.


virtio-scsi and scsi-hd faults
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``scsi-hd`` gains ``nto64-drop-sector=a:b:c``, a colon-separated list of
failing sectors (eight slots, with a warning when truncated), and the
sense, media-change, capacity-change, write-protect and bring-up-readiness
shapes are driven from the guest.

Run ``make run-scsitest``, ``run-scsifault``, ``run-scsierr``,
``run-scsibringup``, ``run-scsimedia``, ``run-scsiwp``, and
``run-scsiintr``/``run-scsiintrinj`` for the lost completion.

.. note::
   The task-management coverage is where the wire format bites: abort task
   set, clear task set, the ``I_T`` nexus reset and an abort racing a
   command that is completing, with the subtypes a driver has to encode
   correctly.  A unit that reports a failure once is easy; one that reports
   it *differently* on retry, which is what breaks caching drivers, is
   only partly covered.


SATA/AHCI bad track, retry and lost MSI
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The IDE/AHCI path gains bad-track, device retry, a wedged drive, slow
media and NCQ error reporting, and ``ich9-ahci`` gains ``nto64-msi-drop``
for its MSI (not MSI-X) completions.

Run ``make run-satatest``, ``run-satabadtrack``, ``run-sataerr``,
``run-satapersist``, ``run-sataslow``, ``run-satastuck``, ``run-satancq``,
``run-satasdblie``, ``run-satad2hlie``, and ``run-ahciintr`` /
``run-ahciintrdrop``.

.. note::
   AHCI completes through two channels - the SDB FIS carries an NCQ
   command's status while the D2H FIS carries the device-ready and ``BSy``
   state - and either can contradict the other, which is invisible to a
   driver that trusts one.  The two ``*-lie`` cases exist for that.  No
   cable or PHY behaviour beyond link state, and no port multiplier.


NVMe multi-queue stress
~~~~~~~~~~~~~~~~~~~~~~~

Run ``make run-nvmetest``: it builds the admin and I/O queues from
scratch against the stock ``nvme`` device and drives them concurrently
with per-queue MSI-X vectors.

.. note::
   No testbed change is needed for this one, and that is worth stating:
   queue creation order and completions against the right queue are the
   parts a driver cannot fake.  Two limits of the environment matter:
   same-vector interrupts fired rapidly coalesce in the local APIC IRR, so
   the case asserts minimum deliveries and verifies by polling and data;
   and firmware state is real - SeaBIOS leaves the controller enabled with
   its own queues, so a driver that does not reset first writes enable bits
   that are already no-ops.


NVMe fault injection, storms and namespace edge states
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Controller properties and guest-armed controls cover cold and wear
latency, surprise unplug, a link-generation downgrade, attach, reset and
hotplug storms, AER and namespace-not-ready, a stalled ``Format NVM``,
write-protect, a dead completion queue that never posts, a dead DMA path
behind a live MMIO one, and reservation conflict across a
multi-controller subsystem; ``nvme-cold.conf`` supplies the block-layer
side.

Run ``make run-nvmefault`` and the ``run-nvmeattach``, ``run-nvmedead``,
``run-nvmedeadq``, ``run-nvmedmarev``, ``run-nvmehang``, ``run-nvmelate``,
``run-nvmereplug``, ``run-nvmerdylie``, ``run-nvmestuck``, ``run-nvmewp``,
``run-nvmeaer``, ``run-nvmenotready``, ``run-nvmeformatstall``,
``run-nvmeformatreset`` and ``run-nvmeresv`` cases.

.. note::
   Every case ends in a recovery proof rather than an error report: the
   driver has to reach a consistent state again.  A surprise unplug here
   removes the device from the guest's view; the electrical and link
   sequence, and power-loss atomics such as the ``CAP.CPS``/``FUAB`` race,
   are not modelled.

.. note::
   The reset paths wipe the admin CQ (and the I/O rings) while the
   controller is still disabled, and never take a completion for granted
   by its phase bit alone: every admin command stamps a CID that never
   repeats across a controller life, and a completion is only consumed
   when the phase *and* the CID match.  A stale phase-1 entry left at the
   head of an un-wiped ring can therefore not be returned as the status
   of the next command, which is what the revive and format-reset paths
   probe for with a planted entry before re-enabling the controller.

NVMe lost completion interrupt
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``nvme,nto64-msix-drop=N`` suppresses the *N*th deliverable completion
interrupt once and re-arms on reset.  Run ``make run-nvmeintr`` and
``run-nvmeintrdrop``, which prove the submit, bounded interrupt wait, poll
fallback and resume cycle on a controller that keeps completing commands.

.. note::
   The storage-side instance of the transport case above.  A controller
   that stops posting completions at all is the dead-queue case, which is
   a different test with a different recovery.


USB
---

xHCI interrupt loss
~~~~~~~~~~~~~~~~~~

``qemu-xhci`` can drop the interrupt for one transfer while still writing
the completion into the event ring.  Run ``make run-usbintr`` and
``run-usbintrdrop``.

.. note::
   A USB completion is ring state *plus* an interrupt, and losing the
   second is invisible from the first, so the case is verified by data and
   by the device-side counters rather than by counting deliveries.


``usb-nto64`` and the storage/UAS fault slice
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A control-only full-speed device whose enumeration behaviour is
configured per instance: ``power-ma`` (the current it declares, in 2 mA
units), ``bad-desc``, ``no-config``, ``stall-config``, ``reset-hang``,
``composite`` and ``kill-iface``.  Mass storage and UAS get the
``blkdebug``-backed data-path faults in ``usb-*.conf``.

Run ``make run-usbstoragetest``, ``run-usbstoragebadtrack``,
``run-usbstorageerr``, ``run-usbstoragepersist``, ``run-usbstoragestall``,
``run-usbstoragedrop``, ``run-uastest``, ``run-uabadtrack``,
``run-uaerr``, ``run-uapersist``.

.. note::
   A power-budget check cannot be tested against a device that asks for
   less than the bus provides, which is why ``power-ma`` is a property.
   The device is full-speed and control-only: SuperSpeed bring-up,
   isochronous endpoints and descriptor-sequence handling are separate
   cases.


Non-disk USB misbehaviour
~~~~~~~~~~~~~~~~~~~~~~~~~

HID report faults, a stalled interrupt endpoint, a dead interface inside
a composite device, and over-current on a hub port.  Run
``make run-usbmisbehave``, ``run-usbbaddesc``, ``run-usbbadreport``,
``run-usbstallintr``, ``run-usbdead``, ``run-usbenum`` and
``run-usbpower``.

.. note::
   A HID or composite device fails differently from mass storage, and a
   stack that only handles the storage case has never met a report that
   never arrives or an interface that is present but dead.  The report
   machinery is a stub on purpose: the interesting behaviour is the
   stack's reaction to its absence.


Hub over-current matrix
~~~~~~~~~~~~~~~~~~~~~~~

A hub can report over-current in the shapes the specification says must
not happen: on a port it is powering, one that never clears, one that
changes state with no status change, and a port-power budget that lies.
Run ``make run-usboc``, ``run-usbocpersist``, ``run-usboclevel``,
``run-usbocchange``, ``run-usbocstatus`` and ``run-usbocclear``.

.. note::
   The question each case asks is whether the driver re-reads port status
   or trusts a cached value.  Power itself is a model: a port that
   over-currents does not actually interrupt power delivery to a
   co-scheduled device beyond what the hub's state machine reports.


Mid-transfer disconnect and port churn
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``nto64-disconnect`` removes a device while a transfer is in flight
(optionally re-plugging it after ``nto64-replug-ms``), and a hub with
``nto64-port-storm`` flaps a port on a timer.  Run
``make run-usbeject``, ``run-usbejectinflight``, ``run-usbdisconnect`` and
``run-usbstorm``.

.. note::
   These are the two ways a USB stack loses state it did not know it held.
   What is checked is that it notices, quiesces and re-enumerates without
   wedging a controller that is still healthy.  A disconnect is a
   device-side event: there is no VBUS or connector timing, and the hub
   keeps its own port state rather than emulating an electrical bounce.


Isochronous NAK re-arm and recovery without a controller reset
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

An isochronous endpoint that NAKs has to be re-armed, and a device that
reappears after a replug has to recover without ``HCRST``, which clears
the command and event rings, the slots and the endpoints together.  Run
``make run-usbisoc``, ``run-usbflushlie``, ``run-usbwp`` and
``run-usbejectinflight``.

.. note::
   The difference between a driver that resets and one that recovers is
   observable here: after the narrow recovery the prefill pattern still
   survives, because the backend was never touched.  Isochronous transfer
   is NAK-and-re-arm only - bandwidth scheduling, microframes and real
   sample delivery are not modelled.
