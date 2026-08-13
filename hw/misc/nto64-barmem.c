/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * nto64-barmem: test PCI device with a big BAR backed by a host memory
 * backend.
 *
 * This is the "device/VRAM" memory-class testbed for the nto64 /
 * nto-user work: a guest measures throughput between emulated RAM
 * and the BAR (the device class of the storage -> RAM -> device/VRAM
 * memory hierarchy), and the BAR/config/doorbell shape doubles as
 * the reference for the work (
 * 53-55).
 *
 *   BAR0: big memory region, aliased to the memdev backend
 *         (-object memory-backend-ram,size=...,id=vram) or to an
 *         internal anonymous region when no backend is given.  A
 *         control bit switches BAR0 between the RAM-backed fast path
 *         and a trap-based MMIO path (device-model access to the same
 *         storage), for the emulated-RAM vs device-memory throughput
 *         comparison.
 *         The instrumented direct-RAM path (counters 0x14/0x18,
 *         delay 0x1c) works on the backend itself, so a memdev-backed
 *         BAR gets the same counting/latency treatment as the
 *         internal storage.  The memdev must be dedicated to this
 *         device: a backend also mapped elsewhere (e.g. machine RAM)
 *         would count and delay those accesses too.
 *         PCIe Resizable BAR (REBAR): BAR0 is resizable between
 *         64 MiB and 512 MiB via the REBAR extended capability at
 *         ECAM offset 0x100 (PCI_EXT_CAP_ID_REBAR, one variable BAR,
 *         sizes 64M/128M/256M/512M).  Writing the REBAR Control
 *         BAR Size field resizes the BAR in place; the guest then
 *         re-probes/reassigns the BAR like any REBAR device.
 *   BAR1: 4 KiB control MMIO:
 *           0x00 magic "NTO6"
 *           0x04 doorbell counter (write rings)
 *           0x08 bar0 size
 *           0x0c mode/irq control: bit0 BAR0 MMIO mode,
 *                bit1 doorbell->IRQ enable, bit2 edge(1)/level(0),
 *                bit3 prefer MSI
 *           0x10 irq count (write 0 clears)
 *           0x14 BAR0 read count (instrumented direct-RAM path)
 *           0x18 BAR0 write count
 *           0x1c BAR0 manual access delay in ns (0 = off)
 *           0x20 doorbell IRQ status: bit0 level INTx active
 *                (write 1 acknowledges / deasserts)
 *
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/pcie.h"
#include "hw/pci/msi.h"
#include "hw/qdev-properties.h"
#include "system/hostmem.h"
#include "qemu/timer.h"
#include "qom/object.h"

#define TYPE_NTO64_BARMEM "nto64-barmem"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64BarmemState, NTO64_BARMEM)

#define NTO64_BARMEM_VENDOR      0x1234
#define NTO64_BARMEM_DEVICE      0xBEEF
#define NTO64_BARMEM_CLASS       0x0500      /* class 05, subclass 00 */
#define NTO64_BARMEM_REVISION    1
#define NTO64_BARMEM_MAGIC       0x4e544f36u /* "NTO6" */
#define NTO64_BARMEM_BAR0_DEFAULT (256 * MiB)
#define NTO64_BARMEM_CTRL_SIZE   0x1000

/*
 * REBAR: one variable BAR (BAR0), supported sizes 64M/128M/256M/512M
 * (size index n = 2^(20+n) bytes).  The capability is the first PCIe
 * extended capability (ECAM offset 0x100), reachable on q35.
 */
#define NTO64_BARMEM_PCIE_CAP_OFF 0xe0
#define NTO64_BARMEM_REBAR_CAP_OFF 0x100
#define NTO64_BARMEM_REBAR_SIZES \
    ((1u << 6) | (1u << 7) | (1u << 8) | (1u << 9))

#define NTO64_BARMEM_CTRL_MMIO   0x1     /* BAR0 trap-based MMIO path */
#define NTO64_BARMEM_CTRL_IRQ    0x2     /* doorbell raises an IRQ */
#define NTO64_BARMEM_CTRL_EDGE   0x4
#define NTO64_BARMEM_CTRL_MSI    0x8

