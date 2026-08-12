/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * nto64-remote: cross-CPU interconnect / remote-memory test device.
 *
 * The per-CPU RAM views map a CPU's OWN
 * page as fast RAM but route every OTHER CPU's page through this
 * device's trap region: remote writes are write-behind (the visible
 * copy updates only after a configurable commit delay), so a remote
 * read right after a remote write returns the OLD value - the "access
 * to each cpu may occur out of order" model for the nto64 memory-
 * hierarchy work .
 *
 * Whole-RAM node slices: with slice-size/slices set, one
 * coherent trap region per node overlays the machine RAM range in
 * each CPU's address-space root - the owning CPU's slice is direct
 * RAM, every foreign slice is a trap that reads/writes the SAME host
 * RAM (so the guest sees one flat, coherent memory: hardware-NUMA /
 * software-UMA semantics, no SRAT/SLIT needed; cross-node accesses
 * are counted and MMIO-trapped, hence slower).  No CPU root contains
 * a plain-RAM alias to another node's slice.
 *
 * Regions (sysbus): 0 = remote-mmio (pages, stale model), 1 = ram
 * (pages, direct, same storage), 2 = control MMIO:
 *   0x00 magic "NTO3"
 *   0x04 commit delay in ns (default 1 ms)
 *   0x08 jitter in ns (+/- on the delay)
 *   0x0c control: bit0 bypass (reads = latest), bit1 write-through,
 *                 bit2 irq on commit, bit4 ccnuma (coherent mode)
 *   0x10 read counter
 *   0x14 write counter
 *   0x18 commit counter (pages committed)
 *   0x1c pending page count
 *   0x20 irq status (write clears / deasserts)
 *   0x24 last commit latency in ns (virtual clock; per-page: the
 *       time the most recently committed page spent pending)
 *
 * The commit-complete interrupt is a level INTx-style qdev irq; the
 * guest clears it by writing the status register.
 *
 * Write-behind model: each page is armed independently when it is
 * first dirtied after a commit (commit deadline = arm time + delay +
 * a fresh jitter draw), and a single timer commits pages as their
 * individual deadlines expire - so a burst of writes commits page by
 * page at per-page times, not all at once after the first write.
 *
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "qemu/error-report.h"
#include "hw/irq.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "hw/boards.h"
#include "qapi/error.h"
#include "qom/object.h"

#define TYPE_NTO64_REMOTE "nto64-remote"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64RemoteState, NTO64_REMOTE)

#define NTO64_REMOTE_MAGIC   0x4e544f33u /* "NTO3" */
#define NTO64_REMOTE_BYPASS  0x1
#define NTO64_REMOTE_WT      0x2
#define NTO64_REMOTE_IRQ     0x4
#define NTO64_REMOTE_CCNUMA  0x10
#define NTO64_REMOTE_PAGE    0x1000

typedef struct Nto64RemoteState {
    SysBusDevice parent_obj;

    MemoryRegion remote_mmio;
    MemoryRegion ram;
    MemoryRegion ctrl;
    qemu_irq irq;

    uint64_t window_size;
    uint8_t *storage;          /* latest writes */
    uint8_t *visible;          /* what remote reads see (committed) */
    uint8_t *pending;          /* one byte per page */
    uint32_t pending_count;

    uint32_t delay_ns;
    uint32_t jitter_ns;
    uint32_t control;
    uint32_t reads, writes, commits;
    uint64_t *pending_deadline;   /* per page: commit deadline (0 = clean) */
    uint64_t *pending_arm;        /* per page: virtual time first dirtied */
    uint64_t next_deadline;       /* earliest pending deadline */
    uint32_t last_latency_ns;
    bool ccnuma;
    bool irq_asserted;

    QEMUTimer *timer;

    /* whole-RAM node slices */
    uint64_t slice_base;       /* guest base of the first slice */
    uint64_t slice_size;
    uint32_t nslices;
    uint32_t slice_reads, slice_writes;
    uint32_t slice_delay_ns;   /* manual per-access remote latency */
} Nto64RemoteState;

