/* SPDX-License-Identifier: GPL-2.0-or-later */

/*
 * Copyright (C) 2026, the nto64 project
 *
 * hbguard - a happens-before checker for lock-guarded kernel field sets.
 *
 * WHY THIS EXISTS.  An invariant of the shape "every access to this field
 * set happens under that lock, and no two vCPUs touch one of its words
 * without a lock-mediated edge between them" is not observable from inside
 * the guest: the window that breaks it is a few instructions wide, and a
 * debugger stops the world that contains it.  This plugin runs inside the
 * TCG translation path instead.  It hooks the memory accesses of the
 * instructions in a chosen code range, follows each lock word's stores to
 * see acquire/release, and reports the two shapes that break such an
 * invariant:
 *
 *   HBGUARD-UNGUARDED  a store to a watched field by a vCPU that does not
 *                      hold the field's lock at that moment
 *   HBGUARD-RACE       two accesses to one watched word from two vCPUs,
 *                      at least one a store, with no release of the
 *                      field's lock between them (no happens-before edge)
 *
 * It does not stop the guest, it is not limited to four addresses per vCPU
 * (hardware watchpoints are), it can watch several objects at once, and it
 * keys the synchronization edge on the kernel's own lock word rather than
 * on compiler instrumentation.
 *
 * THE PREDICATE.  This kernel's spinlock is a bare 32-bit word - 0 free,
 * 1 held - acquired so that the critical section is visible after the
 * acquire and released so that it is visible before the release.  So a
 * store of 1 by a vCPU that is not holding it is an acquire, a store of 0
 * by a vCPU that is holding it is a release, and every other store to the
 * lock word is counted and printed in the summary rather than guessed at.
 *
 * ADDRESSES ARE THE OBJECT HERE, SO THEY MUST BE STABLE.  Prefer a field
 * and a lock that live at fixed addresses (a static object in the kernel
 * image): both are then derived once from the kernel's own symbols, and
 * the same address denotes the same object in every boot of that build.
 * A heap object (a per-process record) is NOT armable this way - its
 * address is only known once the guest has run - and a remembered address
 * from an earlier boot would name whatever now lives there.  An
 * instrument that arms a fixed address must therefore report, per field,
 * whether it was accessed at all (see NO-MEASUREMENT below).
 *
 * USAGE (one plugin per run).  A value's own fields are separated by ':'
 * because the -plugin option splits its arguments on ',':
 *
 *   -plugin file=plugins/hbguard.so,\
 *           lock=kdup_lock:0xffffffff811db224,\
 *           lock=kflat_lock:0xffffffff811e2644,\
 *           field=kdup_used64:kdup_lock:0xffffffff811db220:0x4,\
 *           field=kflat_used64:kflat_lock:0xffffffff811e2640:0x4,\
 *           field=CONTROL.mono_ns:kdup_lock:0xffffffff813fb460:0x8,\
 *           code=0xffffffff80110000:0xffffffff80160000,\
 *           budget=8
 *
 *   lock=NAME:ADDR      a guarding lock word (4 bytes); up to 8
 *   field=NAME:LOCK:ADDR:LEN
 *                       a watched region; LEN <= 4096 bytes, up to 16
 *                       fields.  LOCK names one of the lock= arguments,
 *                       or is "-" for a field no lock guards (every store
 *                       to it is then UNGUARDED by definition - useful as
 *                       a negative control).  Regions must not overlap,
 *                       and two fields must not share an 8-byte word: a
 *                       word is tracked whole.
 *   code=LO:HI          only instrument instructions in [LO,HI).  The
 *                       kernel text range is the useful value: it keeps
 *                       the per-access cost off the user-space and device
 *                       paths without losing a kernel access.  Omit it to
 *                       instrument every instruction (slow; the summary
 *                       then reports the filter as "all").
 *   budget=N            printed violations per field before suppression
 *                       (default 8; the suppressed count is reported).
 *
 * OUTPUT (stderr, one line per event; the harness collects it):
 *
 *   HBGUARD-ARM ...            what was armed, before the guest runs
 *   HBGUARD-UNGUARDED field=.. cpu=.. pc=0x.. vaddr=0x.. value=0x..
 *                    lock=.. held_by=.. seq=..
 *   HBGUARD-RACE field=.. cpu=.. pc=0x.. vaddr=0x.. st=..
 *                other_cpu=.. other_pc=0x.. other_st=.. other_guarded=..
 *                lock=.. seq=..
 *   HBGUARD-LOCK name=.. addr=0x.. acq=.. rel=.. other=.. loads=..
 *   HBGUARD-FIELD name=.. lock=.. base=0x.. len=.. accesses=.. stores=..
 *                 guarded=.. unguarded=.. races=.. words=.. suppressed=..
 *                 measured=yes|NO-MEASUREMENT
 *
 * A field with zero accesses is reported as NO-MEASUREMENT and never as a
 * clean one: an instrument that cannot say what it measured is not a check.
 * A violation printed here is a candidate, not a verdict - the field's own
 * invariant decides whether the access it names belongs under the lock.
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

#define HB_MAX_LOCKS    8
#define HB_MAX_FIELDS   16
#define HB_MAX_VCPS     64
#define HB_MAX_WORDS    512             /* per field: LEN <= 512 * 8 bytes */
#define HB_WORD_SHIFT   3
#define HB_WORD_SZ      (1u << HB_WORD_SHIFT)
#define HB_NAME_LEN     48

