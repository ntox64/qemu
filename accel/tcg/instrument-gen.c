/* SPDX-License-Identifier: BSD-2-Clause */

#include "qemu/osdep.h"
#include "qemu/bitops.h"
#include "exec/instrument-gen.h"

bool tcg_has_instrumented_ram;

#ifdef CONFIG_SOFTMMU
#include "tcg/tcg.h"
#include "tcg/tcg-temp-internal.h"
#include "tcg/tcg-op-common.h"
#include "exec/cpu-common.h"
#include "exec/target_page.h"
#include "exec/tlb-common.h"

#define HELPER_H "accel/tcg/mem-instrument.h"
#include "exec/helper-gen.h.inc"
#undef HELPER_H

/*
 * Emit the hook call for one marked data access.
 *
 * The TLB index math mirrors the softmmu fast path in the backends:
 *   index = (addr >> (TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS)) & mask
 *   then   >> CPU_TLB_ENTRY_BITS  (element index, sizeof(entry) == 1<<5)
 *   then   << log2(sizeof(void *)) (byte offset into instr_table)
 */
static void gen_instrument_hook(TCGv_i64 addr, unsigned size,
                                bool is_write, int mmu_idx)
{
    uintptr_t ofs = offsetof(CPUNegativeOffsetState, tlb.f[mmu_idx]) -
                    sizeof(CPUNegativeOffsetState);
    TCGv_ptr base, ent, mr;
    TCGv_i32 set, mmu_c;

    base = tcg_temp_ebb_new_ptr();
    ent = tcg_temp_ebb_new_ptr();
    mr = tcg_temp_ebb_new_ptr();
    set = tcg_temp_ebb_new_i32();
    mmu_c = tcg_constant_i32(mmu_idx);

#if TCG_TARGET_REG_BITS == 64
    {
        TCGv_i64 idx = tcg_temp_ebb_new_i64();
        TCGv_i64 mask = tcg_temp_ebb_new_i64();
        TCGv_i64 ent_off = tcg_temp_ebb_new_i64();
        TCGv_i32 lo = tcg_temp_ebb_new_i32();

        tcg_gen_shri_i64(idx, addr, TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS);
        tcg_gen_ld_i64(mask, tcg_env, ofs + offsetof(CPUTLBDescFast, mask));
        tcg_gen_and_i64(idx, idx, mask);
        tcg_gen_shri_i64(idx, idx, CPU_TLB_ENTRY_BITS);
        tcg_gen_extrl_i64_i32(set, idx);
        tcg_gen_shli_i64(ent_off, idx, ctz64(sizeof(void *)));
        tcg_gen_extrl_i64_i32(lo, ent_off);
        tcg_gen_ext_i32_ptr(ent, lo);

        tcg_temp_free_i32(lo);
        tcg_temp_free_i64(ent_off);
        tcg_temp_free_i64(idx);
        tcg_temp_free_i64(mask);
    }
#else
    {
        TCGv_i32 idx = tcg_temp_ebb_new_i32();
        TCGv_i32 mask = tcg_temp_ebb_new_i32();
        TCGv_i32 ent_off = tcg_temp_ebb_new_i32();

        tcg_gen_extrl_i64_i32(idx, addr);
        tcg_gen_shri_i32(idx, idx, TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS);
        tcg_gen_ld_i32(mask, tcg_env, ofs + offsetof(CPUTLBDescFast, mask));
        tcg_gen_and_i32(idx, idx, mask);
        tcg_gen_shri_i32(idx, idx, CPU_TLB_ENTRY_BITS);
        tcg_gen_mov_i32(set, idx);
        tcg_gen_shli_i32(ent_off, idx, ctz32(sizeof(void *)));
        tcg_gen_ext_i32_ptr(ent, ent_off);

        tcg_temp_free_i32(ent_off);
        tcg_temp_free_i32(idx);
        tcg_temp_free_i32(mask);
    }
#endif

    tcg_gen_ld_ptr(base, tcg_env, ofs + offsetof(CPUTLBDescFast, instr_table));
    tcg_gen_add_ptr(ent, base, ent);
    tcg_gen_ld_ptr(mr, ent, 0);

    {
        TCGv_i32 cpu_index = tcg_temp_ebb_new_i32();
        TCGv_i32 size_c = tcg_constant_i32(size);
        TCGv_i32 write_c = tcg_constant_i32(is_write);

        tcg_gen_ld_i32(cpu_index, tcg_env,
                       offsetof(CPUState, cpu_index) - sizeof(CPUState));
        gen_helper_mem_instrument(mr, cpu_index, addr, size_c, write_c,
                                  set, mmu_c);
        tcg_temp_free_i32(cpu_index);
    }

    tcg_temp_free_i32(set);
    tcg_temp_free_ptr(base);
    tcg_temp_free_ptr(ent);
    tcg_temp_free_ptr(mr);
}

void tcg_gen_inject_instrument_hooks(void)
{
    TCGOp *op, *next;
    bool emit = tcg_has_instrumented_ram;

    if (!emit) {
        return;
    }

    /*
     * While injecting we cannot reuse any freed EBB temps that might
     * still be referenced by marker ops; keep the plugin-gen discipline.
     */
    tcg_temp_ebb_reset_freed(tcg_ctx);

    QTAILQ_FOREACH_SAFE(op, &tcg_ctx->ops, link, next) {
        if (op->opc != INDEX_op_insn_mem_hook) {
            continue;
        }
        {
            TCGv_i64 addr = temp_tcgv_i64(arg_temp(op->args[0]));
            unsigned size = op->args[1];
            bool is_write = op->args[2];
            int mmu_idx = op->args[3];

            if (emit) {
                tcg_ctx->emit_before_op = op;
                gen_instrument_hook(addr, size, is_write, mmu_idx);
                tcg_ctx->emit_before_op = NULL;
            }
            tcg_op_remove(tcg_ctx, op);
        }
    }
}
#endif /* CONFIG_SOFTMMU */
