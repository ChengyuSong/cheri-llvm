//===- MemAnnotCensus.h - M5r annotation census and late stub ---*- C++ -*-===//
// [LLM-generated] CHERI M5r R0.
//
// MemAnnotCensusPass<start>: counts llvm.mem.fact facts, "mem.check" bundles
//   and !mem.guard hints, tags each fact/check with !mem.annot.id and records
//   it (with a weak handle on its block) for the late census.
// MemAnnotCensusPass<late>: counts again and reports, per kind, survivors and
//   losses classified as block-deleted, unreachable-block, dropped (renamed
//   "mem.dropped" by a promote/SROA drop) or unexplained. With
//   -mem-annot-census-strict an unexplained loss of a check, claim or free is
//   a fatal error. !mem.guard losses are always allowed (fail-safe).
// CheriBoundsLoweringPass: the R0 stub of the late CHERI pass. It runs the
//   late census, then strips every annotation (facts, "mem." bundles,
//   !mem.guard, !mem.annot.id) so instruction selection sees the same IR as
//   without annotations. No CHERI decisions are made in R0.
//===----------------------------------------------------------------------===//
#ifndef LLVM_TRANSFORMS_UTILS_MEMANNOTCENSUS_H
#define LLVM_TRANSFORMS_UTILS_MEMANNOTCENSUS_H

#include "llvm/IR/PassManager.h"
#include "llvm/Support/Compiler.h"

namespace llvm {
class Module;

struct MemAnnotCensusPass : PassInfoMixin<MemAnnotCensusPass> {
  bool Late;
  explicit MemAnnotCensusPass(bool Late = false) : Late(Late) {}
  LLVM_ABI PreservedAnalyses run(Module &M, ModuleAnalysisManager &AM);
  static bool isRequired() { return true; }
};

struct CheriBoundsLoweringPass : PassInfoMixin<CheriBoundsLoweringPass> {
  LLVM_ABI PreservedAnalyses run(Module &M, ModuleAnalysisManager &AM);
  static bool isRequired() { return true; }
};

namespace memannot {
/// Start census (adds !mem.annot.id). Returns true if the module changed.
LLVM_ABI bool runCensusStart(Module &M);
/// Late census report; aborts in strict mode on unexplained loss.
LLVM_ABI void runCensusLate(Module &M);
/// Remove all annotations. Returns true if the module changed.
LLVM_ABI bool stripAnnotations(Module &M);
/// Late census + strip (the R0 CheriBoundsLowering body).
LLVM_ABI bool runCheriBoundsLoweringStub(Module &M);
/// Set by -mem-annot-census: add the start census at pipeline start.
LLVM_ABI bool censusAtPipelineStart();
} // namespace memannot
} // namespace llvm
#endif
