/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * nto64-msix: multi-vector MSI-X interrupt generator with per-vector
 * destination control.
 *
 * Test device for the interrupt machinery ('s
 * MSI/MSI-X bus side): one MMIO-triggered MSI-X source with N vectors,
 * each programmably targeted (via the guest-written MSI-X table) at a
 * different CPU/LAPIC, so device-interrupt locality can be tied to a
 * node.  The guest writes the MSI-X table (BAR1), enables MSI-X, then
 * fires vectors individually (vector select + trigger) or as a burst
 * (fire mask); per-vector fire counters let the guest correlate
 * device-side fires with per-CPU handler receipts.
 *
 *   BAR0 (4 KiB control MMIO, 32-bit accesses):
 *     0x00 magic "NTMX"
 *     0x04 control: bit0 enable (fires deliver; else only counted)
 *     0x08 total fire count (write 0 clears)
 *     0x0c vector select (0..N-1, used by the trigger)
 *     0x10 trigger: write 1 -> fire the selected vector
 *     0x14 fire mask: write bits -> fire all set vectors (burst)
 *     0x18 per-vector fire counters, 4 bytes each (write 0 clears all)
 *     0x60 spurious: write "SPR" (0x535052) -> fire the selected vector
 *         IGNORING the enable bit (the device raises for something the
 *         driver did not arm for); 0x64 = spurious count (write 0 clears)
 *   BAR1: MSI-X vector table (lower half) + PBA (upper half), set up
 *         by msix_init_exclusive_bar.
 *
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msix.h"
#include "hw/qdev-properties.h"
#include "qom/object.h"

#define TYPE_NTO64_MSIX "nto64-msix"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64MsixState, NTO64_MSIX)

#define NTO64_MSIX_VENDOR 0x1234
#define NTO64_MSIX_DEVICE 0x1EE8
#define NTO64_MSIX_CLASS  0x0800    /* PIC: interrupt controller */
#define NTO64_MSIX_REVISION 1
#define NTO64_MSIX_MAGIC  0x584d544eu /* "NTMX" */
#define NTO64_MSIX_CTRL_SIZE 0x1000
#define NTO64_MSIX_DEFAULT_VECTORS 4
#define NTO64_MSIX_MAX_VECTORS 16
#define NTO64_MSIX_SPURIOUS_MAGIC 0x535052u /* "SPR" */

#define NTO64_MSIX_CTRL_ENABLE 0x1

typedef struct Nto64MsixState {
    PCIDevice pdev;
    MemoryRegion ctrl;
    uint32_t nv;
    uint32_t control;
    uint32_t count;
    uint32_t vector;
    uint32_t spurious;         /* spurious-interrupt count (0x64) */
    uint32_t *pv;             /* per-vector fire counters */
} Nto64MsixState;

/* Fire one vector: count it, and deliver when enabled + MSI-X up. */
static void nto64_msix_fire(Nto64MsixState *s, unsigned vec)
{
    if (vec >= s->nv) {
        return;
    }
    s->count++;
    s->pv[vec]++;
    if (s->control & NTO64_MSIX_CTRL_ENABLE) {
        msix_notify(&s->pdev, vec);
    }
    if (s->count <= 8 || (s->count & (s->count - 1)) == 0) {
        info_report("nto64-msix: fire vector %u (total %u)",
                    vec, s->count);
    }
}

static uint64_t nto64_msix_read(void *opaque, hwaddr addr, unsigned size)
{
    Nto64MsixState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x00:
        return NTO64_MSIX_MAGIC;
    case 0x04:
        return s->control;
    case 0x08:
        return s->count;
    case 0x0c:
        return s->vector;
    case 0x14:
        return 0;
    case 0x64:
        return s->spurious;
    default:
        if (addr >= 0x18 && addr < 0x18 + 4ULL * s->nv &&
            (addr & 3) == 0) {
            return s->pv[(addr - 0x18) / 4];
        }
        return 0;
    }
}

