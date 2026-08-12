/* SPDX-License-Identifier: BSD-2-Clause */

#ifndef EXEC_INSTRUMENT_GEN_H
#define EXEC_INSTRUMENT_GEN_H

/*
 * Set (machine realize time) when any MemoryRegion has instrumented RAM
 * enabled.  TCG translation uses it to decide whether to emit the
 * insn_mem_hook marker for data loads/stores; it is never set in
 * user-mode or KVM-only builds.
 */
extern bool tcg_has_instrumented_ram;

/*
 * Replace every insn_mem_hook marker in the current TB's op stream with
 * an inline, TLB-gated call to the region hook, emitted before the
 * qemu_ld/st op (plugin-gen style).  No-op when no instrumented region
 * exists.
 */
void tcg_gen_inject_instrument_hooks(void);

#endif /* EXEC_INSTRUMENT_GEN_H */