typedef struct Nto64BarmemState {
    PCIDevice pdev;

    HostMemoryBackend *hostmem;   /* memdev property */
    MemoryRegion bar0_container;  /* BAR0: container of the two paths */
    MemoryRegion bar0_alias;      /* RAM-backed fast path */
    MemoryRegion bar0_mmio;       /* trap-based device-model path */
    MemoryRegion bar0_storage;    /* internal anon RAM if no backend */
    MemoryRegion ctrl;
    uint8_t *storage_ptr;         /* host pointer to the BAR storage */
    uint64_t bar0_size;
    uint32_t doorbell;
    uint32_t irq_control;
    uint32_t irq_count;
    uint32_t bar_reads, bar_writes;
    uint32_t bar_delay_ns;
    bool irq_level_active;
    uint32_t rebar_sizes;     /* supported REBAR size-index mask */
    uint16_t rebar_cap;       /* extended cap offset (0 if disabled) */
} Nto64BarmemState;

/*
 * Per-access hook for the instrumented BAR0 fast path (internal
 * storage): count and optionally inject a manual latency, like the
 * whole-RAM slices.  Device/VRAM-class memory is direct host RAM -
 * as fast as emulation allows - with measurement on top.
 */
static void nto64_barmem_hook(void *opaque, unsigned int vcpu_index,
                              hwaddr addr, unsigned size, bool is_write)
{
    Nto64BarmemState *s = opaque;

    (void)vcpu_index;
    (void)addr;
    (void)size;
    if (is_write) {
        qatomic_inc(&s->bar_writes);
    } else {
        qatomic_inc(&s->bar_reads);
    }
    if (s->bar_delay_ns) {
        int64_t start = qemu_clock_get_ns(QEMU_CLOCK_HOST);

        while (qemu_clock_get_ns(QEMU_CLOCK_HOST) <
               start + (int64_t)s->bar_delay_ns) {
        }
    }
}

/* --- BAR0 MMIO path: device-model access to the same storage ---- */

static uint64_t nto64_barmem_mmio_read(void *opaque, hwaddr addr,
                                       unsigned size)
{
    Nto64BarmemState *s = opaque;
    uint64_t v = 0;

    if (addr + size <= s->bar0_size) {
        memcpy(&v, s->storage_ptr + addr, size);
    }
    return v;
}

static void nto64_barmem_mmio_write(void *opaque, hwaddr addr,
                                    uint64_t val, unsigned size)
{
    Nto64BarmemState *s = opaque;

    if (addr + size <= s->bar0_size) {
        memcpy(s->storage_ptr + addr, &val, size);
    }
}

static const MemoryRegionOps nto64_barmem_mmio_ops = {
    .read = nto64_barmem_mmio_read,
    .write = nto64_barmem_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
};

/* --- doorbell IRQ ---- */

static void nto64_barmem_irq_fire(Nto64BarmemState *s)
{
    bool use_msi = (s->irq_control & NTO64_BARMEM_CTRL_MSI) &&
                   msi_enabled(&s->pdev);

    s->irq_count++;
    if (use_msi) {
        msi_notify(&s->pdev, 0);
    } else if (s->irq_control & NTO64_BARMEM_CTRL_EDGE) {
        pci_set_irq(&s->pdev, 1);
        pci_set_irq(&s->pdev, 0);
    } else {
        s->irq_level_active = true;
        pci_set_irq(&s->pdev, 1);
    }
    if (s->irq_count <= 8 || (s->irq_count & (s->irq_count - 1)) == 0) {
        info_report("nto64-barmem: doorbell irq %u (%s)",
                    s->irq_count, use_msi ? "msi" : "intx");
    }
}

static uint64_t nto64_barmem_ctrl_read(void *opaque, hwaddr addr,
                                       unsigned size)
{
    Nto64BarmemState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x00:
        return NTO64_BARMEM_MAGIC;
    case 0x04:
        return s->doorbell;
    case 0x08:
        return (uint32_t)s->bar0_size;
    case 0x0c:
        return s->irq_control;
    case 0x10:
        return s->irq_count;
    case 0x14:
        return s->bar_reads;
    case 0x18:
        return s->bar_writes;
    case 0x1c:
        return s->bar_delay_ns;
    case 0x20:
        return s->irq_level_active ? 1 : 0;
    default:
        return 0;
    }
}

