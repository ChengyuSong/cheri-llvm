//===- CheriInvalidate.cpp - M5r R4 Track B prototype -------------------===//
// [LLM-generated] CHERI M5r R4 (Track B, RELAYER-DESIGN.md section 7).
//
// Precise invalidation of the capability copies a function keeps in its own
// frame, decided late from the events rustc and the generic passes carry:
//   * llvm.lifetime.end(A): null A's own capability slots; clear the tag of
//     any other live frame capability slot whose base lies inside A;
//   * "mem.free"(p) on a deallocation call: after the call, clear the tag of
//     any live frame capability slot whose base lies inside p's bounds.
// Only capabilities into dead storage are touched (fail-safe; no defined
// behaviour changes). Off by default: -cheri-invalidate=none|scope|free|all.
//===----------------------------------------------------------------------===//
#include "llvm/Transforms/Utils/MemAnnotCensus.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/CaptureTracking.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<std::string> InvalidateOpt(
    "cheri-invalidate", cl::init("none"), cl::Hidden,
    cl::desc("M5r R4 Track B prototype: none, scope, free, all"));
static cl::opt<bool> InvFilter(
    "cheri-invalidate-filter", cl::init(true), cl::Hidden,
    cl::desc("Only range-check a slot whose stored capabilities may point "
             "into the dead object (underlying-object provenance)"));
static cl::opt<std::string> InvStatsOut(
    "cheri-invalidate-stats-out", cl::init(""), cl::Hidden,
    cl::desc("Append one line of per-module invalidation counts"));

namespace {
struct Slot {
  AllocaInst *A;
  int64_t Off;
};

struct Inv {
  Module &M;
  const DataLayout &DL;
  bool Scope, Free;
  unsigned ScopeEvents = 0, FreeEvents = 0, OwnNulled = 0, RangeChecks = 0,
           Slots = 0, LUFrameCopies = 0, LUCarriers = 0, Filtered = 0;
  // Provenance of the capabilities stored into each slot (R4 filter):
  // the identified underlying objects, and whether any origin is unknown.
  struct Prov {
    SmallPtrSet<const Value *, 4> Objs;
    bool Unknown = false;
  };
  DenseMap<std::pair<AllocaInst *, int64_t>, Prov> SlotProv;
  Inv(Module &M, bool Scope, bool Free)
      : M(M), DL(M.getDataLayout()), Scope(Scope), Free(Free) {}

  Function *decl(Intrinsic::ID ID, ArrayRef<Type *> Tys = {}) {
    return Intrinsic::getOrInsertDeclaration(&M, ID, Tys);
  }

  // Frame capability slots: (alloca, constant offset) written by a
  // capability-typed store.
  void collectSlots(Function &F, MapVector<AllocaInst *, SmallVector<int64_t, 2>> &Out) {
    for (Instruction &I : instructions(F)) {
      auto *SI = dyn_cast<StoreInst>(&I);
      if (!SI || !DL.isFatPointer(SI->getValueOperand()->getType()))
        continue;
      int64_t Off = 0;
      Value *Base = GetPointerBaseWithConstantOffset(SI->getPointerOperand(), Off, DL);
      auto *A = dyn_cast_or_null<AllocaInst>(Base);
      if (!A || Off < 0 || Off % 16)
        continue;
      auto &V = Out[A];
      if (!is_contained(V, Off))
        V.push_back(Off);
      Prov &Pv = SlotProv[{A, Off}];
      SmallVector<const Value *, 4> Objs;
      getUnderlyingObjects(SI->getValueOperand(), Objs);
      for (const Value *O : Objs) {
        if (isa<AllocaInst>(O) || isa<Argument>(O) || isa<GlobalValue>(O))
          Pv.Objs.insert(O);
        else if (!isa<ConstantPointerNull>(O) && !isa<UndefValue>(O))
          Pv.Unknown = true;
      }
    }
    for (auto &[A, Offs] : Out)
      Slots += Offs.size();
  }

  static void lifetimeMarkers(AllocaInst *A, SmallVectorImpl<Instruction *> &Starts,
                              SmallVectorImpl<Instruction *> &Ends) {
    SmallVector<Value *, 4> Work{A};
    SmallPtrSet<Value *, 8> Seen;
    while (!Work.empty()) {
      Value *V = Work.pop_back_val();
      if (!Seen.insert(V).second)
        continue;
      for (User *U : V->users()) {
        if (auto *II = dyn_cast<IntrinsicInst>(U)) {
          if (II->getIntrinsicID() == Intrinsic::lifetime_start)
            Starts.push_back(II);
          else if (II->getIntrinsicID() == Intrinsic::lifetime_end)
            Ends.push_back(II);
        } else if (isa<CastInst>(U) || isa<GetElementPtrInst>(U))
          Work.push_back(U);
      }
    }
  }

