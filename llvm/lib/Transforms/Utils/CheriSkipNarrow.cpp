//===- CheriSkipNarrow.cpp - Skip per-access narrowing proven unnecessary -===//
//
// LLM-generated research prototype (local branch only; not for upstream).
// See CheriSkipNarrow.h for the annotation contract.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Utils/CheriSkipNarrow.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/Argument.h"
#include "llvm/IR/ConstantRange.h"
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
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/ModRef.h"

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

//===----------------------------------------------------------------------===//
// M3.1: C header mirror of the Rust type contracts (mem_contract.h).
//===----------------------------------------------------------------------===//

STATISTIC(NumContracts, "C mem.contract annotations lowered");

static cl::opt<bool> ContractSpatialOnly(
    "mem-contract-spatial-only", cl::init(false), cl::Hidden,
    cl::desc("Lower only the spatial (CHERI-enforceable) part of each "
             "mem.contract; drop the trusted facts (noundef, noalias, "
             "readonly, captures, mem.box_family)"));

namespace {
enum class CKind { Slice, SliceMut, Ref, RefMut, Box, CStr, Keep, RetBorrows };

struct Contract {
  CKind Kind;
  SmallVector<uint64_t, 4> Args; // as written in C (1-based, 0 = return)
};

std::optional<CKind> parseKind(StringRef S) {
  return StringSwitch<std::optional<CKind>>(S)
      .Case("slice", CKind::Slice)
      .Case("slice_mut", CKind::SliceMut)
      .Case("ref", CKind::Ref)
      .Case("ref_mut", CKind::RefMut)
      .Case("box", CKind::Box)
      .Case("cstr", CKind::CStr)
      .Case("keep", CKind::Keep)
      .Case("ret_borrows", CKind::RetBorrows)
      .Default(std::nullopt);
}

const char *kindName(CKind K) {
  switch (K) {
  case CKind::Slice: return "slice";
  case CKind::SliceMut: return "slice_mut";
  case CKind::Ref: return "ref";
  case CKind::RefMut: return "ref_mut";
  case CKind::Box: return "box";
  case CKind::CStr: return "cstr";
  case CKind::Keep: return "keep";
  case CKind::RetBorrows: return "ret_borrows";
  }
  llvm_unreachable("kind");
}

unsigned expectedArgs(CKind K) {
  switch (K) {
  case CKind::Slice:
  case CKind::SliceMut: return 4; // ip, ilen, size, align
  case CKind::Ref:
  case CKind::RefMut:
  case CKind::Box: return 3; // ip, size, align
  case CKind::CStr:
  case CKind::Keep:
  case CKind::RetBorrows: return 1; // ip
  }
  llvm_unreachable("kind");
}

std::optional<StringRef> annotString(Value *V) {
  auto *GV = dyn_cast<GlobalVariable>(V->stripPointerCasts());
  if (!GV || !GV->hasInitializer())
    return std::nullopt;
  auto *CDA = dyn_cast<ConstantDataArray>(GV->getInitializer());
  if (!CDA || !CDA->isCString())
    return std::nullopt;
  return CDA->getAsCString();
}

// Adds attribute A at LLVM attribute index Idx (ReturnIndex or a param).
void addAt(Function &F, unsigned ArgNoOrRet, bool IsRet, Attribute A) {
  if (IsRet)
    F.addRetAttr(A);
  else
    F.addParamAttr(ArgNoOrRet, A);
}
} // namespace