static void nto64_barmem_ctrl_write(void *opaque, hwaddr addr,
                                    uint64_t val, unsigned size)
{
    Nto64BarmemState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x04:                  /* doorbell: ring, optionally an IRQ */
        s->doorbell++;
        if (s->irq_control & NTO64_BARMEM_CTRL_IRQ) {
            nto64_barmem_irq_fire(s);
        }
        if (s->doorbell <= 8 || (s->doorbell & (s->doorbell - 1)) == 0) {
            info_report("nto64-barmem: doorbell %u", s->doorbell);
        }
        break;
    case 0x0c:                  /* mode/irq control */
        s->irq_control = (uint32_t)val;
        if (s->irq_control & NTO64_BARMEM_CTRL_MMIO) {
            memory_region_set_enabled(&s->bar0_alias, false);
            memory_region_set_enabled(&s->bar0_mmio, true);
        } else {
            memory_region_set_enabled(&s->bar0_mmio, false);
            memory_region_set_enabled(&s->bar0_alias, true);
        }
        break;
    case 0x10:
        s->irq_count = 0;
        break;
    case 0x1c:
        s->bar_delay_ns = (uint32_t)val;
        break;
    case 0x20:                  /* doorbell IRQ ack: deassert level INTx */
        if (val & 1) {
            s->irq_level_active = false;
            if (!((s->irq_control & NTO64_BARMEM_CTRL_MSI) &&
                  msi_enabled(&s->pdev))) {
                pci_set_irq(&s->pdev, 0);
            }
        }
        break;
    default:
        break;
    }
}

