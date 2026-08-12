/* SPDX-License-Identifier: BSD-2-Clause */

/*
 * Called from TCG-generated code before the direct RAM access whenever
 * the fast-path TLB gate (CPUTLBDescFast.instr_table) resolved a
 * non-NULL instrumented MemoryRegion.  Dispatches to the region hook;
 * no BQL is held.
 *
 * Note: intentionally no include guard; QEMU includes helper headers
 * once per macro context (prototypes, TCGHelperInfo, gen helpers).
 */
DEF_HELPER_FLAGS_7(mem_instrument, TCG_CALL_NO_RWG, void,
                   ptr, i32, i64, i32, i32, i32, i32)
