/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * nto64-dma: test DMA engine bound to a vCPU (node).
 *
 * The device's DMA address space is rooted at the selected vCPU's
 * memory view, so device DMA obeys the same per-CPU shape as CPU
 * accesses: with nto64-per-cpu-ram=on, DMA to the node's own window
 * page is direct RAM, DMA to another CPU's page traverses the
 * nto64-remote interconnect (coherent in ccNUMA mode), and DMA to
 * plain RAM is the normal system alias.  Together with nto64-msix
 * this models device-node binding: its completion interrupt is an
 * MSI-X vector the guest targets at the node's CPU.
 *
 *   BAR0 (4 KiB control MMIO, 32-bit accesses):
 *     0x00 magic "NTDM"
 *     0x04 control: bit0 start, bit1 irq-on-done, bit2 ring mode
 *     0x08 source address low, 0x0c high
 *     0x10 dest address low, 0x14 high
 *     0x18 size (bytes, capped at max-xfer)
 *     0x1c status: bit0 busy, bit1 done, bit2 error, bit3 fault
 *          (write 0 clears)
 *     0x20 transfers completed
 *     0x24 bytes moved
 *     0x28 ring base low, 0x2c high (ring mode)
 *     0x30 ring count (descriptors in the batch)
 *     0x34 descriptor stride (bytes; 16 = 4x32-bit entries)
 *     0x38 descriptors processed (last ring batch)
 *     0x3c queue count (read-only; the `queues` property)
 *     0x40 queue select (0..queues-1, used by the per-queue regs)
 *     0x44/0x48 per-queue ring base low/high (selected queue)
 *     0x4c per-queue ring count
 *     0x50 per-queue descriptor stride
 *     0x54 per-queue start: write 1 -> run the selected queue's ring
 *          asynchronously; one completion MSI-X (vector = queue index)
 *          per message when control bit1 is set
 *     0x58 per-queue descriptors processed
 *     0x5c per-queue transfers completed
 *     0x60/0x64 per-queue bytes moved
 *     0x68 peer-P2P transfers completed (P2P mode, read-only)
 *     0x6c peer-P2P bytes moved low, 0x70 high (read-only)
 *     0x74 fault control: bit0 fault-window enable, bit1 inject a
 *          fault on the next transfer (self-clearing), bit2 resolve /
 *          retry (write 1 re-runs the faulted transfer after the
 *          guest fixed the mapping), bit3 fault IRQ enable (the fault
 *          fires MSI-X vector `queues`)
 *     0x78 fault status: bit0 pending (a transfer stopped on a
 *          device fault, awaiting resolve/retry)
 *     0x7c/0x80 fault address low/high (first faulting byte)
 *     0x84 fault count (number of faults latched)
 *     0x88/0x8c fault window base low/high, 0x90 window size bytes
 *     0x94 PCIe AER inject: write "AERC" (0x43524541) -> correctable
 *         (Receiver Error), "AERU" (0x55524541) -> uncorrectable
 *         non-fatal (Data Link Protocol), "AERF" (0x46524541) ->
 *         uncorrectable fatal (Internal Error); each logs through the
 *         device's AER capability (extended config cap id 1),
 *         0x98 = AER inject count (write 0 clears)
 *          (0 disables the window; the window models a not-present
 *          range in the device's page tables - a PRI/ATS-style
 *          device fault)
 *
 * The 0x28-0x38 ring registers alias queue 0, so the legacy single-ring
 * mode (control bit2 + start) is the "queue 0" case.
 *
 * PCIe peer-to-peer (P2P): with the `peer` property set
 * another PCI device (e.g. nto64-barmem) and control bit3 (P2P) set,
 * the bulk engine's transfer target is that peer's BAR instead of
 * system memory - the CPU never touches the moved bytes (the OS only
 * set up src/dst + the descriptor rings).  Direction:
 *     bit3=1, bit4=0: device AS -> peer BAR   (src read via the DMA
 *                       AS, dst is an offset into the peer BAR)
 *     bit3=1, bit4=1: peer BAR -> device AS   (src is an offset into
 *                       the peer BAR, dst written via the DMA AS)
 * P2P transfers are counted separately in 0x68/0x6c/0x70.
 * `peer-bar` (default 0) selects the peer's BAR to target; it must be
 * a memory BAR.  The peer device must appear before nto64-dma on the
 * command line (QEMU realizes -device options in order).
 *
 * Ring descriptors (stride bytes, 32-bit little-endian):
 *     +0 source address, +4 dest address, +8 length,
 *     +0xc flags (bit0 valid; the device ORs bit1 on completion;
 *     bit2 = peer dest (dst is an offset into the peer BAR),
 *     bit3 = peer src (src is an offset into the peer BAR) - the
 *     device-side address of that descriptor goes through the bound
 *     queue's AS, the peer side through the peer BAR AS, so a
 *     descriptor with both bits set relocates data within device
 *     memory with no CPU involvement).
 *
 * Device faults (PRI-like): with the fault window enabled,
 * any DMA chunk whose device-AS-side address range overlaps the
 * window stops the transfer immediately (chunks before the faulting
 * one stay written - partial progress, like a real page fault mid-
 * DMA), latches the first faulting byte in 0x7c/0x80, increments
 * 0x84, sets status bit3 + fault-status bit0, and raises the fault
 * MSI-X vector (`queues`).  The guest "resolves" the fault by fixing
 * the mapping (moving/disabling the window or clearing the inject)
 * and writing fault-control bit2: the device then retries the
 * interrupted transfer from the start.  `queues` MSI-X vectors are
 * used for queue completions, plus one extra vector for faults.
 * The ring mode walks the descriptors one small transfer at a time,
 * firing the completion MSI-X per message (NIC/RDMA-style); the bulk
 * mode does one chunked transfer of up to max-xfer bytes
 * (GPU-style).: with queues > 1, queue i is bound to vCPU i
 * (its ring descriptors are fetched and its DMA transfers run through
 * vCPU i's memory view) and its completion MSI-X is vector i - the
 * guest programs vector i's MSI-X table entry to target CPU i, giving
 * the full "device attached to node" (multi-queue NIC/RDMA) shape.
 *   BAR1: MSI-X vector table + PBA (msix_init_exclusive_bar).
 *
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msix.h"
#include "hw/pci/pcie.h"
#include "hw/pci/pcie_aer.h"
#include "hw/qdev-properties.h"
#include "system/address-spaces.h"
#include "qemu/main-loop.h"
#include "qom/object.h"

#define TYPE_NTO64_DMA "nto64-dma"
OBJECT_DECLARE_SIMPLE_TYPE(Nto64DmaState, NTO64_DMA)

#define NTO64_DMA_VENDOR 0x1234
#define NTO64_DMA_DEVICE 0x1EE9
#define NTO64_DMA_CLASS  0x0500    /* memory controller */
#define NTO64_DMA_REVISION 1
#define NTO64_DMA_MAGIC  0x4d44544eu /* "NTDM" */
#define NTO64_DMA_CTRL_SIZE 0x1000
#define NTO64_DMA_CHUNK   (1 * MiB)
#define NTO64_DMA_BH_BURST 4   /* max 1 MiB chunks per BH invocation */
#define NTO64_DMA_MAX_XFER (1 * GiB)   /* default single-transfer cap */
#define NTO64_DMA_QUEUE_MAX 16
#define NTO64_DMA_QUEUES_DEFAULT 4
#define NTO64_DMA_EXP_OFFSET 0x90       /* PCIe endpoint cap (regular) */
#define NTO64_DMA_AER_OFFSET 0x100      /* AER cap (extended) */
#define NTO64_DMA_AER_COR  0x43524541u  /* "AERC" */
#define NTO64_DMA_AER_UNC  0x55524541u  /* "AERU" */
#define NTO64_DMA_AER_FAT  0x46524541u  /* "AERF" */

#define NTO64_DMA_CTRL_START 0x1
#define NTO64_DMA_CTRL_IRQ   0x2
#define NTO64_DMA_CTRL_RING  0x4
#define NTO64_DMA_CTRL_P2P   0x8     /* bulk target is the peer BAR */
#define NTO64_DMA_CTRL_P2PREV 0x10   /* P2P direction: peer -> device */

#define NTO64_DMA_DESC_PEER_DST 0x4  /* ring dst is a peer BAR offset */
#define NTO64_DMA_DESC_PEER_SRC 0x8  /* ring src is a peer BAR offset */

#define NTO64_DMA_ST_BUSY 0x1
#define NTO64_DMA_ST_DONE 0x2
#define NTO64_DMA_ST_ERR  0x4
#define NTO64_DMA_ST_FAULT 0x8   /* stopped on a device fault */

#define NTO64_DMA_FAULT_WIN     0x1  /* window checks enabled */
#define NTO64_DMA_FAULT_INJECT  0x2  /* inject on the next transfer */
#define NTO64_DMA_FAULT_RESOLVE 0x4  /* resolve + retry the faulted xfer */
#define NTO64_DMA_FAULT_IRQEN   0x8  /* fault IRQ (MSI-X vector `queues`) */

#define NTO64_DMA_FST_PENDING 0x1

typedef struct Nto64DmaState {
    PCIDevice pdev;
    MemoryRegion ctrl;
    AddressSpace *dma_as;     /* heap: released by address_space_destroy_free() */
    MemoryRegion *dma_root;
    uint32_t node;
    uint32_t control;
    uint64_t src;
    uint64_t dst;
    uint32_t size;
    uint32_t max_xfer;
    uint32_t status;
    uint32_t xfers;
    uint64_t bytes;
    uint32_t queues_n;        /* `queues` property (MSI-X vectors too) */
    struct Nto64DmaQueue *queues;
    uint32_t qselect;         /* per-queue register window selector */
    uint32_t ring_queue;      /* queue index for the async per-queue start */
    bool queue_start;         /* 0x54-driven per-queue ring in flight */
    uint64_t bulk_src, bulk_dst;  /* snapshot of the in-flight bulk op */
    uint32_t bulk_len;            /* total bytes of the bulk op */
    uint64_t bulk_off;            /* bytes moved so far */
    bool bulk_p2p;                /* bulk target is the peer BAR */
    bool bulk_rev;                /* P2P direction: peer -> device */
    uint8_t *bounce;              /* shared 1 MiB chunk buffer */
    /*
     * DMA through the PCI/IOMMU AS instead of the vCPU (node) memory view
     */
    bool iommu;
    PCIDevice *peer;          /* `peer` property: P2P target device */
    uint32_t peer_bar;        /* `peer-bar` property: BAR on the peer */
    MemoryRegion *peer_mr;    /* resolved peer BAR memory region */
    AddressSpace *peer_as;    /* AS rooted at the peer BAR (P2P side) */
    uint32_t p2p_xfers;       /* P2P transfers completed */
    uint64_t p2p_bytes;       /* P2P bytes moved */
    uint32_t fault_ctrl;      /* fault control (0x74) */
    uint32_t fault_status;    /* fault status (0x78) */
    uint64_t fault_addr;      /* first faulting byte (0x7c/0x80) */
    uint32_t fault_count;     /* faults latched (0x84) */
    uint64_t fault_win_base;  /* fault window base (0x88/0x8c) */
    uint32_t fault_win_size;  /* fault window size (0x90), 0 = off */
    uint32_t aer_count;       /* AER injections (0x98) */
    bool retry_ring;          /* the faulted op was a ring batch */
    unsigned retry_queue;     /* ...and which queue */
    QEMUBH *bh;
} Nto64DmaState;

/*
 * One queue: ring state + its own DMA address space rooted at the
 * bound vCPU's memory view.
 */
typedef struct Nto64DmaQueue {
    MemoryRegion *root;
    AddressSpace *as;
    uint64_t ring_base;
    uint32_t ring_count;
    uint32_t ring_stride;
    uint32_t ring_done;
    uint32_t xfers;
    uint64_t bytes;
} Nto64DmaQueue;

typedef enum Nto64DmaResult {
    NTO64_DMA_OK,
    NTO64_DMA_FAULT,
    NTO64_DMA_ERR,
} Nto64DmaResult;

/* Does [addr, addr+len) overlap the fault window? */
static bool nto64_dma_in_window(Nto64DmaState *s, hwaddr addr, uint32_t len)
{
    uint64_t wb = s->fault_win_base;
    uint64_t we = wb + s->fault_win_size;

    if (!(s->fault_ctrl & NTO64_DMA_FAULT_WIN) || !s->fault_win_size) {
        return false;
    }
    return addr + len > wb && addr < we;
}

/*
 * First byte of [addr, addr+len) inside the window (the faulting
 * byte the OS's fault path would resolve).
 */
static hwaddr nto64_dma_fault_byte(Nto64DmaState *s, hwaddr addr)
{
    uint64_t wb = s->fault_win_base;

    return addr < wb ? wb : addr;
}

/*
 * Chunked copy with per-chunk PRI-like fault checks on the device-AS
 * side (the peer BAR side is device memory - no page faults there).
 * A chunk overlapping the window returns FAULT before moving it, so
 * everything before the faulting chunk stays written (partial
 * progress, like a page fault mid-DMA).  Returns OK/FAULT/ERR.
 */
static Nto64DmaResult nto64_dma_copy_checked(Nto64DmaState *s,
                                             AddressSpace *dev_as,
                                             hwaddr src, hwaddr dst,
                                             uint32_t len,
                                             bool src_peer, bool dst_peer,
                                             uint8_t *buf)
{
    AddressSpace *src_as = src_peer ? s->peer_as : dev_as;
    AddressSpace *dst_as = dst_peer ? s->peer_as : dev_as;
    uint64_t off;

    if ((s->fault_ctrl & NTO64_DMA_FAULT_INJECT) && len) {
        /* injected fault: the next transfer faults at its first byte */
        s->fault_addr = src_peer ? dst : src;
        return NTO64_DMA_FAULT;
    }
    for (off = 0; off < len; off += NTO64_DMA_CHUNK) {
        uint32_t chunk = MIN(NTO64_DMA_CHUNK, len - off);
        MemTxResult r1, r2;

        if (!src_peer && nto64_dma_in_window(s, src + off, chunk)) {
            s->fault_addr = nto64_dma_fault_byte(s, src + off);
            return NTO64_DMA_FAULT;
        }
        if (!dst_peer && nto64_dma_in_window(s, dst + off, chunk)) {
            s->fault_addr = nto64_dma_fault_byte(s, dst + off);
            return NTO64_DMA_FAULT;
        }
        r1 = address_space_rw(src_as, src + off,
                              MEMTXATTRS_UNSPECIFIED, buf, chunk, false);
        r2 = address_space_rw(dst_as, dst + off,
                              MEMTXATTRS_UNSPECIFIED, buf, chunk, true);
        if (r1 != MEMTX_OK || r2 != MEMTX_OK) {
            return NTO64_DMA_ERR;
        }
    }
    return NTO64_DMA_OK;
}

/*
 * One transfer, with optional peer-BAR endpoints (P2P):
 * a peer endpoint address is an offset into the peer BAR resolved in
 * realize (`peer` + `peer-bar`); the other endpoint goes through the
 * caller's address space (the bulk engine's AS or a queue's AS).
 */
static Nto64DmaResult nto64_dma_xfer(Nto64DmaState *s, AddressSpace *dev_as,
                                     hwaddr src, hwaddr dst, uint32_t len,
                                     bool src_peer, bool dst_peer,
                                     uint8_t *buf)
{
    /*
     * A ring descriptor may name either endpoint as a peer BAR offset
     * even when the device has no `peer` (s->peer_as is NULL then).
     * That is a guest/descriptor error: fail the transfer like the
     * bulk P2P path does instead of handing NULL to address_space_rw().
     */
    if ((src_peer || dst_peer) && !s->peer_as) {
        return NTO64_DMA_ERR;
    }
    return nto64_dma_copy_checked(s, dev_as, src, dst, len,
                                  src_peer, dst_peer, buf);
}

/*
 * Bulk-mode P2P copy: direction from control bit4.  Returns OK only
 * if a peer is configured; FAULT/ERR propagate.
 */
static Nto64DmaResult nto64_dma_copy_peer(Nto64DmaState *s, hwaddr src,
                                          hwaddr dst, uint32_t len)
{
    bool rev = s->control & NTO64_DMA_CTRL_P2PREV;

    if (!s->peer_mr) {
        return NTO64_DMA_ERR;
    }
    return nto64_dma_xfer(s, s->dma_as, src, dst, len, rev, !rev,
                          s->bounce);
}

/*
 * Latch a device fault: stop the transfer, record the address, raise
 * the fault MSI-X vector (`queues`), and remember the interrupted
 * operation for the resolve/retry path.
 */
static void nto64_dma_latch_fault(Nto64DmaState *s, hwaddr addr,
                                  bool ring, unsigned q)
{
    s->status = NTO64_DMA_ST_FAULT;
    s->fault_status = NTO64_DMA_FST_PENDING;
    s->fault_addr = addr;
    s->fault_count++;
    s->fault_ctrl &= ~NTO64_DMA_FAULT_INJECT;   /* consumed */
    s->retry_ring = ring;
    s->retry_queue = q;
    if (s->fault_ctrl & NTO64_DMA_FAULT_IRQEN) {
        msix_notify(&s->pdev, s->queues_n);
    }
    info_report("nto64-dma: fault @ %#" PRIx64 " (count %u)",
                addr, s->fault_count);
}

/* One ring descriptor: +0 src, +4 dst, +8 len, +0xc flags. */
typedef struct Nto64DmaDesc {
    uint32_t src;
    uint32_t dst;
    uint32_t len;
    uint32_t flags;
} Nto64DmaDesc;

/*
 * Run one ring batch for queue q: descriptors are fetched and transfers
 * run through queue q's own address space (the bound vCPU's view); each
 * completed message fires completion MSI-X vector q.
 */
static void nto64_dma_ring_q(Nto64DmaState *s, unsigned q)
{
    Nto64DmaQueue *qq = &s->queues[q];
    hwaddr daddr;
    uint32_t i;

    qq->ring_done = 0;
    for (i = 0; i < qq->ring_count; i++) {
        Nto64DmaDesc d;

        daddr = qq->ring_base + (uint64_t)i * qq->ring_stride;
        if (address_space_read(qq->as, daddr, MEMTXATTRS_UNSPECIFIED,
                               &d, sizeof(d)) != MEMTX_OK) {
            /*
             * truncated / unmapped ring: a real engine latches an
             * error instead of reporting DONE (2026-08-22 fix).
             */
            s->status = NTO64_DMA_ST_ERR;
            return;
        }
        if (!(d.flags & 1)) {
            /* the valid bit ran out before ring_count: truncated. */
            s->status = NTO64_DMA_ST_ERR;
            return;
        }
        if (d.len > s->max_xfer) {
            s->status = NTO64_DMA_ST_ERR;
            return;
        }
        switch (nto64_dma_xfer(s, qq->as, d.src, d.dst, d.len,
                               !!(d.flags & NTO64_DMA_DESC_PEER_SRC),
                               !!(d.flags & NTO64_DMA_DESC_PEER_DST),
                               s->bounce)) {
        case NTO64_DMA_FAULT:
            nto64_dma_latch_fault(s, s->fault_addr, true, q);
            return;
        case NTO64_DMA_ERR:
            s->status = NTO64_DMA_ST_ERR;
            return;
        default:
            break;
        }
        d.flags |= 2;
        if (address_space_write(qq->as, daddr + 12,
                                MEMTXATTRS_UNSPECIFIED, &d.flags,
                                4) != MEMTX_OK) {
            s->status = NTO64_DMA_ST_ERR;
            return;
        }
        if (d.flags & (NTO64_DMA_DESC_PEER_SRC | NTO64_DMA_DESC_PEER_DST)) {
            s->p2p_xfers++;
            s->p2p_bytes += d.len;
        }
        qq->xfers++;
        qq->bytes += d.len;
        qq->ring_done = i + 1;
        if (s->control & NTO64_DMA_CTRL_IRQ) {
            msix_notify(&s->pdev, q);
        }
    }
    /* a latched error (e.g. start-while-busy) survives the completion */
    if (!(s->status & NTO64_DMA_ST_ERR)) {
        s->status = NTO64_DMA_ST_DONE;
    }
}

/* Snapshot the register-set bulk transfer parameters at start/retry. */
static void nto64_dma_bulk_begin(Nto64DmaState *s)
{
    s->bulk_len = MIN(s->size, s->max_xfer);
    s->bulk_src = s->src;
    s->bulk_dst = s->dst;
    s->bulk_off = 0;
    s->bulk_p2p = !!(s->control & NTO64_DMA_CTRL_P2P);
    s->bulk_rev = !!(s->control & NTO64_DMA_CTRL_P2PREV);
}

/*
 * Runs on the main loop (bottom half): the transfer is asynchronous,
 * so the guest's start write returns immediately and the device never
 * blocks a vCPU inside an MMIO handler (or re-enters other regions
 * while the BQL is held).  A bulk transfer processes a bounded burst
 * of 1 MiB chunks per invocation and re-schedules itself, so a
 * max-xfer (default 1 GiB) copy does not stall every vCPU for its
 * whole duration.
 */
static void nto64_dma_bh(void *opaque)
{
    Nto64DmaState *s = opaque;
    Nto64DmaResult r;
    unsigned burst;

    if (!(s->status & NTO64_DMA_ST_BUSY)) {
        return;
    }

    if (s->queue_start) {
        s->queue_start = false;
        if (s->ring_queue < s->queues_n) {
            nto64_dma_ring_q(s, s->ring_queue);
        } else {
            s->status = NTO64_DMA_ST_ERR;
        }
        return;
    }

    if (s->retry_ring) {
        /* resolve/retry: re-run the faulted ring batch */
        s->retry_ring = false;
        if (s->retry_queue < s->queues_n) {
            nto64_dma_ring_q(s, s->retry_queue);
        } else {
            s->status = NTO64_DMA_ST_ERR;
        }
        return;
    }

    if (s->control & NTO64_DMA_CTRL_RING) {
        nto64_dma_ring_q(s, 0);   /* legacy single-ring = queue 0 */
        return;
    }

    if (!s->bulk_len) {
        s->status = NTO64_DMA_ST_ERR;
        return;
    }
    burst = 0;
    while (s->bulk_off < s->bulk_len && burst < NTO64_DMA_BH_BURST) {
        uint32_t chunk = MIN(NTO64_DMA_CHUNK, s->bulk_len - s->bulk_off);
        hwaddr src = s->bulk_src + s->bulk_off;
        hwaddr dst = s->bulk_dst + s->bulk_off;

        if (s->bulk_p2p) {
            r = nto64_dma_copy_peer(s, src, dst, chunk);
        } else {
            r = nto64_dma_copy_checked(s, s->dma_as, src, dst, chunk,
                                       false, false, s->bounce);
        }
        if (r == NTO64_DMA_FAULT) {
            nto64_dma_latch_fault(s, s->fault_addr, false, 0);
            return;
        }
        if (r != NTO64_DMA_OK) {
            s->status = NTO64_DMA_ST_ERR;
            return;
        }
        s->bulk_off += chunk;
        burst++;
    }

    if (s->bulk_off < s->bulk_len) {
        /*
         * More work remains: yield to the main loop (and the other
         * vCPUs under mttcg) and continue on the next BH slice.
         */
        qemu_bh_schedule(s->bh);
        return;
    }

    if (s->bulk_p2p) {
        s->p2p_xfers++;
        s->p2p_bytes += s->bulk_len;
        s->xfers++;
        s->bytes += s->bulk_len;
        if (!(s->status & NTO64_DMA_ST_ERR)) {
            s->status = NTO64_DMA_ST_DONE;
        }
        if (s->control & NTO64_DMA_CTRL_IRQ) {
            msix_notify(&s->pdev, 0);
        }
        info_report("nto64-dma: p2p %s %u bytes (%" PRIx64
                    " -> peer +%" PRIx64 ")",
                    s->bulk_rev ? "in" : "out",
                    s->bulk_len, s->bulk_src, s->bulk_dst);
        return;
    }

    s->xfers++;
    s->bytes += s->bulk_len;
    if (!(s->status & NTO64_DMA_ST_ERR)) {
        s->status = NTO64_DMA_ST_DONE;
    }
    if (s->control & NTO64_DMA_CTRL_IRQ) {
        msix_notify(&s->pdev, 0);
    }
    info_report("nto64-dma: xfer %u, %u bytes (%" PRIx64 " -> %" PRIx64 ")",
                s->xfers, s->bulk_len, s->bulk_src, s->bulk_dst);
}

static void nto64_dma_start(Nto64DmaState *s)
{
    if (s->status & NTO64_DMA_ST_BUSY) {
        /*
         * start-while-busy must not be silently dropped: latch the
         * error like a real engine (2026-08-22 fix).
         */
        s->status = NTO64_DMA_ST_ERR;
        return;
    }
    if (!(s->control & NTO64_DMA_CTRL_RING)) {
        nto64_dma_bulk_begin(s);
    }
    s->status = NTO64_DMA_ST_BUSY;
    qemu_bh_schedule(s->bh);
}

/* Start one queue's ring batch asynchronously (0x54). */
static void nto64_dma_start_queue(Nto64DmaState *s, unsigned q)
{
    if (q >= s->queues_n) {
        return;
    }
    if (s->status & NTO64_DMA_ST_BUSY) {
        s->status = NTO64_DMA_ST_ERR;
        return;
    }
    s->ring_queue = q;
    s->queue_start = true;
    s->status = NTO64_DMA_ST_BUSY;
    qemu_bh_schedule(s->bh);
}

static uint64_t nto64_dma_read(void *opaque, hwaddr addr, unsigned size)
{
    Nto64DmaState *s = opaque;
    Nto64DmaQueue *qq;

    (void)size;
    switch (addr) {
    case 0x00:
        return NTO64_DMA_MAGIC;
    case 0x04:
        return s->control;
    case 0x08:
        return (uint32_t)s->src;
    case 0x0c:
        return (uint32_t)(s->src >> 32);
    case 0x10:
        return (uint32_t)s->dst;
    case 0x14:
        return (uint32_t)(s->dst >> 32);
    case 0x18:
        return s->size;
    case 0x1c:
        return s->status;
    case 0x20:
        return s->xfers;
    case 0x24:
        return (uint32_t)s->bytes;
    case 0x28:
        qq = &s->queues[0];
        return (uint32_t)qq->ring_base;
    case 0x2c:
        qq = &s->queues[0];
        return (uint32_t)(qq->ring_base >> 32);
    case 0x30:
        qq = &s->queues[0];
        return qq->ring_count;
    case 0x34:
        qq = &s->queues[0];
        return qq->ring_stride;
    case 0x38:
        qq = &s->queues[0];
        return qq->ring_done;
    case 0x3c:
        return s->queues_n;
    case 0x40:
        return s->qselect;
    case 0x44:
        qq = &s->queues[s->qselect];
        return (uint32_t)qq->ring_base;
    case 0x48:
        qq = &s->queues[s->qselect];
        return (uint32_t)(qq->ring_base >> 32);
    case 0x4c:
        qq = &s->queues[s->qselect];
        return qq->ring_count;
    case 0x50:
        qq = &s->queues[s->qselect];
        return qq->ring_stride;
    case 0x58:
        qq = &s->queues[s->qselect];
        return qq->ring_done;
    case 0x5c:
        qq = &s->queues[s->qselect];
        return qq->xfers;
    case 0x60:
        qq = &s->queues[s->qselect];
        return (uint32_t)qq->bytes;
    case 0x64:
        qq = &s->queues[s->qselect];
        return (uint32_t)(qq->bytes >> 32);
    case 0x68:
        return s->p2p_xfers;
    case 0x6c:
        return (uint32_t)s->p2p_bytes;
    case 0x70:
        return (uint32_t)(s->p2p_bytes >> 32);
    case 0x74:
        return s->fault_ctrl;
    case 0x78:
        return s->fault_status;
    case 0x7c:
        return (uint32_t)s->fault_addr;
    case 0x80:
        return (uint32_t)(s->fault_addr >> 32);
    case 0x84:
        return s->fault_count;
    case 0x88:
        return (uint32_t)s->fault_win_base;
    case 0x8c:
        return (uint32_t)(s->fault_win_base >> 32);
    case 0x90:
        return s->fault_win_size;
    case 0x98:
        return s->aer_count;
    default:
        return 0;
    }
}

static void nto64_dma_write(void *opaque, hwaddr addr,
                            uint64_t val, unsigned size)
{
    Nto64DmaState *s = opaque;
    Nto64DmaQueue *qq;

    (void)size;
    switch (addr) {
    case 0x04:
        s->control = (uint32_t)val & (NTO64_DMA_CTRL_START |
                                      NTO64_DMA_CTRL_IRQ |
                                      NTO64_DMA_CTRL_RING |
                                      NTO64_DMA_CTRL_P2P |
                                      NTO64_DMA_CTRL_P2PREV);
        if (s->control & NTO64_DMA_CTRL_START) {
            nto64_dma_start(s);
        }
        break;
    case 0x08:
        s->src = (s->src & 0xffffffff00000000ULL) | (uint32_t)val;
        break;
    case 0x0c:
        s->src = (s->src & 0x00000000ffffffffULL) | ((uint64_t)val << 32);
        break;
    case 0x10:
        s->dst = (s->dst & 0xffffffff00000000ULL) | (uint32_t)val;
        break;
    case 0x14:
        s->dst = (s->dst & 0x00000000ffffffffULL) | ((uint64_t)val << 32);
        break;
    case 0x18:
        s->size = (uint32_t)val;
        break;
    case 0x1c:
        s->status = 0;
        break;
    case 0x28:
        qq = &s->queues[0];
        qq->ring_base = (qq->ring_base & 0xffffffff00000000ULL) |
                        (uint32_t)val;
        break;
    case 0x2c:
        qq = &s->queues[0];
        qq->ring_base = (qq->ring_base & 0x00000000ffffffffULL) |
                        ((uint64_t)val << 32);
        break;
    case 0x30:
        s->queues[0].ring_count = (uint32_t)val;
        break;
    case 0x34:
        s->queues[0].ring_stride = (uint32_t)val;
        break;
    case 0x40:
        s->qselect = (uint32_t)val % s->queues_n;
        break;
    case 0x44:
        qq = &s->queues[s->qselect];
        qq->ring_base = (qq->ring_base & 0xffffffff00000000ULL) |
                        (uint32_t)val;
        break;
    case 0x48:
        qq = &s->queues[s->qselect];
        qq->ring_base = (qq->ring_base & 0x00000000ffffffffULL) |
                        ((uint64_t)val << 32);
        break;
    case 0x4c:
        qq = &s->queues[s->qselect];
        qq->ring_count = (uint32_t)val;
        break;
    case 0x50:
        qq = &s->queues[s->qselect];
        qq->ring_stride = (uint32_t)val;
        break;
    case 0x54:
        if (val & 1) {
            nto64_dma_start_queue(s, s->qselect);
        }
        break;
    case 0x74:
        s->fault_ctrl = (uint32_t)val &
            (NTO64_DMA_FAULT_WIN | NTO64_DMA_FAULT_INJECT |
             NTO64_DMA_FAULT_IRQEN);
        if (val & NTO64_DMA_FAULT_RESOLVE) {
            if (s->fault_status & NTO64_DMA_FST_PENDING) {
                s->fault_status = 0;
                if (!s->retry_ring) {
                    /*
                     * bulk fault: re-snapshot the register-set op and
                     * retry it from the start
                     */
                    nto64_dma_bulk_begin(s);
                }
                s->status = NTO64_DMA_ST_BUSY;
                qemu_bh_schedule(s->bh);
                info_report("nto64-dma: fault resolved, retrying");
            }
        }
        break;
    case 0x88:
        s->fault_win_base = (s->fault_win_base &
                             0xffffffff00000000ULL) | (uint32_t)val;
        break;
    case 0x8c:
        s->fault_win_base = (s->fault_win_base &
                             0x00000000ffffffffULL) |
                            ((uint64_t)val << 32);
        break;
    case 0x90:
        s->fault_win_size = (uint32_t)val;
        break;
    case 0x94:
        /*
         * PCIe AER injection (Step-gap transport-error fold): the guest
         * arms a correctable / uncorrectable (non-fatal) / uncorrectable
         * (fatal) error through the standard AER log.  The guest then
         * observes the device's AER capability in config space.
         */
        if (val == NTO64_DMA_AER_COR) {
            PCIEAERErr err = {
                .status = PCI_ERR_COR_RCVR,
                .flags = PCIE_AER_ERR_IS_CORRECTABLE |
                         PCIE_AER_ERR_HEADER_VALID,
                .header = { 0x00001234, 0x00005678,
                            0x00009abc, 0x0000def0 },
            };
            if (pcie_aer_inject_error(&s->pdev, &err) == 0) {
                s->aer_count++;
            }
        } else if (val == NTO64_DMA_AER_UNC) {
            PCIEAERErr err = {
                .status = PCI_ERR_UNC_DLP,
                .flags = PCIE_AER_ERR_HEADER_VALID,
                .header = { 0x00001234, 0x00005678,
                            0x00009abc, 0x0000def0 },
            };
            if (pcie_aer_inject_error(&s->pdev, &err) == 0) {
                s->aer_count++;
            }
        } else if (val == NTO64_DMA_AER_FAT) {
            PCIEAERErr err = {
                .status = PCI_ERR_UNC_INTN,
                .flags = PCIE_AER_ERR_HEADER_VALID,
                .header = { 0x00001234, 0x00005678,
                            0x00009abc, 0x0000def0 },
            };
            if (pcie_aer_inject_error(&s->pdev, &err) == 0) {
                s->aer_count++;
            }
        }
        break;
    case 0x98:
        s->aer_count = 0;
        break;
    default:
        break;
    }
}

static const MemoryRegionOps nto64_dma_ops = {
    .read = nto64_dma_read,
    .write = nto64_dma_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

/*
 * Release what the engine registered for itself.  This has to cover a
 * failed realize as well as a normal unplug, because a device whose
 * realize returns an error never runs its .exit (pci_qdev_realize() just
 * unregisters the function).  The per-queue AddressSpace objects live
 * while being linked into the global address_spaces list - which every
 * memory transaction commit walks, and whose tail pointer the next
 * address_space_init() writes through - so they must leave that list
 * before the object holding them is freed.  address_space_destroy()
 * only detaches the AddressSpace; the object itself is torn down from
 * an RCU callback (readers keep walking the old flatview until the
 * grace period ends), so whoever owns the memory holding it must still
 * be alive then.  Every AS here is therefore its own heap allocation,
 * released with address_space_destroy_free(), which frees it from that
 * callback - this state (and the @queues array of pointers) can go away
 * as soon as the call returns.
 * Safe to call twice and at any point in realize.
 */
static void nto64_dma_release(Nto64DmaState *s)
{
    int i;

    if (s->bh) {
        qemu_bh_delete(s->bh);
        s->bh = NULL;
    }
    g_free(s->bounce);
    s->bounce = NULL;

    if (s->queues) {
        for (i = 0; i < s->queues_n; i++) {
            /* as is set exactly when that queue's AS was initialised */
            if (s->queues[i].as) {
                address_space_destroy_free(s->queues[i].as);
                s->queues[i].as = NULL;
            }
        }
        g_free(s->queues);
        s->queues = NULL;
    }
    if (s->peer_as) {
        address_space_destroy_free(s->peer_as);
        s->peer_as = NULL;
        s->peer_mr = NULL;
    }
    if (s->dma_as) {
        address_space_destroy_free(s->dma_as);
        s->dma_as = NULL;
        s->dma_root = NULL;
    }
}

static void nto64_dma_realize(PCIDevice *pci_dev, Error **errp)
{
    Nto64DmaState *s = NTO64_DMA(pci_dev);
    CPUState *cpu = qemu_get_cpu(s->node);
    int i;

    if (!s->iommu && (!cpu || !cpu->memory)) {
        error_setg(errp, "nto64-dma: node %u has no memory view",
                   s->node);
        return;
    }
    if (s->queues_n < 1 || s->queues_n > NTO64_DMA_QUEUE_MAX) {
        error_setg(errp, "nto64-dma: queues must be 1..%u",
                   NTO64_DMA_QUEUE_MAX);
        return;
    }
    /*
     * DMA address space selection: by default the engine is bound to a
     * vCPU's memory view (node) - that AS bypasses any
     * guest-visible IOMMU, because device DMA through an AS rooted at
     * the vCPU view never enters the PCI bus's IOMMU translation.  With
     * `iommu=on` the engine's AS is rooted at the PCI/IOMMU address
     * space (pci_device_iommu_address_space), so DMA IOVAs are
     * translated by the guest-programmed IOMMU page tables (VT-d /
     * AMD-Vi) instead of resolving through the node view -
     * per-CPU-AS x IOMMU interplay question.
     */
    if (s->iommu) {
        s->dma_root = pci_device_iommu_address_space(pci_dev)->root;
        info_report("nto64-dma: DMA AS via PCI IOMMU");
    } else {
        s->dma_root = cpu->memory;
    }
    s->dma_as = g_new0(AddressSpace, 1);
    address_space_init(s->dma_as, s->dma_root, "nto64-dma-as");
    if (s->peer) {
        if (s->peer_bar >= PCI_NUM_REGIONS ||
            !s->peer->io_regions[s->peer_bar].memory ||
            (s->peer->io_regions[s->peer_bar].type &
             PCI_BASE_ADDRESS_SPACE_IO)) {
            error_setg(errp, "nto64-dma: peer BAR %u is not a memory BAR",
                       s->peer_bar);
            goto out_err;
        }
        s->peer_mr = s->peer->io_regions[s->peer_bar].memory;
        s->peer_as = g_new0(AddressSpace, 1);
        address_space_init(s->peer_as, s->peer_mr, "nto64-dma-peer-as");
        info_report("nto64-dma: P2P peer %s BAR %u",
                    object_get_canonical_path_component(OBJECT(s->peer)),
                    s->peer_bar);
    }
    s->queues = g_new0(Nto64DmaQueue, s->queues_n);
    for (i = 0; i < s->queues_n; i++) {
        Nto64DmaQueue *qq = &s->queues[i];

        if (s->iommu) {
            qq->root = s->dma_root;
        } else {
            CPUState *qc = qemu_get_cpu(i);

            if (!qc || !qc->memory) {
                error_setg(errp,
                           "nto64-dma: queue %u needs vCPU %u memory view",
                           i, i);
                goto out_err;
            }
            qq->root = qc->memory;
        }
        qq->ring_stride = 16;
        qq->as = g_new0(AddressSpace, 1);
        address_space_init(qq->as, qq->root, "nto64-dma-q-as");
    }
    s->bh = qemu_bh_new(nto64_dma_bh, s);
    s->bounce = g_malloc(NTO64_DMA_CHUNK);

    pci_config_set_interrupt_pin(pci_dev->config, 1);   /* INTx#A (unused) */
    memory_region_init_io(&s->ctrl, OBJECT(s), &nto64_dma_ops, s,
                          "nto64-dma-ctrl", NTO64_DMA_CTRL_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->ctrl);

    /* queues_n completion vectors + one fault vector */
    if (msix_init_exclusive_bar(pci_dev, s->queues_n + 1, 1, errp)) {
        goto out_err;
    }
    for (i = 0; i <= s->queues_n; i++) {
        msix_vector_use(pci_dev, i);
    }
    /*
     * PCIe endpoint capability + AER (the transport-error testbed
     * hook): the guest arms injections via BAR0+0x94.
     */
    pcie_endpoint_cap_init(pci_dev, NTO64_DMA_EXP_OFFSET);
    if (pcie_aer_init(pci_dev, PCI_ERR_VER, NTO64_DMA_AER_OFFSET,
                      PCI_ERR_SIZEOF, errp) < 0) {
        msix_uninit_exclusive_bar(pci_dev);
        goto out_err;
    }
    info_report("nto64-dma: ready (%u queues, queue i -> vCPU i; "
                "bulk DMA AS bound to vCPU %u; fault vector %u)",
                s->queues_n, s->node, s->queues_n);
    return;

out_err:
    nto64_dma_release(s);
}

static void nto64_dma_exit(PCIDevice *pci_dev)
{
    Nto64DmaState *s = NTO64_DMA(pci_dev);

    msix_unuse_all_vectors(pci_dev);
    msix_uninit_exclusive_bar(pci_dev);
    pcie_aer_exit(pci_dev);
    pcie_cap_exit(pci_dev);
    nto64_dma_release(s);
}

static const Property nto64_dma_props[] = {
    DEFINE_PROP_UINT32("node", Nto64DmaState, node, 0),
    DEFINE_PROP_UINT32("max-xfer", Nto64DmaState, max_xfer,
                       NTO64_DMA_MAX_XFER),
    DEFINE_PROP_UINT32("queues", Nto64DmaState, queues_n,
                       NTO64_DMA_QUEUES_DEFAULT),
    DEFINE_PROP_BOOL("iommu", Nto64DmaState, iommu, false),
    DEFINE_PROP_LINK("peer", Nto64DmaState, peer, TYPE_PCI_DEVICE,
                     PCIDevice *),
    DEFINE_PROP_UINT32("peer-bar", Nto64DmaState, peer_bar, 0),
};

static void nto64_dma_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    (void)data;
    k->realize = nto64_dma_realize;
    k->exit = nto64_dma_exit;
    k->vendor_id = NTO64_DMA_VENDOR;
    k->device_id = NTO64_DMA_DEVICE;
    k->revision = NTO64_DMA_REVISION;
    k->class_id = NTO64_DMA_CLASS;
    k->subsystem_vendor_id = NTO64_DMA_VENDOR;
    k->subsystem_id = NTO64_DMA_DEVICE;
    device_class_set_props(dc, nto64_dma_props);
    dc->desc = "nto64-dma: DMA engine bound to a vCPU (node)";
}

static const TypeInfo nto64_dma_info = {
    .name = TYPE_NTO64_DMA,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(Nto64DmaState),
    .class_init = nto64_dma_class_init,
    .interfaces = (InterfaceInfo[]) {
        /*
         * Express (NVMe-style): 4 KiB config space + the PCIe/AER
         * capabilities, on q35 (ECAM) and the legacy pc machine
         * alike.
         */
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void nto64_dma_register_types(void)
{
    type_register_static(&nto64_dma_info);
}

type_init(nto64_dma_register_types)
