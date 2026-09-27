/* SPDX-License-Identifier: GPL-2.0-or-later */

/*
 * Copyright (C) 2026, the nto64 project
 *
 * slotwatch.c - name the writer of ONE 4-byte slot, without stopping the world.
 *
 * The instrument this replaces is a hardware watchpoint: it needs the guest
 * stopped, and the fault it was pointed at (a path manager's table slot
 * taking a code address during its own init) is a concurrency window that
 * stopping deletes - 40 of 40 watched boots were clean where free-running
 * boots failed about one time in six.  So the watch lives in the TCG
 * translation path instead: it hooks every STORE of the instructions in the
 * chosen code ranges and logs the ones that land on the slot.
 *
 * ADDRESSES, NOT NAMES.  The slot is watched by BOTH its virtual address and
 * the physical frame that address maps to: a user-side writer stores to the
 * virtual address, but a KERNEL writer reaches the same bytes through its
 * per-CPU copy window (a different virtual address, the same frame), and only
 * the physical comparison catches that.  The frame is LEARNED from the first
 * store to the virtual address (which is the owner's own, expected write), so
 * the caller only has to know the slot's VA and the code ranges to hook.
 *
 * USAGE (one plugin per run; -plugin splits its arguments on ','):
 *
 *   -plugin file=plugins/slotwatch.so,\
 *           slot=0x0a02ee08,\
 *           code=0x0a000000:0x0a00a700,\
 *           code=0xffffffff8014d040:0xffffffff8014d460,\
 *           budget=16
 *
 *   slot=VA        the 4-byte slot to watch (required)
 *   code=LO:HI     instrument the stores of the instructions in [LO,HI);
 *                  repeatable, up to 8 ranges.  No code= means every
 *                  instruction (very slow, but complete).
 *   budget=N       printed hits before suppression (default 16)
 *   frame=PHYS     watch the byte at PHYS+frameoff directly (a KERNEL
 *   frameoff=OFF   writer reaches the same frame through its copy window,
 *                  so the VA alone would never see it).  frameoff= requires
 *                  frame= and defaults to slot's page offset.
 *   frameany=1     watch every byte in frame= (conflicts with frameoff=).
 *   physlo=LO      watch a PHYSICAL RANGE; both bounds are required and LO
 *   physhi=HI      must be below HI.
 *
 * OUTPUT (stderr):
 *
 *   SLOTWATCH-ARM slot=.. code=.. budget=..
 *   SLOTWATCH-LEARN cpu=.. pc=0x.. vaddr=0x.. phys=0x.. frame=0x..
 *   SLOTWATCH-WRITE cpu=.. pc=0x.. vaddr=0x.. phys=0x.. value=0x..
 *                  size=.. via=slot|frame src=kernel|user
 *   SLOTWATCH-SUMMARY stores=.. hits=.. kernel=.. user=.. via_frame=..
 *                    suppressed=.. armed=yes stores_observed=yes|no
 *                    target_hits=.. measured=yes|NO-MEASUREMENT
 *
 * A run that hooked nothing, or saw no store at all, reports
 * measured=NO-MEASUREMENT and never a clean bill of health.
 */

#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define SW_MAX_RANGES 8

typedef struct {
    uint64_t lo, hi;
} sw_range_t;

typedef struct {
    uint64_t pc;
    uint32_t size;
} sw_insn_t;

static sw_insn_t sw_insns_tbl[1 << 16]; /* one entry per hooked instruction */
static size_t sw_insns_used;

static sw_range_t sw_ranges[SW_MAX_RANGES];
static int sw_nranges;
static uint64_t sw_slot;
static uint64_t sw_slot_off;
static uint64_t sw_frame;               /* learned from the owner's own store */
static bool sw_have_frame;
static bool sw_have_frameoff;
static bool sw_have_physlo;
static bool sw_have_physhi;
static int sw_budget = 16;

static uint64_t sw_stores;
static uint64_t sw_hits;
static uint64_t sw_kernel;
static uint64_t sw_user;
static uint64_t sw_via_frame;
static uint64_t sw_suppressed;
static uint64_t sw_insns;
static pthread_mutex_t sw_mtx = PTHREAD_MUTEX_INITIALIZER;
static bool sw_need_phys;               /* a hooked range is kernel code */
static bool sw_frame_any;               /* watch the whole frame page */
static uint64_t sw_phys_lo, sw_phys_hi; /* watch a PHYSICAL range */
static uint64_t sw_cs_lo, sw_cs_hi;     /* log stores OF code addresses */
static uint64_t sw_cs_hits;
static uint64_t sw_cs_budget = 24;
static bool sw_callpush;                /* keep a ring of call pushes */
static int sw_ring_dumps;

#define SW_RING 64
static struct {
    uint64_t pc, vaddr, value;
    unsigned cpu;
} sw_ring[SW_RING];
static unsigned sw_ring_head;

