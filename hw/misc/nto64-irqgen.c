/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * nto64-irqgen: on-demand interrupt generator / IRQ storm source.
 *
 * Test device for the IRQ machinery (:
 * PIC/APIC IRQ -> SIGEV_INTR/pulse, then the MSI bus side): MMIO-
 * triggered interrupts with selectable delivery (PCI INTx -> I/O APIC
 * or PIC, or MSI), edge/level modes, and a configurable auto-repeat
 * timer for IRQ storms, with a delivered-count register.
 *
 * BAR0 (4 KiB control MMIO, 32-bit accesses):
 *   0x00 magic "NTOI"
 *   0x04 control: bit0 irq-enable, bit1 edge(1)/level(0),
 *                 bit2 prefer-MSI, bit3 storm (periodic)
 *   0x08 delivered count (write 0 to clear)
 *   0x0c storm period in us (0 = single shot)
 *   0x10 trigger: write 1 -> fire one interrupt
 *   0x14 status: bit0 level line active (read-only)
 *   0x18 irq ack: write 1 deasserts a level INTx line
 *
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "qemu/timer.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msi.h"
#include "hw/qdev-properties.h"
#include "qom/object.h"

#define TYPE_NTO64_IRQGEN "nto64-irqgen"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64IrqgenState, NTO64_IRQGEN)

#define NTO64_IRQGEN_VENDOR 0x1234
#define NTO64_IRQGEN_DEVICE 0x1EE7
#define NTO64_IRQGEN_CLASS  0x0800    /* PIC: interrupt controller */
#define NTO64_IRQGEN_REVISION 1
#define NTO64_IRQGEN_MAGIC  0x49544e4fu /* "NTOI" */
#define NTO64_IRQGEN_CTRL_SIZE 0x1000

#define NTO64_IRQGEN_CTRL_ENABLE 0x1
#define NTO64_IRQGEN_CTRL_EDGE   0x2
#define NTO64_IRQGEN_CTRL_MSI    0x4
#define NTO64_IRQGEN_CTRL_STORM  0x8

typedef struct Nto64IrqgenState {
    PCIDevice pdev;
    MemoryRegion ctrl;
    QEMUTimer *timer;
    uint32_t control;
    uint32_t count;
    uint32_t period_us;
    bool level_active;
} Nto64IrqgenState;

static void nto64_irqgen_update_level(Nto64IrqgenState *s)
{
    bool use_msi = (s->control & NTO64_IRQGEN_CTRL_MSI) &&
                   msi_enabled(&s->pdev);
    bool level = (s->control & NTO64_IRQGEN_CTRL_ENABLE) &&
                 !(s->control & NTO64_IRQGEN_CTRL_EDGE);

    if (!use_msi) {
        s->level_active = level;
        pci_set_irq(&s->pdev, level);
    } else {
        s->level_active = false;
    }
}

/* Fire one interrupt and count it. */
static void nto64_irqgen_fire(Nto64IrqgenState *s)
{
    bool use_msi = (s->control & NTO64_IRQGEN_CTRL_MSI) &&
                   msi_enabled(&s->pdev);

    s->count++;
    if (use_msi) {
        msi_notify(&s->pdev, 0);
    } else if (s->control & NTO64_IRQGEN_CTRL_EDGE) {
        pci_set_irq(&s->pdev, 1);
        pci_set_irq(&s->pdev, 0);
    } else {
        s->level_active = true;
        pci_set_irq(&s->pdev, 1);
    }
    if (s->count <= 8 || (s->count & (s->count - 1)) == 0) {
        info_report("nto64-irqgen: interrupt %u (%s)",
                    s->count, use_msi ? "msi" : "intx");
    }
}

static void nto64_irqgen_timer_cb(void *opaque)
{
    Nto64IrqgenState *s = opaque;

    if ((s->control & NTO64_IRQGEN_CTRL_ENABLE) &&
        (s->control & NTO64_IRQGEN_CTRL_STORM)) {
        nto64_irqgen_fire(s);
        timer_mod(s->timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  (int64_t)s->period_us * 1000);
    }
}