/* per-region context for a node slice */
typedef struct Nto64Slice {
    Nto64RemoteState *s;
    uint32_t node;
} Nto64Slice;

/*
 * Per-access hook for the whole-RAM slices: count and optionally
 * inject a manual latency.  Runs on the TCG slow path without the
 * BQL; the access itself is direct RAM (coherent).
 */
static void nto64_slice_hook(void *opaque, unsigned int vcpu_index,
                             hwaddr addr, unsigned size, bool is_write)
{
    Nto64Slice *sl = opaque;
    Nto64RemoteState *s = sl->s;

    (void)vcpu_index;
    (void)addr;
    (void)size;
    if (is_write) {
        qatomic_inc(&s->slice_writes);
    } else {
        qatomic_inc(&s->slice_reads);
    }
    if (s->slice_delay_ns) {
        int64_t start = qemu_clock_get_ns(QEMU_CLOCK_HOST);

        while (qemu_clock_get_ns(QEMU_CLOCK_HOST) <
               start + (int64_t)s->slice_delay_ns) {
        }
    }
}

/*
 * Arm page p for a commit: its deadline is now + delay + a fresh
 * jitter draw (per-page, per-write jitter).  Re-arm the shared timer
 * only if this page's deadline is earlier than the current earliest.
 */
static void nto64_remote_arm_page(Nto64RemoteState *s, uint32_t p,
                                  uint64_t now)
{
    int64_t delay = s->delay_ns;

    if (s->jitter_ns) {
        delay += g_random_int_range(-(int)s->jitter_ns,
                                    (int)s->jitter_ns + 1);
        if (delay < 0) {
            delay = 0;
        }
    }
    s->pending_arm[p] = now;
    s->pending_deadline[p] = now + delay;
    if (s->pending_deadline[p] < s->next_deadline) {
        s->next_deadline = s->pending_deadline[p];
        timer_mod(s->timer, s->next_deadline);
    }
}

/* Scan the pending pages and arm the timer to the earliest deadline. */
static void nto64_remote_rearm(Nto64RemoteState *s)
{
    uint32_t p, npages = s->window_size >> 12;

    s->next_deadline = UINT64_MAX;
    for (p = 0; p < npages; p++) {
        if (s->pending[p] && s->pending_deadline[p] < s->next_deadline) {
            s->next_deadline = s->pending_deadline[p];
        }
    }
    if (s->next_deadline != UINT64_MAX) {
        timer_mod(s->timer, s->next_deadline);
    }
}

static void nto64_remote_commit(void *opaque)
{
    Nto64RemoteState *s = opaque;
    uint32_t p, npages = s->window_size >> 12, n = 0;
    uint64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    for (p = 0; p < npages; p++) {
        if (s->pending[p] && s->pending_deadline[p] <= now) {
            memcpy(s->visible + p * NTO64_REMOTE_PAGE,
                   s->storage + p * NTO64_REMOTE_PAGE, NTO64_REMOTE_PAGE);
            s->pending[p] = 0;
            s->pending_deadline[p] = 0;
            s->pending_count--;
            s->last_latency_ns = (uint32_t)(now - s->pending_arm[p]);
            n++;
        }
    }
    if (n) {
        s->commits += n;
        if ((s->control & NTO64_REMOTE_IRQ) && !s->irq_asserted) {
            s->irq_asserted = true;
            qemu_set_irq(s->irq, 1);
        }
    }
    nto64_remote_rearm(s);
}

static uint64_t nto64_remote_mmio_read(void *opaque, hwaddr addr,
                                       unsigned size)
{
    Nto64RemoteState *s = opaque;
    uint64_t v = 0;
    const uint8_t *src;

    if (addr + size <= s->window_size) {
        src = ((s->control & (NTO64_REMOTE_BYPASS | NTO64_REMOTE_CCNUMA))
               || s->ccnuma) ? s->storage : s->visible;
        memcpy(&v, src + addr, size);
    }
    s->reads++;
    return v;
}