typedef struct {
    char name[HB_NAME_LEN];
    uint64_t addr, end;
    uint64_t acq, rel, other, loads;
    uint64_t acq_cpu[HB_MAX_VCPS];      /* acquires per vCPU (who took it) */
    uint64_t last_edge;                 /* seq of this lock's last release */
    bool held[HB_MAX_VCPS];
} hb_lock_t;

typedef struct {
    uint64_t stamp;                     /* seq of the last access, 0 = never */
    uint64_t pc;
    unsigned cpu;
    bool store;
    bool guarded;
} hb_last_t;

typedef struct {
    char name[HB_NAME_LEN];
    char lock_name[HB_NAME_LEN];        /* resolved to `lock` at install */
    const hb_lock_t *lock;              /* NULL = no lock guards this field */
    uint64_t base, end;
    uint64_t accesses, stores, guarded, unguarded, races;
    uint64_t printed_u, printed_r, words_touched;
    uint64_t acc_cpu[HB_MAX_VCPS];      /* accesses per vCPU */
    hb_last_t words[HB_MAX_WORDS];
} hb_field_t;

static hb_lock_t hb_locks[HB_MAX_LOCKS];
static int hb_nlocks;
static hb_field_t hb_fields[HB_MAX_FIELDS];
static int hb_nfields;
static uint64_t hb_code_lo, hb_code_hi;
static uint64_t hb_budget = 8;

static pthread_mutex_t hb_mtx = PTHREAD_MUTEX_INITIALIZER;
static uint64_t hb_seq;
static unsigned hb_max_vcpus;

static uint64_t mem_value_u64(qemu_plugin_mem_value v)
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
    }
    return 0;
}

static const char *held_by_str(const hb_lock_t *lk)
{
    static char buf[HB_MAX_VCPS * 4 + 2];
    size_t off = 0;
    int i;

    buf[0] = '\0';
    if (!lk) {
        return "-";
    }
    for (i = 0; i < (int)hb_max_vcpus; i++) {
        if (lk->held[i]) {
            off += snprintf(buf + off, sizeof(buf) - off, off ? ",%d" : "%d",
                            i);
        }
    }
    return off ? buf : "-";
}

static bool field_guarded(const hb_field_t *f, unsigned cpu)
{
    return f->lock && f->lock->held[cpu];
}

static void hb_report_unguarded(hb_field_t *f, unsigned cpu, uint64_t pc,
                                uint64_t vaddr, uint64_t value, uint64_t stamp)
{
    f->unguarded++;
    if (f->printed_u >= hb_budget) {
        return;
    }
    f->printed_u++;
    fprintf(stderr,
            "HBGUARD-UNGUARDED field=%s cpu=%u pc=0x%" PRIx64
            " vaddr=0x%" PRIx64 " value=0x%" PRIx64 " lock=%s held_by=%s"
            " seq=%" PRIu64 "\n",
            f->name, cpu, pc, vaddr, value,
            f->lock ? f->lock->name : "-", held_by_str(f->lock), stamp);
}

