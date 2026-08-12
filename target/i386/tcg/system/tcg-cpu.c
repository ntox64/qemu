/*
 * i386 TCG cpu class initialization functions specific to system emulation
 *
 *  Copyright (c) 2003 Fabrice Bellard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "cpu.h"
#include "tcg/helper-tcg.h"
#include "hw/qdev-core.h"
#include "qapi/error.h"

#include "system/system.h"
#include "qemu/units.h"
#include "system/address-spaces.h"
#include "system/memory.h"

#include "tcg/tcg-cpu.h"

/*
 * Per-CPU RAM window base (low-4G hole on q35/pc); one 4 KiB page
 * per vCPU, selected by cpu_index.
 */
#define NTO64_PERCPU_RAM_BASE 0xDF000000u

static void tcg_cpu_machine_done(Notifier *n, void *unused)
{
    X86CPU *cpu = container_of(n, X86CPU, machine_done);
    MemoryRegion *smram =
        (MemoryRegion *) object_resolve_path("/machine/smram", NULL);

    if (smram) {
        cpu->smram = g_new(MemoryRegion, 1);
        memory_region_init_alias(cpu->smram, OBJECT(cpu), "smram",
                                 smram, 0, 4 * GiB);
        memory_region_set_enabled(cpu->smram, true);
        memory_region_add_subregion_overlap(cpu->cpu_as_root, 0,
                                            cpu->smram, 1);
    }
}

bool tcg_cpu_realizefn(CPUState *cs, Error **errp)
{
    X86CPU *cpu = X86_CPU(cs);

    /*
     * The realize order is important, since x86_cpu_realize() checks if
     * nothing else has been set by the user (or by accelerators) in
     * cpu->ucode_rev and cpu->phys_bits, and the memory regions
     * initialized here are needed for the vcpu initialization.
     *
     * realize order:
     * tcg_cpu -> host_cpu -> x86_cpu
     */
    cpu->cpu_as_mem = g_new(MemoryRegion, 1);
    cpu->cpu_as_root = g_new(MemoryRegion, 1);

    /* Outer container... */
    memory_region_init(cpu->cpu_as_root, OBJECT(cpu), "memory", ~0ull);
    memory_region_set_enabled(cpu->cpu_as_root, true);

    /*
     * ... with two regions inside: normal system memory with low
     * priority, and...
     */
    memory_region_init_alias(cpu->cpu_as_mem, OBJECT(cpu), "memory",
                             get_system_memory(), 0, ~0ull);
    memory_region_add_subregion_overlap(cpu->cpu_as_root, 0, cpu->cpu_as_mem, 0);
    memory_region_set_enabled(cpu->cpu_as_mem, true);

    /*
     * nto64-per-cpu-ram: give this vCPU its own address space whose
     * root is the full system memory plus a private per-CPU RAM page.
     * The per-CPU views union into the same real RAM; each CPU only
     * sees its own private window (testbed for per-CPU memory).
     */
    if (object_property_get_bool(OBJECT(qdev_get_machine()),
                                 "nto64-per-cpu-ram", NULL)) {
        MemoryRegion *cpu_ram_root = g_new(MemoryRegion, 1);
        MemoryRegion *cpu_ram_sysmem = g_new(MemoryRegion, 1);
        MemoryRegion *cpu_ram_priv = g_new(MemoryRegion, 1);
        char *priv_name = g_strdup_printf("cpu-ram-private-%d",
                                          cs->cpu_index);

        memory_region_init(cpu_ram_root, OBJECT(cpu), "cpu-ram", ~0ull);
        memory_region_init_alias(cpu_ram_sysmem, OBJECT(cpu),
                                 "cpu-ram-sysmem", get_system_memory(),
                                 0, ~0ull);
        memory_region_add_subregion(cpu_ram_root, 0, cpu_ram_sysmem);
        memory_region_init_ram(cpu_ram_priv, OBJECT(cpu),
                               priv_name, 0x1000, &error_abort);
        g_free(priv_name);
        memory_region_add_subregion_overlap(
            cpu_ram_root,
            NTO64_PERCPU_RAM_BASE + cs->cpu_index * 0x1000,
            cpu_ram_priv, 1);
        cs->memory = cpu_ram_root;
    }

    cs->num_ases = 2;
    cpu_address_space_init(cs, X86ASIdx_MEM, "cpu-memory", cs->memory);
    cpu_address_space_init(cs, X86ASIdx_SMM, "cpu-smm", cpu->cpu_as_root);

    /* ... SMRAM with higher priority, linked from /machine/smram.  */
    cpu->machine_done.notify = tcg_cpu_machine_done;
    qemu_add_machine_init_done_notifier(&cpu->machine_done);
    return true;
}