static void nto64_remote_mmio_write(void *opaque, hwaddr addr,
                                    uint64_t val, unsigned size)
{
    Nto64RemoteState *s = opaque;
    uint32_t p;

    if (addr + size <= s->window_size) {
        memcpy(s->storage + addr, &val, size);
        if ((s->control & NTO64_REMOTE_WT) || s->ccnuma) {
            memcpy(s->visible + addr, &val, size);
        } else {
            p = addr >> 12;
            if (!s->pending[p]) {
                s->pending[p] = 1;
                s->pending_count++;
                nto64_remote_arm_page(
                    s, p, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
            }
        }
    }
    s->writes++;
}

static const MemoryRegionOps nto64_remote_mmio_ops = {
    .read = nto64_remote_mmio_read,
    .write = nto64_remote_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
};

static uint64_t nto64_remote_ctrl_read(void *opaque, hwaddr addr,
                                       unsigned size)
{
    Nto64RemoteState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x00:
        return NTO64_REMOTE_MAGIC;
    case 0x04:
        return s->delay_ns;
    case 0x08:
        return s->jitter_ns;
    case 0x0c:
        return s->control;
    case 0x10:
        return s->reads;
    case 0x14:
        return s->writes;
    case 0x18:
        return s->commits;
    case 0x1c:
        return s->pending_count;
    case 0x20:
        return s->irq_asserted ? 1 : 0;
    case 0x24:
        return s->last_latency_ns;
    case 0x28:
        return s->slice_reads;
    case 0x2c:
        return s->slice_writes;
    case 0x3c:
        return s->slice_delay_ns;
    default:
        return 0;
    }
}

static void nto64_remote_flush(Nto64RemoteState *s)
{
    uint32_t p, npages = s->window_size >> 12, n = 0;

    for (p = 0; p < npages; p++) {
        if (s->pending[p]) {
            memcpy(s->visible + p * NTO64_REMOTE_PAGE,
                   s->storage + p * NTO64_REMOTE_PAGE, NTO64_REMOTE_PAGE);
            s->pending[p] = 0;
            s->pending_deadline[p] = 0;
            n++;
        }
    }
    if (n) {
        s->commits += n;
        s->pending_count = 0;
    }
    timer_del(s->timer);
    s->next_deadline = UINT64_MAX;
}

static void nto64_remote_ctrl_write(void *opaque, hwaddr addr,
                                    uint64_t val, unsigned size)
{
    Nto64RemoteState *s = opaque;

    (void)size;
    switch (addr) {
    case 0x04:
        s->delay_ns = (uint32_t)val;
        break;
    case 0x08:
        s->jitter_ns = (uint32_t)val;
        break;
    case 0x0c:
        s->control = (uint32_t)val;
        if (s->control & NTO64_REMOTE_WT) {
            nto64_remote_flush(s);
        }
        if (s->control & NTO64_REMOTE_CCNUMA) {
            nto64_remote_flush(s);
        }
        break;
    case 0x20:
        s->irq_asserted = false;
        qemu_set_irq(s->irq, 0);
        break;
    case 0x3c:
        s->slice_delay_ns = (uint32_t)val;
        break;
    default:
        break;
    }
}