static void hb_report_race(hb_field_t *f, unsigned cpu, uint64_t pc,
                           uint64_t vaddr, bool store, const hb_last_t *other,
                           uint64_t stamp)
{
    f->races++;
    if (f->printed_r >= hb_budget) {
        return;
    }
    f->printed_r++;
    fprintf(stderr,
            "HBGUARD-RACE field=%s cpu=%u pc=0x%" PRIx64 " vaddr=0x%" PRIx64
            " st=%u other_cpu=%u other_pc=0x%" PRIx64 " other_st=%u"
            " other_guarded=%u lock=%s seq=%" PRIu64 "\n",
            f->name, cpu, pc, vaddr, store ? 1u : 0u, other->cpu, other->pc,
            other->store ? 1u : 0u, other->guarded ? 1u : 0u,
            f->lock ? f->lock->name : "-", stamp);
}

/*
 * A lock-word store: 1 while free is an acquire, 0 while held is a
 * release; anything else is counted, never guessed at.
 */
static void hb_lock_store(hb_lock_t *lk, unsigned cpu, uint64_t value)
{
    if (value == 1 && !lk->held[cpu]) {
        lk->held[cpu] = true;
        lk->acq++;
        lk->acq_cpu[cpu]++;
        hb_seq++;
    } else if (value == 0 && lk->held[cpu]) {
        lk->held[cpu] = false;
        lk->rel++;
        lk->last_edge = ++hb_seq;
    } else {
        lk->other++;
    }
}

static hb_lock_t *hb_lock_lookup(uint64_t vaddr)
{
    int i;

    for (i = 0; i < hb_nlocks; i++) {
        if (vaddr >= hb_locks[i].addr && vaddr < hb_locks[i].end) {
            return &hb_locks[i];
        }
    }
    return NULL;
}

static hb_field_t *hb_field_lookup(uint64_t vaddr)
{
    int i;

    for (i = 0; i < hb_nfields; i++) {
        if (vaddr >= hb_fields[i].base && vaddr < hb_fields[i].end) {
            return &hb_fields[i];
        }
    }
    return NULL;
}

static void hb_mem_cb(unsigned cpu, qemu_plugin_meminfo_t info, uint64_t vaddr,
                      void *ud)
{
    const uint64_t pc = (uint64_t)(uintptr_t)ud;
    const bool store = qemu_plugin_mem_is_store(info);
    const uint64_t size = 1ull << qemu_plugin_mem_size_shift(info);
    hb_lock_t *lk;
    hb_field_t *f;
    uint64_t value = 0;
    uint64_t first, last, wi;
    uint64_t stamp, edge;

    pthread_mutex_lock(&hb_mtx);

    lk = hb_lock_lookup(vaddr);
    if (lk) {
        if (store) {
            qemu_plugin_mem_value v = qemu_plugin_mem_get_value(info);

            hb_lock_store(lk, cpu, mem_value_u64(v));
        } else {
            lk->loads++;
        }
        pthread_mutex_unlock(&hb_mtx);
        return;
    }

    f = hb_field_lookup(vaddr);
    if (!f) {
        pthread_mutex_unlock(&hb_mtx);
        return;
    }
    if (store) {
        value = mem_value_u64(qemu_plugin_mem_get_value(info));
    }

    first = (vaddr - f->base) >> HB_WORD_SHIFT;
    last = ((vaddr + size - 1) - f->base) >> HB_WORD_SHIFT;
    if (last >= HB_MAX_WORDS) {
        last = HB_MAX_WORDS - 1;
    }

    f->accesses++;
    f->acc_cpu[cpu]++;
    if (store) {
        f->stores++;
    }
    stamp = f->words[first].stamp;
    edge = f->lock ? f->lock->last_edge : 0;

    /*
     * The pair check runs on the word the access starts in; "a release of
     * this field's lock happened after the other access" is exactly the
     * happens-before edge the lock's release ordering gives any later
     * access on any CPU.
     */
    if (stamp && f->words[first].cpu != cpu &&
        (f->words[first].store || store) && stamp > edge) {
        hb_report_race(f, cpu, pc, vaddr, store, &f->words[first], hb_seq);
    }

    for (wi = first; wi <= last; wi++) {
        hb_last_t *rec = &f->words[wi];
        if (!rec->stamp) {
            f->words_touched++;
        }
        rec->stamp = ++hb_seq;
        rec->cpu = cpu;
        rec->pc = pc;
        rec->store = store;
        rec->guarded = field_guarded(f, cpu);
    }

    if (field_guarded(f, cpu)) {
        f->guarded++;
    } else if (store) {
        hb_report_unguarded(f, cpu, pc, vaddr, value, hb_seq);
    }

    pthread_mutex_unlock(&hb_mtx);
}