  bool liveAt(AllocaInst *A, Instruction *At, DominatorTree &DT) {
    SmallVector<Instruction *, 2> Starts, Ends;
    lifetimeMarkers(A, Starts, Ends);
    if (Starts.empty() && Ends.empty())
      return true;
    bool Dom = false;
    for (Instruction *S : Starts)
      Dom |= DT.dominates(S, At);
    if (!Dom)
      return false;
    for (Instruction *E : Ends)
      if (E != At && isPotentiallyReachable(E, At, nullptr, &DT))
        return false;
    return true;
  }

  // R4 filter: can slot S hold a capability into the frame object A?
  // An argument or global cannot (A is created in this frame); an unknown
  // origin (a load, a call result) can only if A's address escapes.
  bool mayHoldFrame(Slot S, AllocaInst *A) {
    if (!InvFilter)
      return true;
    auto It = SlotProv.find({S.A, S.Off});
    if (It == SlotProv.end())
      return true;
    if (It->second.Objs.count(A))
      return true;
    if (It->second.Unknown && PointerMayBeCaptured(A, /*ReturnCaptures=*/true))
      return true;
    ++Filtered;
    return false;
  }
  // Can slot S hold a capability into a heap block? Only an argument or an
  // unknown origin can; frame objects and globals cannot.
  bool mayHoldHeap(Slot S) {
    if (!InvFilter)
      return true;
    auto It = SlotProv.find({S.A, S.Off});
    if (It == SlotProv.end() || It->second.Unknown)
      return true;
    for (const Value *O : It->second.Objs)
      if (isa<Argument>(O))
        return true;
    ++Filtered;
    return false;
  }

  // R4 filter: a non-escaping slot object that is never read again after
  // the event cannot hand out the stale capability; skip it.
  bool readLater(AllocaInst *S, Instruction *At, DominatorTree &DT) {
    if (!InvFilter)
      return true;
    auto It = ReadLater.find({S, At});
    if (It != ReadLater.end())
      return It->second;
    bool R = PointerMayBeCaptured(S, /*ReturnCaptures=*/true);
    if (!R) {
      SmallVector<const Value *, 8> WL{S};
      SmallPtrSet<const Value *, 16> Seen;
      while (!WL.empty() && !R) {
        const Value *V = WL.pop_back_val();
        if (!Seen.insert(V).second)
          continue;
        for (const User *U : V->users()) {
          auto *I = dyn_cast<Instruction>(U);
          if (!I)
            continue;
          if (isa<GetElementPtrInst>(I) || isa<CastInst>(I) || isa<PHINode>(I) ||
              isa<SelectInst>(I)) {
            WL.push_back(I);
            continue;
          }
          if (isa<StoreInst>(I) || I->isLifetimeStartOrEnd() ||
              isa<DbgInfoIntrinsic>(I))
            continue;
          // A load or any other reader (memcpy source, call): reachable?
          if (I != At && isPotentiallyReachable(At, I, nullptr, &DT)) {
            R = true;
            break;
          }
        }
      }
    }
    if (!R)
      ++Filtered;
    ReadLater[{S, At}] = R;
    return R;
  }
  DenseMap<std::pair<AllocaInst *, Instruction *>, bool> ReadLater;