PreservedAnalyses MemContractCPass::run(Module &M, ModuleAnalysisManager &) {
  GlobalVariable *GA = M.getGlobalVariable("llvm.global.annotations");
  if (!GA || !GA->hasInitializer())
    return PreservedAnalyses::all();
  auto *Arr = dyn_cast<ConstantArray>(GA->getInitializer());
  if (!Arr)
    return PreservedAnalyses::all();
  LLVMContext &Ctx = M.getContext();

  MapVector<Function *, SmallVector<Contract, 4>> PerFn;
  SmallVector<Constant *, 8> Kept;
  for (Use &U : Arr->operands()) {
    auto *E = cast<Constant>(U.get());
    auto *CS = dyn_cast<ConstantStruct>(E);
    std::optional<StringRef> Str =
        CS && CS->getNumOperands() >= 5 ? annotString(CS->getOperand(1))
                                        : std::nullopt;
    if (!Str || !Str->starts_with("mem.contract.")) {
      Kept.push_back(E);
      continue;
    }
    auto *F = dyn_cast<Function>(CS->getOperand(0)->stripPointerCasts());
    std::optional<CKind> K = parseKind(Str->drop_front(strlen("mem.contract.")));
    if (!F || !K) {
      Ctx.emitError("mem.contract: unknown contract '" + *Str + "'");
      continue;
    }
    Contract C{*K, {}};
    if (auto *AG = dyn_cast<GlobalVariable>(
            CS->getOperand(4)->stripPointerCasts()))
      if (Constant *AI = AG->getInitializer()) {
        // An all-zero args struct (e.g. RS_RET_CSTR's {i32 0}) folds to
        // zeroinitializer, so read elements generically.
        unsigned N = 0;
        if (auto *ST = dyn_cast<StructType>(AI->getType()))
          N = ST->getNumElements();
        for (unsigned I = 0; I < N; ++I)
          if (auto *CI = dyn_cast_or_null<ConstantInt>(
                  AI->getAggregateElement(I)))
            C.Args.push_back(CI->getZExtValue());
      }
    if (C.Args.size() != expectedArgs(*K)) {
      Ctx.emitError("mem.contract." + Twine(kindName(*K)) + " on " +
                    F->getName() + ": expected " + Twine(expectedArgs(*K)) +
                    " integer arguments");
      continue;
    }
    PerFn[F].push_back(std::move(C));
  }
  if (PerFn.empty())
    return PreservedAnalyses::all();

  bool Trusted = !ContractSpatialOnly;
  for (auto &KV : PerFn) {
    Function *F = KV.first;
    auto &Cs = KV.second;
    FunctionType *FT = F->getFunctionType();
    SmallSet<unsigned, 4> KeepSet, RetBorrowSet;
    for (const Contract &C : Cs) {
      if (C.Kind == CKind::Keep)
        KeepSet.insert(C.Args[0]);
      if (C.Kind == CKind::RetBorrows)
        RetBorrowSet.insert(C.Args[0]);
    }
    std::string Canon;
    auto badIdx = [&](const Twine &Why) {
      Ctx.emitError("mem.contract on " + F->getName() + ": " + Why);
    };
    for (const Contract &C : Cs) {
      uint64_t Ip = C.Args[0];
      bool IsRet = Ip == 0;
      unsigned ArgNo = IsRet ? 0 : Ip - 1;
      Type *PT = IsRet ? FT->getReturnType()
                       : (ArgNo < FT->getNumParams() ? FT->getParamType(ArgNo)
                                                     : nullptr);
      if (!PT || !PT->isPointerTy()) {
        badIdx(Twine(kindName(C.Kind)) + " index " + Twine(Ip) +
               " is not a pointer parameter/return");
        continue;
      }
      if (!Canon.empty())
        Canon += ";";
      Canon += kindName(C.Kind);
      Canon += "(";
      Canon += IsRet ? std::string("ret") : std::to_string(ArgNo);
      if (C.Kind == CKind::Keep || C.Kind == CKind::RetBorrows) {
        Canon += ")";
        continue; // modifiers: consumed by the captures rule below
      }
      ++NumContracts;
      bool IsSlice = C.Kind == CKind::Slice || C.Kind == CKind::SliceMut;
      bool IsMut = C.Kind == CKind::SliceMut || C.Kind == CKind::RefMut;
      uint64_t Size = 0, Align = 1;
      std::optional<unsigned> LenNo;
      if (IsSlice) {
        uint64_t Il = C.Args[1];
        if (Il == 0 || Il - 1 >= FT->getNumParams() ||
            !FT->getParamType(Il - 1)->isIntegerTy()) {
          badIdx("slice length index " + Twine(Il) +
                 " is not an integer parameter");
          continue;
        }
        LenNo = Il - 1;
        Size = C.Args[2];
        Align = C.Args[3];
        Canon += "," + std::to_string(*LenNo);
      } else if (C.Kind != CKind::CStr) {
        Size = C.Args[1];
        Align = C.Args[2];
      }
      if (C.Kind != CKind::CStr)
        Canon += "," + std::to_string(Size) + "," + std::to_string(Align);
      Canon += ")";

      // Spatial part: what CHERI can establish and enforce (narrow-once).
      addAt(*F, ArgNo, IsRet, Attribute::get(Ctx, "mem.alloc_inbounds"));
      addAt(*F, ArgNo, IsRet, Attribute::get(Ctx, Attribute::NonNull));
      if (Align > 1 && isPowerOf2_64(Align))
        addAt(*F, ArgNo, IsRet,
              Attribute::getWithAlignment(Ctx, llvm::Align(Align)));
      // Box: no dereferenceable (the callee may free it; rustc omits it too).
      // Returns: none either; rustc ties dereferenceable to nofree, which is
      // not valid on returns (M3.2: the Rust declaration is the reference).
      if (!IsSlice && C.Kind != CKind::CStr && C.Kind != CKind::Box &&
          !IsRet && Size > 0)
        addAt(*F, ArgNo, IsRet,
              Attribute::getWithDereferenceableBytes(Ctx, Size));
      if (C.Kind == CKind::CStr)
        addAt(*F, ArgNo, IsRet, Attribute::get(Ctx, "mem.cstr"));
      if (IsSlice) {
        addAt(*F, ArgNo, IsRet,
              Attribute::get(Ctx, "mem.range",
                             std::to_string(*LenNo) + ":" +
                                 std::to_string(Size)));
        // len * size <= isize::MAX, as Rust's slice length range.
        unsigned W = FT->getParamType(*LenNo)->getIntegerBitWidth();
        if (Size > 0 && W >= 2 &&
            !F->getAttributes().hasParamAttr(*LenNo, Attribute::Range)) {
          APInt Max = APInt::getSignedMaxValue(W).udiv(APInt(W, Size)) + 1;
          F->addParamAttr(*LenNo, Attribute::get(Ctx, Attribute::Range,
                                                 ConstantRange(APInt(W, 0),
                                                               Max)));
        }
      }
      if (!Trusted)
        continue;

      // Trusted part: Rust's type-system facts; the caller must establish
      // them (C) or the type checker does (Rust). CHERI cannot check them.
      addAt(*F, ArgNo, IsRet, Attribute::get(Ctx, Attribute::NoUndef));
      if (LenNo)
        F->addParamAttr(*LenNo, Attribute::get(Ctx, Attribute::NoUndef));
      if (IsRet) {
        if (C.Kind == CKind::Box)
          F->addRetAttr(Attribute::get(Ctx, "mem.box_family", "__rust_alloc"));
        continue; // no noalias/captures claims on returns
      }
      bool Shared = !IsMut && C.Kind != CKind::Box;
      F->addParamAttr(ArgNo, Attribute::get(Ctx, Attribute::NoAlias));
      if (Shared)
        F->addParamAttr(ArgNo, Attribute::get(Ctx, Attribute::ReadOnly));
      // A borrow cannot be freed by the callee (rustc's nofree on &T/&mut T);
      // a Box can.
      if (C.Kind != CKind::Box)
        F->addParamAttr(ArgNo, Attribute::get(Ctx, Attribute::NoFree));
      if (C.Kind == CKind::Box) {
        // Ownership moves to the callee: no captures claim.
        F->addParamAttr(ArgNo,
                        Attribute::get(Ctx, "mem.box_family", "__rust_alloc"));
      } else if (KeepSet.contains(Ip)) {
        // 'static / retained: no lifetime claim. A shared frozen borrow is
        // still read-only through any copy (rustc's &T fact).
        if (Shared)
          F->addParamAttr(
              ArgNo, Attribute::getWithCaptureInfo(
                         Ctx, CaptureInfo(CaptureComponents::Address |
                                          CaptureComponents::ReadProvenance)));
      } else if (RetBorrowSet.contains(Ip)) {
        // Tied to the return: only the address escapes otherwise (as rustc).
        F->addParamAttr(ArgNo, Attribute::getWithCaptureInfo(
                                   Ctx, CaptureInfo(CaptureComponents::Address,
                                                    CaptureComponents::Address |
                                                        CaptureComponents::Provenance)));
      } else {
        // Borrow for the call only: the lifetime ends with the call, so the
        // provenance cannot escape; the address may (a Rust callee may store
        // `p as usize`). M3.2: matches rustc's lifetime-derived claim.
        F->addParamAttr(ArgNo, Attribute::getWithCaptureInfo(
                                   Ctx, CaptureInfo(CaptureComponents::Address)));
      }
    }
    F->addFnAttr("mem.contract", Canon);
  }

  // Drop the consumed annotation entries (and the array if now empty).
  SmallSetVector<GlobalVariable *, 8> MaybeDead;
  for (Use &U : Arr->operands())
    if (auto *CS = dyn_cast<ConstantStruct>(U.get()))
      for (unsigned I : {1u, 2u, 4u})
        if (I < CS->getNumOperands())
          if (auto *G = dyn_cast<GlobalVariable>(
                  CS->getOperand(I)->stripPointerCasts()))
            MaybeDead.insert(G);
  if (Kept.empty()) {
    GA->eraseFromParent();
  } else {
    auto *NewTy = ArrayType::get(Arr->getType()->getElementType(), Kept.size());
    auto *NewGA = new GlobalVariable(M, NewTy, GA->isConstant(),
                                     GA->getLinkage(),
                                     ConstantArray::get(NewTy, Kept), "",
                                     GA, GA->getThreadLocalMode(),
                                     GA->getAddressSpace());
    NewGA->setSection(GA->getSection());
    NewGA->takeName(GA);
    GA->eraseFromParent();
  }
  for (GlobalVariable *G : MaybeDead) {
    G->removeDeadConstantUsers();
    if (G->use_empty() && G->getSection() == "llvm.metadata" &&
        G->hasLocalLinkage())
      G->eraseFromParent();
  }
  return PreservedAnalyses::none();
}
