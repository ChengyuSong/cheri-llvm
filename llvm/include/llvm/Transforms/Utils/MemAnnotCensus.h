//===- MemAnnotCensus.h - M5r annotation census and late stub ---*- C++ -*-===//
// [LLM-generated] CHERI M5r R0/R1.
//
// MemAnnotCensusPass<start>: counts llvm.mem.fact facts, llvm.mem.claim
//   calls, "mem.check" / "mem.free" bundles and !mem.guard / !mem.last_use
//   hints, tags each fact/claim/check/free with !mem.annot.id and records it
//   (with a weak handle on its block; claims also with a callback handle that
//   sees a RAUW) for the late census.
// MemAnnotCensusPass<late>: counts again and reports, per kind, survivors and
//   losses classified as block-deleted, unreachable-block, dropped (renamed
//   "mem.dropped" by a promote/SROA drop) or unexplained. With
//   -mem-annot-census-strict an unexplained loss of a check, claim or free is
//   a fatal error; a claim replaced by a non-claim value (folded into its
//   operand) is unexplained, a claim deleted while unused is "dead".
//   !mem.guard / !mem.last_use losses are always allowed (fail-safe).
// CheriBoundsLoweringPass: the R0 stub of the late CHERI pass. It runs the
//   late census, then strips every annotation (facts, claims -> operand,
//   "mem." bundles, !mem.guard, !mem.last_use, !mem.annot.id) so instruction
//   selection sees the same IR as without annotations. No CHERI decisions.
//===----------------------------------------------------------------------===//
#ifndef LLVM_TRANSFORMS_UTILS_MEMANNOTCENSUS_H
#define LLVM_TRANSFORMS_UTILS_MEMANNOTCENSUS_H

#include "llvm/IR/PassManager.h"
#include "llvm/Support/Compiler.h"

namespace llvm {
class Module;
class Function;
class Instruction;

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
/// True while a start census is pending for \p M (D14: InstCombine keeps
/// "mem.dropped" placeholders only then).
LLVM_ABI bool censusActive(const Module &M);
/// A pass erased fact \p I as redundant (implied by the allocation or by an
/// identical earlier fact); the census classifies it as "redundant".
LLVM_ABI void noteRedundantFact(const Instruction &I);
/// -mem-annot-census-per-pass: attribute annotation count changes to passes.
LLVM_ABI bool censusPerPass();
/// Number of annotation kinds counted by countAnnotations.
inline constexpr unsigned NumCensusKinds = 8;
/// Count annotations in \p F (check, guard, claim, alloc_inbounds, inbounds,
/// free, last_use, dropped), adding to \p Out.
LLVM_ABI void countAnnotations(const Function &F, unsigned *Out);
/// Record that pass \p Pass changed the counts of \p M by Before -> After.
LLVM_ABI void notePassDelta(const Module *M, StringRef Pass,
                            const unsigned *Before, const unsigned *After);
} // namespace memannot
} // namespace llvm
#endif