static void nto64_msix_write(void *opaque, hwaddr addr,
                             uint64_t val, unsigned size)
{
    Nto64MsixState *s = opaque;
    uint32_t mask;
    int i;

    (void)size;
    switch (addr) {
    case 0x04:
        s->control = (uint32_t)val & NTO64_MSIX_CTRL_ENABLE;
        break;
    case 0x08:
        s->count = 0;
        break;
    case 0x0c:
        s->vector = (uint32_t)val;
        break;
    case 0x10:
        if (val & 1) {
            nto64_msix_fire(s, s->vector);
        }
        break;
    case 0x14:
        mask = (uint32_t)val &
               ((s->nv == 32) ? 0xffffffffu : ((1u << s->nv) - 1));
        for (i = 0; i < s->nv; i++) {
            if (mask & (1u << i)) {
                nto64_msix_fire(s, i);
            }
        }
        break;
    case 0x18:
        memset(s->pv, 0, sizeof(uint32_t) * s->nv);
        break;
    case 0x60:
        /*
         * Spurious: deliver on the selected vector even if the device
         * is disabled - a "got an interrupt we didn't arm for" shape the
         * driver must tolerate.  Uses the PBA/raising model: if the
         * vector is masked, msix_notify sets the pending bit instead.
         */
        if (val == NTO64_MSIX_SPURIOUS_MAGIC) {
            if (s->vector < s->nv) {
                s->spurious++;
                msix_notify(&s->pdev, s->vector);
                info_report("nto64-msix: spurious vector %u (total %u)",
                            s->vector, s->spurious);
            }
        }
        break;
    case 0x64:
        s->spurious = 0;
        break;
    default:
        break;
    }
}

static const MemoryRegionOps nto64_msix_ops = {
    .read = nto64_msix_read,
    .write = nto64_msix_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void nto64_msix_realize(PCIDevice *pci_dev, Error **errp)
{
    Nto64MsixState *s = NTO64_MSIX(pci_dev);
    int i;

    if (s->nv < 1 || s->nv > NTO64_MSIX_MAX_VECTORS) {
        error_setg(errp, "nto64-msix: vectors must be 1..%u",
                   NTO64_MSIX_MAX_VECTORS);
        return;
    }

    pci_config_set_interrupt_pin(pci_dev->config, 1);   /* INTx#A (unused) */
    memory_region_init_io(&s->ctrl, OBJECT(s), &nto64_msix_ops, s,
                          "nto64-msix-ctrl", NTO64_MSIX_CTRL_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->ctrl);

    if (msix_init_exclusive_bar(pci_dev, s->nv, 1, errp)) {
        return;
    }
    for (i = 0; i < s->nv; i++) {
        msix_vector_use(pci_dev, i);
    }
    s->pv = g_new0(uint32_t, s->nv);
    info_report("nto64-msix: ready (%u MSI-X vectors)", s->nv);
}

static void nto64_msix_exit(PCIDevice *pci_dev)
{
    Nto64MsixState *s = NTO64_MSIX(pci_dev);

    msix_unuse_all_vectors(pci_dev);
    msix_uninit_exclusive_bar(pci_dev);
    g_free(s->pv);
    s->pv = NULL;
}

static const Property nto64_msix_props[] = {
    DEFINE_PROP_UINT32("vectors", Nto64MsixState, nv,
                       NTO64_MSIX_DEFAULT_VECTORS),
};

static void nto64_msix_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    (void)data;
    k->realize = nto64_msix_realize;
    k->exit = nto64_msix_exit;
    k->vendor_id = NTO64_MSIX_VENDOR;
    k->device_id = NTO64_MSIX_DEVICE;
    k->revision = NTO64_MSIX_REVISION;
    k->class_id = NTO64_MSIX_CLASS;
    k->subsystem_vendor_id = NTO64_MSIX_VENDOR;
    k->subsystem_id = NTO64_MSIX_DEVICE;
    device_class_set_props(dc, nto64_msix_props);
    dc->desc = "nto64-msix: multi-vector MSI-X interrupt generator";
}

static const TypeInfo nto64_msix_info = {
    .name = TYPE_NTO64_MSIX,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(Nto64MsixState),
    .class_init = nto64_msix_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    },
};

static void nto64_msix_register_types(void)
{
    type_register_static(&nto64_msix_info);
}

type_init(nto64_msix_register_types)
