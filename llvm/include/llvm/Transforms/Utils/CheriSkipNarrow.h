//===- CheriSkipNarrow.h - Skip per-access narrowing proven unnecessary ---===//
//
// LLM-generated research prototype (local branch only; not for upstream).
//
// Front ends (rustc, and potentially Clang/Fil-C) can request per-access
// capability narrowing by emitting llvm.cheri.cap.bounds.set[.exact] calls
// tagged !cheri.access_narrow. They can also state target-neutral facts:
//
//   !mem.alloc_inbounds !{}   on an instruction producing or narrowing a
//       pointer P: every access through P (and through inbounds GEPs of P)
//       stays inside the allocation that P's operand is based on, AND the
//       operand's capability/fat pointer is already bounded to (at most) that
//       allocation. Proven by the front end's type system (e.g. Rust &T/&[T]
//       with a retained software check), not by llvm.assume.
//   "mem.alloc_inbounds"      string attribute on a pointer argument: the
//       argument itself satisfies the above (e.g. Rust &T / &mut T / Box<T>).
//   !mem.checked !{}          on an access-narrow call: its (base, len)
//       operands are exactly the base and length of a dominating software
//       bounds check guarding the accesses through the result. Kept for future
//       intra-object policy; never implied by a bare llvm.assume.
//
// CheriSkipNarrowPass removes access-narrow calls that are !mem.checked (a
// retained software check guards the access, so the narrow is redundant with it)
// AND whose base is alloc_inbounds (call metadata, or base = inbounds-GEP chain of
// an alloc_inbounds argument). A narrow without !mem.checked may be the sole
// bounds check (rustc `elide`) and is never removed. Matching calls are removed,
// replacing the result by the base pointer. Allocation-level bounds (calls
// without !cheri.access_narrow) are never touched. Missing/dropped metadata
// means "keep the narrow" (fail-safe). Disable with -cheri-skip-narrow=false.
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
} // namespace llvm

#endif