static const MemoryRegionOps nto64_barmem_ctrl_ops = {
    .read = nto64_barmem_ctrl_read,
    .write = nto64_barmem_ctrl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

/*
 * Resize BAR0 to the REBAR size index @idx (in place).  The PCI core's
 * notion of the BAR size (io_regions[0].size) is updated so the size
 * probe and pci_bar_address use the new size; the container/alias/MMIO
 * regions shrink or grow over the backing storage (allocated at the
 * max supported size).
 */
static void nto64_barmem_rebar_set_size(Nto64BarmemState *s, unsigned idx)
{
    uint64_t newsize = 1ULL << (20 + idx);
    MemoryRegion *backing = s->hostmem
        ? host_memory_backend_get_memory(s->hostmem)
        : &s->bar0_storage;

    if (!(s->rebar_sizes & (1u << idx)) ||
        newsize > memory_region_size(backing) ||
        newsize == s->bar0_size) {
        return;
    }

    memory_region_set_size(&s->bar0_container, newsize);
    memory_region_set_size(&s->bar0_alias, newsize);
    memory_region_set_size(&s->bar0_mmio, newsize);
    s->bar0_size = newsize;
    s->pdev.io_regions[0].size = newsize;
    /*
     * The BAR config wmask (set at registration from the old size)
     * must follow the resize, or the guest's size probe keeps seeing
     * the original mask.
     */
    pci_set_long(s->pdev.wmask + pci_bar(&s->pdev, 0),
                 ~(newsize - 1) & 0xffffffff);
    info_report("nto64-barmem: BAR0 resized to %" PRIu64 " MiB",
                newsize / MiB);
}

static void nto64_barmem_config_write(PCIDevice *pci_dev, uint32_t addr,
                                      uint32_t val, int len)
{
    Nto64BarmemState *s = NTO64_BARMEM(pci_dev);

    pci_default_write_config(pci_dev, addr, val, len);

    if (s->rebar_cap &&
        ranges_overlap(addr, len, s->rebar_cap + PCI_REBAR_CTRL, 4)) {
        uint32_t ctrl = pci_get_long(pci_dev->config +
                                     s->rebar_cap + PCI_REBAR_CTRL);
        unsigned idx = (ctrl & PCI_REBAR_CTRL_BAR_SIZE) >>
                       PCI_REBAR_CTRL_BAR_SHIFT;

        nto64_barmem_rebar_set_size(s, idx);
    }
}

static void nto64_barmem_realize(PCIDevice *pci_dev, Error **errp)
{
    Nto64BarmemState *s = NTO64_BARMEM(pci_dev);
    MemoryRegion *mem;
    uint64_t size = s->bar0_size;
    uint64_t storage_size = size;
    int i;

    if (!is_power_of_2(size)) {
        error_setg(errp, "nto64-barmem: bar-size must be a power of two");
        return;
    }

    if (s->hostmem) {
        mem = host_memory_backend_get_memory(s->hostmem);
        size = MIN(size, memory_region_size(mem));
        if (!is_power_of_2(size)) {
            error_setg(errp, "nto64-barmem: backend size 0x%" PRIx64
                       " is not a power of two", memory_region_size(mem));
            return;
        }
        s->storage_ptr = memory_region_get_ram_ptr(mem);
        /*
         * Instrumented direct-RAM path on the backend itself: the TCG
         * TLB fill resolves the hook from the leaf RAM region, so
         * attaching it to the backend's MemoryRegion makes
         * bar_reads/bar_writes and bar-delay work for memdev-backed
         * BARs (the realistic large-VRAM path), exactly like the
         * internal anon storage below.
         */
        memory_region_set_instrumented(mem, nto64_barmem_hook, s);
        /* Clamp the REBAR size set to what the backend can hold. */
        for (i = 0; i < 32; i++) {
            if ((s->rebar_sizes & (1u << i)) &&
                (1ULL << (20 + i)) > memory_region_size(mem)) {
                s->rebar_sizes &= ~(1u << i);
            }
        }
        info_report("nto64-barmem: BAR0 %" PRIu64 " MiB aliased to backend '%s'",
                    size / MiB, object_get_canonical_path(OBJECT(s->hostmem)));
    } else {
        /*
         * Back the BAR with enough storage for the largest REBAR size
         * so resizing can grow in place.
         */
        if (s->rebar_sizes) {
            int max_idx = 31 - clz32(s->rebar_sizes);
            storage_size = MAX(storage_size, 1ULL << (20 + max_idx));
        }
        memory_region_init_ram(&s->bar0_storage, OBJECT(s),
                               "nto64-barmem-ram", storage_size, errp);
        if (*errp) {
            return;
        }
        mem = &s->bar0_storage;
        s->storage_ptr = memory_region_get_ram_ptr(&s->bar0_storage);
        /* Instrumented direct-RAM path: count + optional latency. */
        memory_region_set_instrumented(&s->bar0_storage,
                                       nto64_barmem_hook, s);
        info_report("nto64-barmem: BAR0 %" PRIu64 " MiB (internal anon RAM)",
                    size / MiB);
    }
    s->bar0_size = size;

    /* BAR0 container: RAM fast path + MMIO trap path on one storage. */
    memory_region_init(&s->bar0_container, OBJECT(s),
                       "nto64-barmem-bar0", size);
    memory_region_init_alias(&s->bar0_alias, OBJECT(s),
                             "nto64-barmem-bar0-ram", mem, 0, size);
    memory_region_init_io(&s->bar0_mmio, OBJECT(s),
                          &nto64_barmem_mmio_ops, s,
                          "nto64-barmem-bar0-mmio", size);
    memory_region_add_subregion(&s->bar0_container, 0, &s->bar0_alias);
    memory_region_add_subregion(&s->bar0_container, 0, &s->bar0_mmio);
    memory_region_set_enabled(&s->bar0_mmio, false);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY,
                     &s->bar0_container);

    /*
     * PCIe endpoint + Resizable BAR capability.  The REBAR cap is only
     * added when the initial size is one of the supported sizes.
     */
    if (s->rebar_sizes && size >= (1ULL << 20) &&
        (s->rebar_sizes & (1u << (__builtin_ctzll(size) - 20)))) {
        uint16_t pos;
        uint32_t cap, ctrl;
        unsigned idx = __builtin_ctzll(size) - 20;

        /*
         * Hybrid device: conventional interface + PCIe capabilities.
         * cap_present is set in instance_init so pci_config_alloc
         * gives the device 4 KiB config space (the extended REBAR cap
         * is reachable via ECAM on q35).
         */
        pcie_endpoint_cap_init(pci_dev, NTO64_BARMEM_PCIE_CAP_OFF);
        pcie_add_capability(pci_dev, PCI_EXT_CAP_ID_REBAR, 1,
                            NTO64_BARMEM_REBAR_CAP_OFF, 16);
        pos = NTO64_BARMEM_REBAR_CAP_OFF;
        s->rebar_cap = pos;

        /*
         * PCIe 7.0 Table 7-165: supported sizes live in bits 4..23 of
         * the capability register; bits 3:0 are RsvdP (must read 0).
         * Table 7-166: the control register carries NBARs in bits 7:5,
         * the current BAR Size (one encoded index) in bits 13:8, and
         * BAR Index (RO, 0 for BAR0) in bits 2:0.
         */
        cap = (s->rebar_sizes << 4);
        ctrl = (1u << PCI_REBAR_CTRL_NBAR_SHIFT) |
               ((uint32_t)idx << PCI_REBAR_CTRL_BAR_SHIFT);
        pci_set_long(pci_dev->config + pos + PCI_REBAR_CAP, cap);
        pci_set_long(pci_dev->config + pos + PCI_REBAR_CTRL, ctrl);
        /* Only BAR Size (13:8) is writable; BAR Index (2:0) is RO. */
        pci_set_long(pci_dev->wmask + pos + PCI_REBAR_CTRL,
                     PCI_REBAR_CTRL_BAR_SIZE);
        info_report("nto64-barmem: REBAR cap at 0x%x (sizes 64M-512M)",
                    pos);
    } else {
        s->rebar_cap = 0;
    }

    pci_config_set_interrupt_pin(pci_dev->config, 1);   /* INTx#A */
    memory_region_init_io(&s->ctrl, OBJECT(s), &nto64_barmem_ctrl_ops, s,
                          "nto64-barmem-ctrl", NTO64_BARMEM_CTRL_SIZE);
    pci_register_bar(pci_dev, 1, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->ctrl);

    if (msi_init(pci_dev, 0x60, 1, true, false, errp)) {
        return;
    }
    info_report("nto64-barmem: ready (RAM/MMIO BAR0 paths, doorbell irq)");
}

