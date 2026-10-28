//===- CheriSkipNarrow.h - Skip per-access narrowing proven unnecessary ---===//
//
// LLM-generated research prototype (local branch only; not for upstream).
//
// Front ends (rustc; Clang via MemAnnotateC) can request per-access capability
// narrowing by emitting llvm.cheri.cap.bounds.set[.exact] calls tagged
// !cheri.access_narrow. They state target-neutral facts with:
//
//   "mem.alloc_inbounds"      string attribute on a pointer argument: the
//       pointer is in bounds of its allocation and its capability / fat
//       pointer is bounded to (at most) that allocation; accesses through
//       inbounds GEPs of it that a retained check guards stay inside it.
//       (Rust &T / &mut T / Box<T> / &[T]; C `MEM_ALLOC_INBOUNDS` params.)
//   !mem.alloc_inbounds !{}   on an instruction: the same fact for the
//       pointer operand it narrows / produces.
//   "mem.checked"(ptr B, iN L)  operand bundle on an access-narrow call: a
//       software bounds check that the front end retains guarantees that
//       every access through the call's result lies in [B, B+L) bytes. B and
//       L are SSA values, so a non-CHERI consumer (e.g. a Fil-C-style
//       checker) can use the bound directly. Never implied by llvm.assume.
//   !mem.checked !{}          operand-less form: on a GEP (rustc raw-checked
//       slices, where the bound is the slice metadata and no narrow exists),
//       and left by this pass on kept narrows after it strips the bundle.
//
// CheriSkipNarrowPass removes an access-narrow call iff it carries a
// "mem.checked"(B, L) bundle consistent with the call (B == base operand,
// L == length operand) AND its base is alloc_inbounds (call metadata, or an
// inbounds-GEP chain to an alloc_inbounds argument). The result is replaced
// by the base pointer. A narrow without the bundle may be the sole bounds
// check (rustc `elide`) and is never removed. Allocation-level bounds (no
// !cheri.access_narrow) are never touched. Missing/dropped facts keep the
// narrow (fail-safe). Kept narrows get the bundle stripped (unknown bundles
// make a call conservatively read memory) and !mem.checked !{} added.
//
// Policy: skipping is the default (allocation-level threat model). The
// stronger mode -cheri-skip-narrow=false keeps every narrow (A/B, and
// intra-allocation Spectre protection for narrowed accesses).
//
// Intended placement: PipelineStart, before GVN/LICM drop unknown metadata.
//
//===----------------------------------------------------------------------===//
#ifndef LLVM_TRANSFORMS_UTILS_CHERISKIPNARROW_H
#define LLVM_TRANSFORMS_UTILS_CHERISKIPNARROW_H

#include "llvm/IR/PassManager.h"

namespace llvm {
struct CheriSkipNarrowPass : PassInfoMixin<CheriSkipNarrowPass> {
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
  static bool isRequired() { return true; }
};

/// Lowers C-level annotation conventions (mem_annot.h) to the IR annotations
/// above: `__mem_checked_narrow(base, len)` calls become a tagged
/// llvm.cheri.cap.bounds.set with a "mem.checked"(base, len) bundle on CHERI
/// (pointer in a non-zero address space) or the identity elsewhere, and
/// llvm.var.annotation(..., "mem.alloc_inbounds") on a parameter's spill slot
/// becomes the "mem.alloc_inbounds" parameter attribute.
struct MemAnnotateCPass : PassInfoMixin<MemAnnotateCPass> {
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
  static bool isRequired() { return true; }
};
} // namespace llvm

#endif