static void hb_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    const uint64_t va = qemu_plugin_tb_vaddr(tb);
    const size_t n = qemu_plugin_tb_n_insns(tb);
    size_t i;

    if (hb_code_hi) {
        if (va >= hb_code_hi) {
            return;
        }
        /*
         * 15 bytes is the longest x86 instruction; a TB that ends before
         * the range cannot hold an instruction inside it.
         */
        if (va + n * 15 + 16 <= hb_code_lo) {
            return;
        }
    }

    for (i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        const uint64_t iva = qemu_plugin_insn_vaddr(insn);

        if (hb_code_hi && (iva < hb_code_lo || iva >= hb_code_hi)) {
            continue;
        }
        qemu_plugin_register_vcpu_mem_cb(insn, hb_mem_cb,
                                         QEMU_PLUGIN_CB_NO_REGS,
                                         QEMU_PLUGIN_MEM_RW,
                                         (void *)(uintptr_t)iva);
    }
}

static void hb_atexit(qemu_plugin_id_t id, void *ud)
{
    char cpuinfo[HB_MAX_VCPS * 24 + 1];
    int i, c;

    pthread_mutex_lock(&hb_mtx);
    fprintf(stderr, "HBGUARD-SUMMARY locks=%d fields=%d code=", hb_nlocks,
            hb_nfields);
    if (hb_code_hi) {
        fprintf(stderr, "[0x%" PRIx64 ",0x%" PRIx64 ")",
                hb_code_lo, hb_code_hi);
    } else {
        fprintf(stderr, "all");
    }
    fprintf(stderr, " budget=%" PRIu64 "\n", hb_budget);
    for (i = 0; i < hb_nlocks; i++) {
        const hb_lock_t *lk = &hb_locks[i];
        size_t off = 0;

        cpuinfo[0] = '\0';
        for (c = 0; c < (int)hb_max_vcpus; c++) {
            if (lk->acq_cpu[c]) {
                off += snprintf(cpuinfo + off, sizeof(cpuinfo) - off,
                                off ? ",%d:%" PRIu64 : "%d:%" PRIu64, c,
                                lk->acq_cpu[c]);
            }
        }
        fprintf(stderr,
                "HBGUARD-LOCK name=%s addr=0x%" PRIx64
                " acq=%" PRIu64 " rel=%" PRIu64 " other=%" PRIu64
                " loads=%" PRIu64 " acq_by=%s held_now=%s\n",
                lk->name, lk->addr, lk->acq, lk->rel, lk->other, lk->loads,
                off ? cpuinfo : "-", held_by_str(lk));
    }
    for (i = 0; i < hb_nfields; i++) {
        const hb_field_t *f = &hb_fields[i];
        size_t off = 0;

        cpuinfo[0] = '\0';
        for (c = 0; c < (int)hb_max_vcpus; c++) {
            if (f->acc_cpu[c]) {
                off += snprintf(cpuinfo + off, sizeof(cpuinfo) - off,
                                off ? ",%d:%" PRIu64 : "%d:%" PRIu64, c,
                                f->acc_cpu[c]);
            }
        }
        fprintf(stderr,
                "HBGUARD-FIELD name=%s lock=%s base=0x%" PRIx64
                " len=0x%" PRIx64 " accesses=%" PRIu64 " stores=%" PRIu64
                " guarded=%" PRIu64 " unguarded=%" PRIu64 " races=%" PRIu64
                " words=%" PRIu64 " acc_by=%s suppressed=%" PRIu64
                " measured=%s\n",
                f->name, f->lock ? f->lock->name : "-", f->base,
                f->end - f->base, f->accesses, f->stores, f->guarded,
                f->unguarded, f->races, f->words_touched,
                off ? cpuinfo : "-",
                (f->unguarded - f->printed_u) + (f->races - f->printed_r),
                f->accesses ? "yes" : "NO-MEASUREMENT");
    }
    pthread_mutex_unlock(&hb_mtx);
}