static void nto64_barmem_exit(PCIDevice *pci_dev)
{
    Nto64BarmemState *s = NTO64_BARMEM(pci_dev);

    msi_uninit(pci_dev);
    if (memory_region_size(&s->bar0_storage)) {
        object_unparent(OBJECT(&s->bar0_storage));
    }
}

static void nto64_barmem_instance_init(Object *obj)
{
    PCIDevice *pci_dev = PCI_DEVICE(obj);

    /*
     * Hybrid PCI: keep the conventional interface (works on pc) but
     * request the 4 KiB config space a PCIe device gets, so the REBAR
     * extended capability can live in ECAM space on q35.  Must happen
     * before pci_config_alloc.
     */
    pci_dev->cap_present |= QEMU_PCI_CAP_EXPRESS;
}

static const Property nto64_barmem_props[] = {
    DEFINE_PROP_UINT64("bar-size", Nto64BarmemState, bar0_size,
                       NTO64_BARMEM_BAR0_DEFAULT),
    DEFINE_PROP_UINT32("rebar-sizes", Nto64BarmemState, rebar_sizes,
                       NTO64_BARMEM_REBAR_SIZES),
    DEFINE_PROP_LINK("memdev", Nto64BarmemState, hostmem,
                     TYPE_MEMORY_BACKEND, HostMemoryBackend *),
};

static void nto64_barmem_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    (void)data;
    k->realize = nto64_barmem_realize;
    k->exit = nto64_barmem_exit;
    k->config_write = nto64_barmem_config_write;
    k->vendor_id = NTO64_BARMEM_VENDOR;
    k->device_id = NTO64_BARMEM_DEVICE;
    k->revision = NTO64_BARMEM_REVISION;
    k->class_id = NTO64_BARMEM_CLASS;
    k->subsystem_vendor_id = NTO64_BARMEM_VENDOR;
    k->subsystem_id = NTO64_BARMEM_DEVICE;
    device_class_set_props(dc, nto64_barmem_props);
    dc->desc = "nto64-barmem: big memory-backend-backed PCI BAR test device";
}

static const TypeInfo nto64_barmem_info = {
    .name = TYPE_NTO64_BARMEM,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(Nto64BarmemState),
    .instance_init = nto64_barmem_instance_init,
    .class_init = nto64_barmem_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    },
};

static void nto64_barmem_register_types(void)
{
    type_register_static(&nto64_barmem_info);
}

type_init(nto64_barmem_register_types)
