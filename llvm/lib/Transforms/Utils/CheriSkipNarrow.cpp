//===- CheriSkipNarrow.cpp - Skip per-access narrowing proven unnecessary -===//
//
// LLM-generated research prototype (local branch only; not for upstream).
// See CheriSkipNarrow.h for the annotation contract.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Utils/CheriSkipNarrow.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/Argument.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "cheri-skip-narrow"

STATISTIC(NumAccessNarrow, "Access-narrow calls seen");
STATISTIC(NumSkipped, "Access-narrow calls removed (alloc_inbounds)");
STATISTIC(NumKept, "Access-narrow calls kept (no proof)");

static cl::opt<bool>
    EnableSkipNarrow("cheri-skip-narrow", cl::init(true), cl::Hidden,
                     cl::desc("Remove !cheri.access_narrow capability "
                              "narrowing proven unnecessary by "
                              "!mem.alloc_inbounds (A/B: =false)"));

static bool isAllocInboundsBase(const Value *V) {
  // Propagate through inbounds GEPs (and pointer casts) to the root.
  for (unsigned Depth = 0; Depth < 16; ++Depth) {
    if (const auto *A = dyn_cast<Argument>(V))
      return A->getParent()->getAttributes().hasParamAttr(
          A->getArgNo(), "mem.alloc_inbounds");
    if (const auto *I = dyn_cast<Instruction>(V))
      if (I->getMetadata("mem.alloc_inbounds"))
        return true;
    if (const auto *GEP = dyn_cast<GEPOperator>(V)) {
      if (!GEP->isInBounds())
        return false;
      V = GEP->getPointerOperand();
      continue;
    }
    return false;
  }
  return false;
}

PreservedAnalyses CheriSkipNarrowPass::run(Function &F,
                                           FunctionAnalysisManager &) {
  SmallVector<IntrinsicInst *, 8> ToRemove;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB) {
      auto *II = dyn_cast<IntrinsicInst>(&I);
      if (!II)
        continue;
      Intrinsic::ID ID = II->getIntrinsicID();
      if (ID != Intrinsic::cheri_cap_bounds_set &&
          ID != Intrinsic::cheri_cap_bounds_set_exact)
        continue;
      if (!II->getMetadata("cheri.access_narrow"))
        continue; // allocation-level or user bounds: never touched
      ++NumAccessNarrow;
      // Only a narrow that duplicates a retained software check (!mem.checked) is
      // redundant. A narrow without it may be the sole check (e.g. rustc's
      // `elide` mode removed the software check): never skip it.
      bool Proven = II->getMetadata("mem.checked") &&
                    (II->getMetadata("mem.alloc_inbounds") ||
                     isAllocInboundsBase(II->getArgOperand(0)));
      if (EnableSkipNarrow && Proven)
        ToRemove.push_back(II);
      else
        ++NumKept;
    }
  for (IntrinsicInst *II : ToRemove) {
    LLVM_DEBUG(dbgs() << "cheri-skip-narrow: removing " << *II << "\n");
    II->replaceAllUsesWith(II->getArgOperand(0));
    II->eraseFromParent();
    ++NumSkipped;
  }
  if (ToRemove.empty())
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