static bool parse_u64(const char *s, uint64_t *out)
{
    char *end = NULL;
    uint64_t v = g_ascii_strtoull(s, &end, 0);

    if (!s[0] || !end || *end || end == s) {
        return false;
    }
    *out = v;
    return true;
}

static int parse_lock(const char *arg)
{
    char *copy = strdup(arg);
    char *name = strtok(copy, ":");
    char *addr = strtok(NULL, ":");
    hb_lock_t *lk;
    uint64_t a;
    int rc = -1;

    if (hb_nlocks >= HB_MAX_LOCKS) {
        fprintf(stderr, "hbguard: more than %d locks\n", HB_MAX_LOCKS);
        free(copy);
        return -1;
    }
    if (name && addr && !strtok(NULL, ":") && strlen(name) < HB_NAME_LEN &&
        parse_u64(addr, &a)) {
        if (!a) {
            /*
             * A zero address is never a lock: it would silently disarm the
             * check and every store to the field would read UNGUARDED.
             */
            fprintf(stderr, "hbguard: lock %s has address 0\n", name);
            free(copy);
            return -1;
        }
        lk = &hb_locks[hb_nlocks];
        memset(lk, 0, sizeof(*lk));
        snprintf(lk->name, sizeof(lk->name), "%s", name);
        lk->addr = a;
        lk->end = lk->addr + 4;
        hb_nlocks++;
        rc = 0;
    }
    free(copy);
    return rc;
}

static int parse_field(const char *arg)
{
    char *copy = strdup(arg);
    char *name = strtok(copy, ":");
    char *lock = strtok(NULL, ":");
    char *addr = strtok(NULL, ":");
    char *len = strtok(NULL, ":");
    hb_field_t *f;
    uint64_t base, size;
    int rc = -1;

    if (hb_nfields >= HB_MAX_FIELDS) {
        fprintf(stderr, "hbguard: more than %d fields\n", HB_MAX_FIELDS);
        free(copy);
        return -1;
    }
    if (name && lock && addr && len && !strtok(NULL, ":") &&
        strlen(name) < HB_NAME_LEN && parse_u64(addr, &base) &&
        parse_u64(len, &size) && size && size <= HB_MAX_WORDS * HB_WORD_SZ) {
        if (!base) {
            fprintf(stderr, "hbguard: field %s has address 0\n", name);
            free(copy);
            return -1;
        }
        f = &hb_fields[hb_nfields];
        memset(f, 0, sizeof(*f));
        snprintf(f->name, sizeof(f->name), "%s", name);
        snprintf(f->lock_name, sizeof(f->lock_name), "%s", lock);
        f->base = base;
        f->end = base + size;
        hb_nfields++;
        rc = 0;
    }
    free(copy);
    return rc;
}

/*
 * Resolve each field's lock by name (any order in the command line) and
 * refuse a configuration that could not answer the question it asks.
 */