static void sw_ring_show(const char *why)
{
    unsigned n, i;

    if (!sw_callpush || sw_ring_dumps >= 4)
        return;
    sw_ring_dumps++;
    n = sw_ring_head < SW_RING ? sw_ring_head : SW_RING;
    fprintf(stderr, "SLOTWATCH-TRAIL why=%s pushes=%u\n", why, sw_ring_head);
    for (i = 0; i < n; i++) {
        unsigned k = (sw_ring_head - n + i) % SW_RING;
        fprintf(stderr, "SLOTWATCH-TRAIL   cpu=%u callpc=0x%" PRIx64
                " ret=0x%" PRIx64 " sp=0x%" PRIx64 "\n",
                sw_ring[k].cpu, sw_ring[k].pc, sw_ring[k].value,
                sw_ring[k].vaddr);
    }
}

static uint64_t sw_mem_value_u64(qemu_plugin_mem_value v)
{
    switch (v.type) {
    case QEMU_PLUGIN_MEM_VALUE_U8:
        return v.data.u8;
    case QEMU_PLUGIN_MEM_VALUE_U16:
        return v.data.u16;
    case QEMU_PLUGIN_MEM_VALUE_U32:
        return v.data.u32;
    case QEMU_PLUGIN_MEM_VALUE_U64:
        return v.data.u64;
    case QEMU_PLUGIN_MEM_VALUE_U128:
        return v.data.u128.low;
    default:
        return 0;
    }
}

static bool sw_in_range(uint64_t pc)
{
    int i;

    if (!sw_nranges)
        return true;                    /* no filter: every instruction */
    for (i = 0; i < sw_nranges; i++)
        if (pc >= sw_ranges[i].lo && pc < sw_ranges[i].hi)
            return true;
    return false;
}

static void sw_mem_cb(unsigned cpu, qemu_plugin_meminfo_t info,
                      uint64_t vaddr, void *ud)
{
    const sw_insn_t *insn = ud;
    const uint64_t pc = insn->pc;
    const uint64_t insn_len = insn->size;
    const bool store = qemu_plugin_mem_is_store(info);
    const uint64_t size = 1ull << qemu_plugin_mem_size_shift(info);
    struct qemu_plugin_hwaddr *ha;
    uint64_t phys = 0, value = 0;
    bool hit;

    if (!store)
        return;

    if (sw_need_phys) {
        ha = qemu_plugin_get_hwaddr(info, vaddr);
        if (ha)
            phys = qemu_plugin_hwaddr_phys_addr(ha);
    }

    pthread_mutex_lock(&sw_mtx);
    sw_stores++;
    if (!sw_frame && vaddr == sw_slot && phys) {
        sw_frame = phys & ~0xFFFULL;
        fprintf(stderr, "SLOTWATCH-LEARN cpu=%u pc=0x%" PRIx64
                " vaddr=0x%" PRIx64 " phys=0x%" PRIx64
                " frame=0x%" PRIx64 "\n",
                cpu, pc, vaddr, phys, sw_frame);
    }
    hit = (vaddr == sw_slot) ||
          (sw_frame && (phys & ~0xFFFULL) == sw_frame &&
           (sw_frame_any || (phys & 0xFFFULL) == sw_slot_off)) ||
          (sw_phys_hi && phys >= sw_phys_lo && phys < sw_phys_hi);
    if (!hit) {
     /* Not the slot: still worth a line if this store wrote a CODE ADDRESS
      * (into the stack, say) - that is how a slot can take a code address
      * from a store whose own source register was corrupted.  A `call`'s
      * pushed return address is exactly pc+size, so those are excluded (they
      * are the bulk of code-address stores and are not interesting). */
        if (sw_cs_hi) {
            value = sw_mem_value_u64(qemu_plugin_mem_get_value(info));
            if (insn_len && value == pc + insn_len) {
                /* a call's pushed return address: keep it for the trail */
                if (sw_callpush) {
                    sw_ring[sw_ring_head % SW_RING].pc = pc;
                    sw_ring[sw_ring_head % SW_RING].value = value;
                    sw_ring[sw_ring_head % SW_RING].vaddr = vaddr;
                    sw_ring[sw_ring_head % SW_RING].cpu = cpu;
                    sw_ring_head++;
                }
                pthread_mutex_unlock(&sw_mtx);
                return;
            }
            if (value >= sw_cs_lo && value < sw_cs_hi) {
                sw_cs_hits++;
                if (sw_cs_hits <= sw_cs_budget)
                    fprintf(stderr, "SLOTWATCH-CODESTORE cpu=%u pc=0x%" PRIx64
                            " vaddr=0x%" PRIx64 " value=0x%" PRIx64
                            " size=%" PRIu64 "\n", cpu, pc, vaddr, value, size);
                if (sw_cs_hits <= 3)
                    sw_ring_show("codestore");
            }
        }
        pthread_mutex_unlock(&sw_mtx);
        return;
    }
    value = sw_mem_value_u64(qemu_plugin_mem_get_value(info));
    sw_hits++;
    if (pc >= 0xFFFFFFFF80000000ULL)
        sw_kernel++;
    else
        sw_user++;
    if (vaddr != sw_slot)
        sw_via_frame++;
    if (sw_hits <= 3)
        sw_ring_show("slot");
    if (sw_hits <= (uint64_t)sw_budget) {
        fprintf(stderr, "SLOTWATCH-WRITE cpu=%u pc=0x%" PRIx64
                " vaddr=0x%" PRIx64 " phys=0x%" PRIx64
                " value=0x%" PRIx64 " size=%" PRIu64 " via=%s src=%s\n",
                cpu, pc, vaddr, phys, value, size,
                vaddr == sw_slot ? "slot" : "frame",
                pc >= 0xFFFFFFFF80000000ULL ? "kernel" : "user");
    } else {
        sw_suppressed++;
    }
    pthread_mutex_unlock(&sw_mtx);
}