static uint64_t nto64_irqgen_read(void *opaque, hwaddr addr, unsigned size)
{
    Nto64IrqgenState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x00:
        return NTO64_IRQGEN_MAGIC;
    case 0x04:
        return s->control;
    case 0x08:
        return s->count;
    case 0x0c:
        return s->period_us;
    case 0x14:
        return s->level_active ? 1 : 0;
    default:
        return 0;
    }
}

static void nto64_irqgen_write(void *opaque, hwaddr addr,
                               uint64_t val, unsigned size)
{
    Nto64IrqgenState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x04:
        s->control = (uint32_t)val;
        nto64_irqgen_update_level(s);
        if ((s->control & NTO64_IRQGEN_CTRL_STORM) && s->period_us &&
            (s->control & NTO64_IRQGEN_CTRL_ENABLE)) {
            timer_mod(s->timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                      (int64_t)s->period_us * 1000);
        } else if (!(s->control & NTO64_IRQGEN_CTRL_STORM)) {
            timer_del(s->timer);
        }
        break;
    case 0x08:
        s->count = 0;
        break;
    case 0x0c:
        s->period_us = (uint32_t)val;
        if ((s->control & NTO64_IRQGEN_CTRL_STORM) &&
            (s->control & NTO64_IRQGEN_CTRL_ENABLE) && s->period_us) {
            timer_mod(s->timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                      (int64_t)s->period_us * 1000);
        }
        break;
    case 0x10:
        if (val & 1) {
            nto64_irqgen_fire(s);
        }
        break;
    case 0x18:                  /* irq ack: deassert a level INTx */
        if (val & 1) {
            s->level_active = false;
            if (!((s->control & NTO64_IRQGEN_CTRL_MSI) &&
                  msi_enabled(&s->pdev))) {
                pci_set_irq(&s->pdev, 0);
            }
        }
        break;
    default:
        break;
    }
}

static const MemoryRegionOps nto64_irqgen_ops = {
    .read = nto64_irqgen_read,
    .write = nto64_irqgen_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void nto64_irqgen_realize(PCIDevice *pci_dev, Error **errp)
{
    Nto64IrqgenState *s = NTO64_IRQGEN(pci_dev);

    pci_config_set_interrupt_pin(pci_dev->config, 1);   /* INTx#A */
    memory_region_init_io(&s->ctrl, OBJECT(s), &nto64_irqgen_ops, s,
                          "nto64-irqgen-ctrl", NTO64_IRQGEN_CTRL_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->ctrl);

    if (msi_init(pci_dev, 0x60, 1, true, false, errp)) {
        return;
    }
    s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                            nto64_irqgen_timer_cb, s);
    info_report("nto64-irqgen: ready (INTx + MSI, storm timer)");
}

static void nto64_irqgen_exit(PCIDevice *pci_dev)
{
    Nto64IrqgenState *s = NTO64_IRQGEN(pci_dev);

    timer_free(s->timer);
    msi_uninit(pci_dev);
}

static void nto64_irqgen_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    (void)data;
    k->realize = nto64_irqgen_realize;
    k->exit = nto64_irqgen_exit;
    k->vendor_id = NTO64_IRQGEN_VENDOR;
    k->device_id = NTO64_IRQGEN_DEVICE;
    k->revision = NTO64_IRQGEN_REVISION;
    k->class_id = NTO64_IRQGEN_CLASS;
    k->subsystem_vendor_id = NTO64_IRQGEN_VENDOR;
    k->subsystem_id = NTO64_IRQGEN_DEVICE;
    dc->desc = "nto64-irqgen: on-demand interrupt generator / IRQ storm";
}

static const TypeInfo nto64_irqgen_info = {
    .name = TYPE_NTO64_IRQGEN,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(Nto64IrqgenState),
    .class_init = nto64_irqgen_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    },
};

static void nto64_irqgen_register_types(void)
{
    type_register_static(&nto64_irqgen_info);
}

type_init(nto64_irqgen_register_types)
