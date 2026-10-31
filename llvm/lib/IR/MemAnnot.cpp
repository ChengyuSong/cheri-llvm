//===- MemAnnot.cpp - Memory-safety annotation vocabulary (M5r) -----------===//
// [LLM-generated]
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Function.h"
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
