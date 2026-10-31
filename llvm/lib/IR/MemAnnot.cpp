//===- MemAnnot.cpp - Memory-safety annotation vocabulary (M5r) -----------===//
// [LLM-generated]
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"

using namespace llvm;

bool memannot::isMemFact(const Instruction *I) {
  if (auto *II = dyn_cast<IntrinsicInst>(I))
    return II->getIntrinsicID() == Intrinsic::mem_fact;
  return false;
}

bool memannot::hasMemCheck(const CallBase &CB) {
  return CB.getOperandBundle(TagCheck).has_value();
}

bool memannot::onlyMemBundles(const CallBase &CB) {
  for (unsigned I = 0, E = CB.getNumOperandBundles(); I != E; ++I)
    if (!isMemTag(CB.getOperandBundleAt(I).getTagName()))
      return false;
  return true;
}

bool memannot::isMemClaim(const Value *V) {
  if (auto *II = dyn_cast<IntrinsicInst>(V))
    return II->getIntrinsicID() == Intrinsic::mem_claim;
  return false;
}

bool memannot::isDeallocCall(const CallBase &CB) {
  if (CB.getFnAttr(Attribute::AllocKind).isValid() &&
      (CB.getFnAttr(Attribute::AllocKind).getAllocKind() & AllocFnKind::Free) !=
          AllocFnKind::Unknown)
    return true;
  if (const Function *F = CB.getCalledFunction()) {
    if (F->hasFnAttribute(Attribute::AllocKind) &&
        (F->getFnAttribute(Attribute::AllocKind).getAllocKind() &
         AllocFnKind::Free) != AllocFnKind::Unknown)
      return true;
    StringRef N = F->getName();
    return N == "free" || N == "c_free" || N == "__rust_dealloc" ||
           N == "__rdl_dealloc" || N == "__rg_dealloc";
  }
  return false;
}

// [LLM-generated] M5r R1.
bool memannot::isClaimObjectExact(const CallBase &Claim, const DataLayout &DL) {
  if (!isMemClaim(&Claim))
    return false;
  auto *N = dyn_cast<ConstantInt>(Claim.getArgOperand(1));
  if (!N)
    return false;
  const Value *P = Claim.getArgOperand(0);
  APInt Off(DL.getIndexTypeSizeInBits(P->getType()), 0);
  const Value *Base = P->stripAndAccumulateConstantOffsets(
      DL, Off, /*AllowNonInbounds=*/true);
  if (!Off.isZero())
    return false;
  std::optional<uint64_t> Size;
  if (auto *AI = dyn_cast<AllocaInst>(Base)) {
    if (auto TS = AI->getAllocationSize(DL); TS && !TS->isScalable())
      Size = TS->getFixedValue();
  } else if (auto *GV = dyn_cast<GlobalVariable>(Base)) {
    if (GV->hasDefinitiveInitializer())
      Size = DL.getTypeAllocSize(GV->getValueType()).getFixedValue();
  }
  return Size && *Size == N->getZExtValue();
}

// [LLM-generated] M5r R1.
bool memannot::isTriviallyAllocInbounds(const Value *V, const DataLayout &DL) {
  if (!V->getType()->isPointerTy())
    return false;
  APInt Off(DL.getIndexTypeSizeInBits(V->getType()), 0);
  const Value *Base =
      V->stripAndAccumulateConstantOffsets(DL, Off, /*AllowNonInbounds=*/false);
  std::optional<uint64_t> Size;
  if (auto *AI = dyn_cast<AllocaInst>(Base)) {
    if (auto TS = AI->getAllocationSize(DL); TS && !TS->isScalable())
      Size = TS->getFixedValue();
  } else if (auto *GV = dyn_cast<GlobalVariable>(Base)) {
    if (!GV->isDeclaration() || GV->getValueType()->isSized())
      Size = DL.getTypeAllocSize(GV->getValueType()).getFixedValue();
  }
  return Size && !Off.isNegative() && Off.ule(*Size);
}
