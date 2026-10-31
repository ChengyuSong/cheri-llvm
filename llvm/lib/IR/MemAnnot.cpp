//===- MemAnnot.cpp - Memory-safety annotation vocabulary (M5r) -----------===//
// [LLM-generated]
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/InstrTypes.h"
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
