//===- MemAnnot.cpp - Memory-safety annotation vocabulary (M5r) -----------===//
// [LLM-generated]
#include "llvm/IR/MemAnnot.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/ErrorHandling.h"

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

// [LLM-generated] M5r R16: one loan copy. A packed id uses bits 42..62.
// Those bits are never 0 after a remap (0 would alias an unrekeyed rustc id).
// If every non-zero value is already live, the copy is (orig, disambiguator).
// If that space is exhausted too, compilation stops. Reusing disambiguator 1
// would clear a different copy.
memannot::LoanRef memannot::allocateLoanCopy(uint64_t Orig, uint64_t OldHigh, uint64_t Salt,
                                  function_ref<bool(uint64_t)> PackedTaken,
                                  function_ref<bool(uint64_t)> DisambigTaken,
                                  unsigned HighBits, uint64_t DisambigLimit) {
  unsigned Bits = HighBits;
  if (Bits == 0 || Bits > LoanHighBits)
    Bits = LoanHighBits;
  uint64_t HighMask = (uint64_t(1) << Bits) - 1;
  uint64_t Low = Orig & LoanKeyMask;
  uint64_t Prefer = (OldHigh ^ (Salt & HighMask)) & HighMask;
  auto TryH = [&](uint64_t H, LoanRef &Out) {
    if (H == 0 || H > HighMask)
      return false;
    uint64_t Packed = Low | (H << 42);
    if (PackedTaken(Packed))
      return false;
    Out = LoanRef{Low, Packed, 0};
    return true;
  };
  LoanRef R;
  if (TryH(Prefer, R))
    return R;
  for (uint64_t H = 1; H <= HighMask; ++H) {
    if (H == Prefer)
      continue;
    if (TryH(H, R))
      return R;
  }
  auto GiveUp = [&]() -> LoanRef {
    reportFatalUsageError("mem-inline-loan: no free copy id for census key " +
                          Twine(Low));
  };
  if (DisambigLimit != 0) {
    for (uint64_t D = 1; D <= DisambigLimit; ++D)
      if (!DisambigTaken(D))
        return LoanRef{Low, 0, D};
    return GiveUp();
  }
  uint64_t D = 1;
  while (D && DisambigTaken(D))
    ++D;
  if (D == 0)
    return GiveUp();
  return LoanRef{Low, 0, D};
}

static bool constInt64(const Metadata *M, uint64_t &Out) {
  auto *C = mdconst::dyn_extract_or_null<ConstantInt>(M);
  if (!C || C->getBitWidth() != 64)
    return false;
  Out = C->getZExtValue();
  return true;
}

bool memannot::decodeLoanRef(const Metadata *M, LoanRef &R) {
  uint64_t V = 0;
  if (constInt64(M, V)) {
    R = LoanRef{V & LoanKeyMask, V, 0};
    return true;
  }
  // A !{i64, i64} node is a multi-loan list, not one extended copy. The
  // extended operand is tagged so the two shapes cannot be swapped.
  auto *N = dyn_cast<MDNode>(M);
  if (!N || N->getNumOperands() != 3)
    return false;
  auto *Tag = dyn_cast<MDString>(N->getOperand(0));
  if (!Tag || Tag->getString() != LoanExtTag)
    return false;
  uint64_t Orig = 0, D = 0;
  if (!constInt64(N->getOperand(1).get(), Orig) ||
      !constInt64(N->getOperand(2).get(), D) || D == 0)
    return false;
  R = LoanRef{Orig & LoanKeyMask, 0, D};
  return true;
}

void memannot::appendLoanRefs(const MDNode *N, SmallVectorImpl<LoanRef> &Out) {
  if (!N)
    return;
  for (const MDOperand &Op : N->operands()) {
    LoanRef R;
    if (decodeLoanRef(Op.get(), R))
      Out.push_back(R);
  }
}

void memannot::appendBundleLoanRefs(const CallBase &CB,
                                    SmallVectorImpl<LoanRef> &Out) {
  if (auto OB = CB.getOperandBundle(LastUseMD))
    for (Value *V : OB->Inputs)
      if (auto *C = dyn_cast<ConstantInt>(V))
        if (C->getBitWidth() == 64) {
          uint64_t Id = C->getZExtValue();
          Out.push_back(LoanRef{Id & LoanKeyMask, Id, 0});
        }
  if (auto OB = CB.getOperandBundle(LastUseExt)) {
    auto In = OB->Inputs;
    for (unsigned I = 0; I + 1 < In.size(); I += 2) {
      auto *A = dyn_cast<ConstantInt>(In[I]);
      auto *B = dyn_cast<ConstantInt>(In[I + 1]);
      if (!A || !B || A->getBitWidth() != 64 || B->getBitWidth() != 64)
        continue;
      uint64_t D = B->getZExtValue();
      if (!D)
        continue;
      Out.push_back(LoanRef{A->getZExtValue() & LoanKeyMask, 0, D});
    }
  }
}

Metadata *memannot::encodeLoanRef(LLVMContext &Ctx, const LoanRef &R) {
  Type *I64 = Type::getInt64Ty(Ctx);
  if (R.extended())
    return MDNode::get(
        Ctx, {MDString::get(Ctx, LoanExtTag),
              ConstantAsMetadata::get(ConstantInt::get(I64, R.Orig)),
              ConstantAsMetadata::get(ConstantInt::get(I64, R.Disambig))});
  return ConstantAsMetadata::get(ConstantInt::get(I64, R.Packed));
}

void memannot::insertLastUseAnchors(Instruction &InsertBefore, const MDNode *LU) {
  SmallVector<LoanRef, 4> Refs;
  appendLoanRefs(LU, Refs);
  Module *M = InsertBefore.getModule();
  if (Refs.empty() || !M)
    return;
  LLVMContext &Ctx = InsertBefore.getContext();
  Type *I64 = Type::getInt64Ty(Ctx);
  SmallVector<Value *, 4> Packed, Ext;
  for (const LoanRef &R : Refs) {
    if (R.extended()) {
      Ext.push_back(ConstantInt::get(I64, R.Orig));
      Ext.push_back(ConstantInt::get(I64, R.Disambig));
    } else
      Packed.push_back(ConstantInt::get(I64, R.Packed));
  }
  Function *Fact = Intrinsic::getOrInsertDeclaration(M, Intrinsic::mem_fact);
  auto Emit = [&](StringRef Tag, ArrayRef<Value *> Ids) {
    if (Ids.empty())
      return;
    OperandBundleDef OB(Tag.str(), std::vector<Value *>(Ids.begin(), Ids.end()));
    CallInst::Create(Fact, {}, {OB}, "", InsertBefore.getIterator());
  };
  Emit(LastUseMD, Packed);
  Emit(LastUseExt, Ext);
}