static int hb_resolve(void)
{
    int i, j;

    for (i = 0; i < hb_nfields; i++) {
        hb_field_t *f = &hb_fields[i];

        if (!strcmp(f->lock_name, "-")) {
            f->lock = NULL;
            continue;
        }
        for (j = 0; j < hb_nlocks; j++) {
            if (!strcmp(f->lock_name, hb_locks[j].name)) {
                f->lock = &hb_locks[j];
                break;
            }
        }
        if (!f->lock) {
            fprintf(stderr, "hbguard: field %s names unknown lock %s\n",
                    f->name, f->lock_name);
            return -1;
        }
    }
    for (i = 0; i < hb_nfields; i++) {
        for (j = i + 1; j < hb_nfields; j++) {
            const hb_field_t *a = &hb_fields[i], *b = &hb_fields[j];

            if (a->base < b->end && b->base < a->end) {
                fprintf(stderr, "hbguard: fields %s and %s overlap\n",
                        a->name, b->name);
                return -1;
            }
            if ((a->base >> HB_WORD_SHIFT) == (b->base >> HB_WORD_SHIFT) ||
                ((a->end - 1) >> HB_WORD_SHIFT) ==
                ((b->end - 1) >> HB_WORD_SHIFT)) {
                fprintf(stderr,
                        "hbguard: fields %s and %s share an 8-byte word\n",
                        a->name, b->name);
                return -1;
            }
        }
    }
    return 0;
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    int i;

    hb_max_vcpus = info->system.max_vcpus;
    for (i = 0; i < argc; i++) {
        if (!strncmp(argv[i], "lock=", 5)) {
            if (parse_lock(argv[i] + 5)) {
                fprintf(stderr, "hbguard: bad lock argument: %s\n", argv[i]);
                return -1;
            }
        } else if (!strncmp(argv[i], "field=", 6)) {
            if (parse_field(argv[i] + 6)) {
                fprintf(stderr, "hbguard: bad field argument: %s\n",
                        argv[i]);
                return -1;
            }
        } else if (!strncmp(argv[i], "code=", 5)) {
            char *copy = strdup(argv[i] + 5);
            char *lo = strtok(copy, ":");
            char *hi = strtok(NULL, ":");
            bool ok = lo && hi && !strtok(NULL, ":") &&
                      parse_u64(lo, &hb_code_lo) && parse_u64(hi, &hb_code_hi);
            free(copy);
            if (!ok || hb_code_hi <= hb_code_lo) {
                fprintf(stderr, "hbguard: bad code argument: %s\n", argv[i]);
                return -1;
            }
        } else if (!strncmp(argv[i], "budget=", 7)) {
            if (!parse_u64(argv[i] + 7, &hb_budget)) {
                fprintf(stderr, "hbguard: bad budget argument: %s\n",
                        argv[i]);
                return -1;
            }
        } else {
            fprintf(stderr, "hbguard: unknown argument: %s\n", argv[i]);
            return -1;
        }
    }

    if (!hb_nlocks || !hb_nfields) {
        fprintf(stderr,
                "hbguard: needs at least one lock=<name:addr> and one"
                " field=<name:lock:addr:len>\n");
        return -1;
    }
    if (hb_max_vcpus > HB_MAX_VCPS) {
        fprintf(stderr, "hbguard: %u vCPUs exceeds the %d this supports\n",
                hb_max_vcpus, HB_MAX_VCPS);
        return -1;
    }
    if (hb_resolve()) {
        return -1;
    }

    fprintf(stderr, "HBGUARD-ARM code=");
    if (hb_code_hi) {
        fprintf(stderr, "[0x%" PRIx64 ",0x%" PRIx64 ")",
                hb_code_lo, hb_code_hi);
    } else {
        fprintf(stderr, "all");
    }
    fprintf(stderr, " vcpus=%u budget=%" PRIu64 "\n", hb_max_vcpus, hb_budget);
    for (i = 0; i < hb_nlocks; i++) {
        fprintf(stderr, "HBGUARD-ARM lock=%s addr=0x%" PRIx64 "\n",
                hb_locks[i].name, hb_locks[i].addr);
    }
    for (i = 0; i < hb_nfields; i++) {
        fprintf(stderr, "HBGUARD-ARM field=%s lock=%s base=0x%" PRIx64
                " len=0x%" PRIx64 "\n", hb_fields[i].name,
                hb_fields[i].lock ? hb_fields[i].lock->name : "-",
                hb_fields[i].base,
                hb_fields[i].end - hb_fields[i].base);
    }

    qemu_plugin_register_vcpu_tb_trans_cb(id, hb_tb_trans);
    qemu_plugin_register_atexit_cb(id, hb_atexit, NULL);
    return 0;
}