static void sw_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    size_t i;

    for (i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint64_t iva = qemu_plugin_insn_vaddr(insn);

        if (!sw_in_range(iva))
            continue;
        sw_insns++;
        if (sw_insns_used >= (1 << 16))
            continue;                   /* table full: reported by the summary */
        sw_insns_tbl[sw_insns_used].pc = iva;
        sw_insns_tbl[sw_insns_used].size = qemu_plugin_insn_size(insn);
        qemu_plugin_register_vcpu_mem_cb(insn, sw_mem_cb,
                                         QEMU_PLUGIN_CB_NO_REGS,
                                         QEMU_PLUGIN_MEM_W,
                                         &sw_insns_tbl[sw_insns_used++]);
    }
}

static void sw_atexit(qemu_plugin_id_t id, void *ud)
{
    pthread_mutex_lock(&sw_mtx);
    fprintf(stderr, "SLOTWATCH-SUMMARY slot=0x%" PRIx64
            " insns=%" PRIu64 " stores=%" PRIu64 " hits=%" PRIu64
            " kernel=%" PRIu64 " user=%" PRIu64 " via_frame=%" PRIu64
            " suppressed=%" PRIu64 " codestores=%" PRIu64
            " frame=0x%" PRIx64 " phys=0x%" PRIx64 ":0x%" PRIx64
            " phys_armed=%s armed=yes stores_observed=%s"
            " target_hits=%" PRIu64
            " measured=%s\n",
            sw_slot, sw_insns, sw_stores, sw_hits, sw_kernel, sw_user,
            sw_via_frame, sw_suppressed, sw_cs_hits, sw_frame,
            sw_phys_lo, sw_phys_hi, sw_have_physlo ? "yes" : "no",
            sw_stores ? "yes" : "no", sw_hits,
            sw_hits ? "yes" : "NO-MEASUREMENT");
    pthread_mutex_unlock(&sw_mtx);
}

