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
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "cheri-skip-narrow"

STATISTIC(NumAccessNarrow, "Access-narrow calls seen");
STATISTIC(NumSkipped, "Access-narrow calls removed (checked + alloc_inbounds)");
STATISTIC(NumKept, "Access-narrow calls kept (no proof, or skipping disabled)");
STATISTIC(NumCLowered, "C __mem_checked_narrow calls lowered");
STATISTIC(NumCParams, "C mem.alloc_inbounds parameter annotations lowered");

static cl::opt<bool> EnableSkipNarrow(
    "cheri-skip-narrow", cl::init(true), cl::Hidden,
    cl::desc("Remove !cheri.access_narrow capability narrowing proven "
             "redundant by a \"mem.checked\" bundle and mem.alloc_inbounds "
             "(default on; =false is the stronger keep-all-narrows mode)"));

static const char *const CheckedTag = "mem.checked";

static bool isAllocInboundsBase(const Value *V) {
  // Propagate through inbounds GEPs to the root.
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

/// The "mem.checked"(B, L) bundle, if present and consistent with the narrow.
static bool hasConsistentChecked(const CallBase &CB) {
  auto B = CB.getOperandBundle(CheckedTag);
  if (!B || B->Inputs.size() != 2)
    return false;
  return B->Inputs[0].get() == CB.getArgOperand(0) &&
         B->Inputs[1].get() == CB.getArgOperand(1);
}

PreservedAnalyses CheriSkipNarrowPass::run(Function &F,
                                           FunctionAnalysisManager &) {
  SmallVector<IntrinsicInst *, 8> ToRemove, ToStrip;
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
      // Only a narrow that duplicates a retained software check is redundant.
      // A narrow without the bundle may be the sole check (rustc `elide`).
      bool Proven = hasConsistentChecked(*II) &&
                    (II->getMetadata("mem.alloc_inbounds") ||
                     isAllocInboundsBase(II->getArgOperand(0)));
      if (EnableSkipNarrow && Proven) {
        ToRemove.push_back(II);
      } else {
        ++NumKept;
        if (II->getOperandBundle(CheckedTag))
          ToStrip.push_back(II);
      }
    }
  for (IntrinsicInst *II : ToRemove) {
    LLVM_DEBUG(dbgs() << "cheri-skip-narrow: removing " << *II << "\n");
    II->replaceAllUsesWith(II->getArgOperand(0));
    II->eraseFromParent();
    ++NumSkipped;
  }
  if (!ToStrip.empty()) {
    LLVMContext &Ctx = F.getContext();
    uint32_t Tag = Ctx.getOrInsertBundleTag(CheckedTag)->getValue();
    for (IntrinsicInst *II : ToStrip) {
      CallBase *New = CallBase::removeOperandBundle(II, Tag, II->getIterator());
      New->copyMetadata(*II);
      New->setMetadata(CheckedTag, MDNode::get(Ctx, {}));
      New->takeName(II);
      II->replaceAllUsesWith(New);
      II->eraseFromParent();
    }
  }
  if (ToRemove.empty() && ToStrip.empty())
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}

/// The string a llvm.var.annotation call carries, if it is a constant global.
static StringRef annotationString(const CallBase &CB) {
  const Value *S = CB.getArgOperand(1)->stripPointerCasts();
  if (const auto *GV = dyn_cast<GlobalVariable>(S))
    if (GV->hasInitializer())
      if (const auto *CDA = dyn_cast<ConstantDataArray>(GV->getInitializer()))
        if (CDA->isCString())
          return CDA->getAsCString();
  return {};
}

PreservedAnalyses MemAnnotateCPass::run(Function &F,
                                        FunctionAnalysisManager &) {
  SmallVector<CallBase *, 8> Narrows;
  SmallVector<IntrinsicInst *, 4> Annots;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      if (auto *II = dyn_cast<IntrinsicInst>(CB)) {
        if (II->getIntrinsicID() == Intrinsic::var_annotation &&
            annotationString(*II) == "mem.alloc_inbounds")
          Annots.push_back(II);
        continue;
      }
      Function *Callee = CB->getCalledFunction();
      if (Callee && Callee->getName() == "__mem_checked_narrow" &&
          CB->arg_size() == 2 && CB->getType()->isPointerTy() &&
          CB->getArgOperand(0)->getType() == CB->getType() &&
          CB->getArgOperand(1)->getType()->isIntegerTy())
        Narrows.push_back(CB);
    }
  if (Narrows.empty() && Annots.empty())
    return PreservedAnalyses::all();

  // Parameter annotations: clang spills a parameter to an alloca and puts
  // llvm.var.annotation on the alloca. Move the fact to the argument.
  for (IntrinsicInst *II : Annots) {
    Value *Slot = II->getArgOperand(0)->stripPointerCasts();
    Argument *Arg = nullptr;
    for (User *U : Slot->users())
      if (auto *SI = dyn_cast<StoreInst>(U))
        if (SI->getPointerOperand() == Slot)
          if (auto *A = dyn_cast<Argument>(SI->getValueOperand())) {
            if (Arg && Arg != A) {
              Arg = nullptr; // ambiguous: drop the fact
              break;
            }
            Arg = A;
          }
    if (Arg && Arg->getType()->isPointerTy()) {
      F.addParamAttr(Arg->getArgNo(),
                     Attribute::get(F.getContext(), "mem.alloc_inbounds"));
      ++NumCParams;
    }
    II->eraseFromParent();
  }

  LLVMContext &Ctx = F.getContext();
  for (CallBase *CB : Narrows) {
    Value *Base = CB->getArgOperand(0);
    Value *Len = CB->getArgOperand(1);
    auto *PT = cast<PointerType>(Base->getType());
    Value *Repl = Base;
    if (PT->getAddressSpace() != 0) {
      // CHERI purecap: a capability narrow the retained C check makes
      // redundant when the base is alloc_inbounds.
      IRBuilder<> B(CB);
      Function *Decl = Intrinsic::getOrInsertDeclaration(
          F.getParent(), Intrinsic::cheri_cap_bounds_set, {Len->getType()});
      OperandBundleDef Bundle(CheckedTag, std::vector<Value *>{Base, Len});
      CallInst *N = B.CreateCall(Decl, {Base, Len}, {Bundle});
      N->setMetadata("cheri.access_narrow", MDNode::get(Ctx, {}));
      Repl = N;
    }
    // Elsewhere (e.g. a Fil-C-style or plain target) the narrow is the
    // identity; the C-level check stays in the source.
    CB->replaceAllUsesWith(Repl);
    CB->eraseFromParent();
    ++NumCLowered;
  }
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