static const MemoryRegionOps nto64_remote_ctrl_ops = {
    .read = nto64_remote_ctrl_read,
    .write = nto64_remote_ctrl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void nto64_remote_realize(DeviceState *dev, Error **errp)
{
    Nto64RemoteState *s = NTO64_REMOTE(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    if (s->window_size == 0 || (s->window_size & (NTO64_REMOTE_PAGE - 1))) {
        error_setg(errp, "nto64-remote: window-size must be a non-zero "
                   "multiple of 4 KiB");
        return;
    }

    memory_region_init_ram(&s->ram, OBJECT(s), "nto64-remote-ram",
                           s->window_size, errp);
    if (*errp) {
        return;
    }
    s->storage = memory_region_get_ram_ptr(&s->ram);
    s->visible = g_malloc0(s->window_size);
    s->pending = g_malloc0(s->window_size >> 12);
    s->pending_deadline = g_new0(uint64_t, s->window_size >> 12);
    s->pending_arm = g_new0(uint64_t, s->window_size >> 12);
    s->next_deadline = UINT64_MAX;

    memory_region_init_io(&s->remote_mmio, OBJECT(s),
                          &nto64_remote_mmio_ops, s,
                          "nto64-remote-mmio", s->window_size);
    memory_region_init_io(&s->ctrl, OBJECT(s), &nto64_remote_ctrl_ops, s,
                          "nto64-remote-ctrl", 0x1000);
    sysbus_init_mmio(sbd, &s->remote_mmio);
    sysbus_init_mmio(sbd, &s->ram);
    sysbus_init_mmio(sbd, &s->ctrl);
    sysbus_init_irq(sbd, &s->irq);

    if (s->slice_size && s->nslices) {
        uint32_t i;
        uint64_t base = s->slice_base;

        for (i = 0; i < s->nslices; i++) {
            Nto64Slice *sl = g_new0(Nto64Slice, 1);

            sl->s = s;
            sl->node = i;
            /*
             *  the slices are no longer separate ram_ptr
             * regions over the machine RAM.  A second RAMBlock for the
             * same host bytes gives one guest page two ram_addr
             * identities, which breaks TCG self-modifying-code
             * invalidation when a foreign CPU writes a page whose TBs
             * were translated through the owning CPU's pc.ram view.
             * There are no per-CPU slice subregions either (aliasing the
             * system memory at the slice ranges churns the per-CPU
             * flatviews against OVMF's PAM/ROM updates); the machine RAM
             * keeps one ram_addr identity and the per-node
             * instrumentation is resolved by physical range at TLB fill
             * time.
             */
            memory_region_register_instrument_range(
                base + (uint64_t)i * s->slice_size, s->slice_size, i,
                nto64_slice_hook, sl);
        }
        info_report("nto64-remote: %u instrumented RAM ranges of %" PRIu64
                    " bytes at 0x%" PRIx64, s->nslices, s->slice_size, base);
    }

    s->timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, nto64_remote_commit, s);
}

static void nto64_remote_unrealize(DeviceState *dev)
{
    Nto64RemoteState *s = NTO64_REMOTE(dev);

    timer_free(s->timer);
    g_free(s->visible);
    g_free(s->pending);
    g_free(s->pending_deadline);
    g_free(s->pending_arm);
}

static const Property nto64_remote_props[] = {
    DEFINE_PROP_UINT64("window-size", Nto64RemoteState, window_size, 0x10000),
    DEFINE_PROP_UINT32("delay-ns", Nto64RemoteState, delay_ns, 1000000),
    DEFINE_PROP_UINT32("jitter-ns", Nto64RemoteState, jitter_ns, 0),
    DEFINE_PROP_BOOL("ccnuma", Nto64RemoteState, ccnuma, false),
    DEFINE_PROP_UINT64("slice-size", Nto64RemoteState, slice_size, 0),
    DEFINE_PROP_UINT32("slices", Nto64RemoteState, nslices, 0),
    DEFINE_PROP_UINT64("slice-base", Nto64RemoteState, slice_base, 0),
    DEFINE_PROP_UINT32("slice-delay-ns", Nto64RemoteState, slice_delay_ns, 0),
};

static void nto64_remote_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    (void)data;
    dc->realize = nto64_remote_realize;
    dc->unrealize = nto64_remote_unrealize;
    device_class_set_props(dc, nto64_remote_props);
    dc->desc = "nto64-remote: cross-CPU interconnect / remote memory";
}

static const TypeInfo nto64_remote_info = {
    .name = TYPE_NTO64_REMOTE,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(Nto64RemoteState),
    .class_init = nto64_remote_class_init,
};

static void nto64_remote_register_types(void)
{
    type_register_static(&nto64_remote_info);
}

type_init(nto64_remote_register_types)