  // if (tag(c) && base(c) - Lo <u Len) slot = cleartag(c)
  void checkAndClear(IRBuilder<> &B, Slot S, Value *Lo, Value *Len) {
    Type *CapTy = PointerType::get(M.getContext(), 200);
    Value *P = S.Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), S.A, S.Off) : S.A;
    LoadInst *C = B.CreateAlignedLoad(CapTy, P, Align(16), "cheri.inv.cap");
    Value *T = B.CreateCall(decl(Intrinsic::cheri_cap_tag_get), {C});
    Value *Bs = B.CreateCall(decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {C});
    Value *In = B.CreateICmpULT(B.CreateSub(Bs, Lo), Len);
    Value *Kill = B.CreateAnd(T, In);
    Value *Cl = B.CreateCall(decl(Intrinsic::cheri_cap_tag_clear), {C});
    B.CreateAlignedStore(B.CreateSelect(Kill, Cl, C), P, Align(16));
    ++RangeChecks;
  }

  void runOn(Function &F) {
    MapVector<AllocaInst *, SmallVector<int64_t, 2>> CapSlots;
    collectSlots(F, CapSlots);
    // Feasibility count for loan-end invalidation (design only, 7.2).
    for (Instruction &I : instructions(F))
      if (I.getMetadata(memannot::LastUseMD)) {
        ++LUCarriers;
        if (Value *P = getLoadStorePointerOperand(&I)) {
          int64_t Off;
          Value *Root = GetPointerBaseWithConstantOffset(P, Off, DL);
          if (auto *LI = dyn_cast_or_null<LoadInst>(Root))
            if (isa<AllocaInst>(GetPointerBaseWithConstantOffset(LI->getPointerOperand(), Off, DL)))
              ++LUFrameCopies;
        }
      }
    if (CapSlots.empty())
      return;
    DominatorTree DT(F);
    SmallVector<IntrinsicInst *, 8> Ends;
    SmallVector<CallBase *, 4> Frees;
    for (Instruction &I : instructions(F)) {
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        if (II->getIntrinsicID() == Intrinsic::lifetime_end)
          Ends.push_back(II);
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (CB->getOperandBundle(memannot::TagFree))
          Frees.push_back(CB);
    }
    IRBuilder<> B(M.getContext());
    if (Scope)
      for (IntrinsicInst *E : Ends) {
        auto *A = dyn_cast<AllocaInst>(E->getArgOperand(E->arg_size() - 1)->stripPointerCasts());
        if (!A || !A->isStaticAlloca())
          continue;
        std::optional<TypeSize> Sz = A->getAllocationSize(DL);
        if (!Sz || Sz->isScalable())
          continue;
        ++ScopeEvents;
        B.SetInsertPoint(E);
        auto It = CapSlots.find(A);
        if (It != CapSlots.end())
          for (int64_t Off : It->second) {
            Value *P = Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), A, Off) : A;
            B.CreateAlignedStore(
                ConstantPointerNull::get(PointerType::get(M.getContext(), 200)), P,
                Align(16));
            ++OwnNulled;
          }
        Value *Lo = nullptr;
        for (auto &[S, Offs] : CapSlots) {
          if (S == A || !liveAt(S, E, DT) || !readLater(S, E, DT))
            continue;
          if (!Lo)
            Lo = B.CreateCall(decl(Intrinsic::cheri_cap_address_get, {B.getInt64Ty()}), {A});
          for (int64_t Off : Offs)
            if (mayHoldFrame({S, Off}, A))
              checkAndClear(B, {S, Off}, Lo, B.getInt64(Sz->getFixedValue()));
        }
      }
    if (Free)
      for (CallBase *C : Frees) {
        if (isa<InvokeInst>(C))
          continue;
        Value *P = C->getOperandBundle(memannot::TagFree)->Inputs[0];
        if (!DL.isFatPointer(P->getType()))
          continue;
        ++FreeEvents;
        B.SetInsertPoint(C);
        Value *Lo = B.CreateCall(decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {P});
        Value *Len = B.CreateCall(decl(Intrinsic::cheri_cap_length_get, {B.getInt64Ty()}), {P});
        B.SetInsertPoint(C->getNextNode());
        for (auto &[S, Offs] : CapSlots) {
          if (!liveAt(S, C, DT) || !readLater(S, C, DT))
            continue;
          for (int64_t Off : Offs)
            if (mayHoldHeap({S, Off}))
              checkAndClear(B, {S, Off}, Lo, Len);
        }
      }
  }

  void run() {
    for (Function &F : M)
      if (!F.isDeclaration())
        runOn(F);
    if (!InvStatsOut.empty()) {
      std::error_code EC;
      raw_fd_ostream OS(InvStatsOut, EC, sys::fs::OF_Append | sys::fs::OF_Text);
      if (!EC)
        OS << "cheri-invalidate: " << M.getModuleIdentifier() << " mode="
           << InvalidateOpt << " cap_slots=" << Slots
           << " scope_events=" << ScopeEvents << " free_events=" << FreeEvents
           << " own_nulled=" << OwnNulled << " range_checks=" << RangeChecks
           << " lu_carriers=" << LUCarriers
           << " lu_frame_copies=" << LUFrameCopies << " filtered=" << Filtered << "\n";
    }
  }
};
} // namespace

bool memannot::runCheriInvalidate(Module &M) {
  StringRef Mode = InvalidateOpt;
  bool Scope = Mode == "scope" || Mode == "all";
  bool Free = Mode == "free" || Mode == "all";
  if (!Scope && !Free && InvStatsOut.empty())
    return false;
  Inv I(M, Scope, Free);
  I.run();
  return Scope || Free;
}