static bool sw_parse_u64(const char *text, uint64_t *value)
{
    char *end = NULL;

    if (!text[0])
        return false;
    *value = g_ascii_strtoull(text, &end, 0);
    return end && end != text && *end == '\0';
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    int i;

    for (i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "slot=", 5)) {
            sw_slot = strtoull(argv[i] + 5, NULL, 0);
        } else if (!strncmp(argv[i], "code=", 5)) {
            char *arg = argv[i] + 5;
            char *colon = strchr(arg, ':');

            if (!colon || sw_nranges >= SW_MAX_RANGES) {
                fprintf(stderr, "SLOTWATCH-ERROR bad code= range '%s'\n", arg);
                return -1;
            }
            *colon = 0;
            sw_ranges[sw_nranges].lo = strtoull(arg, NULL, 0);
            sw_ranges[sw_nranges].hi = strtoull(colon + 1, NULL, 0);
            if (sw_ranges[sw_nranges].hi <= sw_ranges[sw_nranges].lo) {
                fprintf(stderr, "SLOTWATCH-ERROR empty code= range '%s'\n",
                        argv[i]);
                return -1;
            }
            sw_nranges++;
            if (sw_ranges[sw_nranges - 1].lo >= 0xFFFFFFFF80000000ULL)
                sw_need_phys = true;
        } else if (!strncmp(argv[i], "budget=", 7)) {
            sw_budget = atoi(argv[i] + 7);
        } else if (!strncmp(argv[i], "codestore=", 10)) {
            char *arg = argv[i] + 10;
            char *colon = strchr(arg, ':');

            if (!colon) {
                fprintf(stderr, "SLOTWATCH-ERROR bad codestore= '%s'\n", arg);
                return -1;
            }
            *colon = 0;
            sw_cs_lo = strtoull(arg, NULL, 0);
            sw_cs_hi = strtoull(colon + 1, NULL, 0);
        } else if (!strncmp(argv[i], "callpush=", 9)) {
            sw_callpush = atoi(argv[i] + 9) != 0;
 /* frame=PHYS / frameoff=OFF set the watched PHYSICAL byte directly, so a
  * KERNEL writer that reaches it through its per-CPU copy window (a
  * different VA, the same frame - nothing ever stores the VA itself) is
  * caught instead of waiting for a learn that never comes. */
        } else if (!strncmp(argv[i], "frame=", 6)) {
            if (!sw_parse_u64(argv[i] + 6, &sw_frame)) {
                fprintf(stderr, "SLOTWATCH-ERROR bad frame= '%s'\n",
                        argv[i]);
                return -1;
            }
            sw_frame &= ~0xFFFULL;
            sw_have_frame = true;
            sw_need_phys = true;
        } else if (!strncmp(argv[i], "frameoff=", 9)) {
            if (!sw_parse_u64(argv[i] + 9, &sw_slot_off) ||
                sw_slot_off > 0xFFFULL) {
                fprintf(stderr, "SLOTWATCH-ERROR bad frameoff= '%s'\n",
                        argv[i]);
                return -1;
            }
            sw_have_frameoff = true;
            sw_need_phys = true;
 /* frameany=1 watches EVERY offset of the frame - the shape a stray copy
  * into a page has (its offset is wherever the copy started). */
        } else if (!strncmp(argv[i], "frameany=", 9)) {
            sw_frame_any = atoi(argv[i] + 9) != 0;
            sw_need_phys = true;
 /* physlo=/physhi= watch a PHYSICAL RANGE - the shape that catches any
  * kernel copy-window store into a region (e.g. a process's image block)
  * without knowing which frame each of its pages got this boot. */
        } else if (!strncmp(argv[i], "physlo=", 7)) {
            if (!sw_parse_u64(argv[i] + 7, &sw_phys_lo)) {
                fprintf(stderr, "SLOTWATCH-ERROR bad physlo= '%s'\n",
                        argv[i]);
                return -1;
            }
            sw_have_physlo = true;
            sw_need_phys = true;
        } else if (!strncmp(argv[i], "physhi=", 7)) {
            if (!sw_parse_u64(argv[i] + 7, &sw_phys_hi)) {
                fprintf(stderr, "SLOTWATCH-ERROR bad physhi= '%s'\n",
                        argv[i]);
                return -1;
            }
            sw_have_physhi = true;
            sw_need_phys = true;
        } else {
            fprintf(stderr, "SLOTWATCH-ERROR unknown argument '%s'\n", argv[i]);
            return -1;
        }
    }
    if (!sw_slot) {
        fprintf(stderr, "SLOTWATCH-ERROR slot=VA is required\n");
        return -1;
    }
    if (sw_have_frameoff && !sw_have_frame) {
        fprintf(stderr, "SLOTWATCH-ERROR frameoff= requires frame=\n");
        return -1;
    }
    if (sw_frame_any && !sw_have_frame) {
        fprintf(stderr, "SLOTWATCH-ERROR frameany=1 requires frame=\n");
        return -1;
    }
    if (sw_frame_any && sw_have_frameoff) {
        fprintf(stderr, "SLOTWATCH-ERROR frameany=1 conflicts with "
                        "frameoff=\n");
        return -1;
    }
    if (sw_have_physlo != sw_have_physhi) {
        fprintf(stderr, "SLOTWATCH-ERROR physlo= and physhi= must be "
                        "given together\n");
        return -1;
    }
    if (sw_have_physlo && sw_phys_hi <= sw_phys_lo) {
        fprintf(stderr, "SLOTWATCH-ERROR empty physical range "
                        "0x%" PRIx64 ":0x%" PRIx64 "\n",
                sw_phys_lo, sw_phys_hi);
        return -1;
    }
    sw_slot_off = sw_slot & 0xFFFULL;
    fprintf(stderr, "SLOTWATCH-ARM slot=0x%" PRIx64 " off=0x%" PRIx64
            " ranges=%d budget=%d phys_check=%s\n", sw_slot, sw_slot_off,
            sw_nranges, sw_budget, sw_need_phys ? "yes" : "no");
    for (i = 0; i < sw_nranges; i++)
        fprintf(stderr, "SLOTWATCH-ARM code=0x%" PRIx64 ":0x%" PRIx64 "\n",
                sw_ranges[i].lo, sw_ranges[i].hi);
    qemu_plugin_register_vcpu_tb_trans_cb(id, sw_tb_trans);
    qemu_plugin_register_atexit_cb(id, sw_atexit, NULL);
    return 0;
}
