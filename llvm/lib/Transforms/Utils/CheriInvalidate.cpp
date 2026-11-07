//===- CheriInvalidate.cpp - M5r R4 Track B prototype -------------------===//
// [LLM-generated] CHERI M5r R4 (Track B, RELAYER-DESIGN.md section 7).
//
// Precise invalidation of the capability copies a function keeps in its own
// frame, decided late from the events rustc and the generic passes carry:
//   * llvm.lifetime.end(A): null A's own capability slots; clear the tag of
//     any other live frame capability slot whose base lies inside A;
//   * "mem.free"(p) on a deallocation call: after the call, clear the tag of
//     any live frame capability slot whose base lies inside p's bounds.
//   * R5: !mem.last_use of loan L: after the carrier, null every frame slot
//     that only ever holds L's reference (all its capability stores carry
//     the rustc slot fact !mem.loan !{L}).
// Only capabilities into dead storage (or of an ended loan) are touched
// (fail-safe). Off by default: -cheri-invalidate=none|scope|free|loan|all,
// or a '+'-list (e.g. scope+free, the R4 "all").
//===----------------------------------------------------------------------===//
#include "llvm/ADT/SmallBitVector.h"
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
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<std::string> InvalidateOpt(
    "cheri-invalidate", cl::init("loan+free+slite+aflog"), cl::Hidden,
    cl::desc("M5r Track B: none, scope, slite (scope range checks without "
             "own-slot nulls, R10 D73), free, loan, flog (R10 D72 free log, "
             "opt-in), aflog (R12 D80 argument free log), loan+free+slite+aflog "
             "(default since R14 D83, owner OK 2026-11-05; R10-R13: "
             "loan+free+slite, which disables aflog; R9 D69: "
             "loan+free; R8 D57: loan), all, or a "
             "'+'-list (scope+free = R4 all)"));
// [LLM-generated] R5 (D40): a clear of a slot that is about to die (own slot
// before lifetime.end, or a loan clear) is a dead store to codegen:
// SelectionDAG drops stores to a frame object before its LIFETIME_END, so the
// R4 own-slot nulling never reached the binary. Volatile keeps it.
// [LLM-generated] M5r R6 (D48): tag every inserted clear with !pcsections
// "cheri_inv_{own,loan,scope,free}" so an ELF-level verifier can count the
// clears that reach the binary and check each one is a capability store.
// Data only (no .text change).
static cl::opt<bool> InvPcMap(
    "cheri-invalidate-pc-map", cl::init(true), cl::Hidden,
    cl::desc("M5r R6 (D48): record each inserted clear's pc in a "
             "cheri_inv_* pcsections section (ELF verifier)"));
static void markClear(Instruction *I, StringRef Sec) {
  if (!InvPcMap || !I)
    return;
  LLVMContext &Ctx = I->getContext();
  I->setMetadata(LLVMContext::MD_pcsections,
                 MDNode::get(Ctx, {MDString::get(Ctx, Sec)}));
}
// [LLM-generated] R10 (D73): scope mode without the own-slot nulls (the
// range checks of other slots into the dying object stay: u2).
static cl::opt<bool> InvOwnNull(
    "cheri-invalidate-own-null", cl::init(true), cl::Hidden,
    cl::desc("M5r R10 (D73): at a lifetime.end, null the dying object's own "
             "capability slots (default; =false keeps only the range checks)"));
static bool InvOwnNullEff = true;
// [LLM-generated] R11 (D77): cheaper free log.
static cl::opt<bool> FLogMayFree(
    "cheri-flog-may-free", cl::init(true), cl::Hidden,
    cl::desc("M5r R11 (D77): check the free log only after calls that may free "
             "(module may-free fixpoint; nofree declarations/intrinsics skip)"));
static cl::opt<unsigned> FLogRing("cheri-flog-ring", cl::init(4), cl::Hidden,
    cl::desc("M5r R11 (D77): free log ring entries (power of 2; R10: 8)"));
static cl::opt<unsigned> FLogChecks("cheri-flog-checks", cl::init(2), cl::Hidden,
    cl::desc("M5r R11 (D77): entries checked after a call (R10: 4)"));
static unsigned FLogNoFree = 0;
static cl::opt<bool> InvVolatile(
    "cheri-invalidate-volatile", cl::init(true), cl::Hidden,
    cl::desc("M5r R5: emit own-slot nulls and loan clears as volatile stores"));
// [LLM-generated] M6.0 D87. Off leaves only the slot store. On also emits
// llvm.cheri.cap.invalidate on the capability value so a loan held in a
// callee-saved register is cleared there; a later call cannot save it.
// Spill-slot nulling is the post-RA pass. Callee-saved save slots (the
// incoming register) are not nulled. D89: this does not put loan ids on MMOs.
static cl::opt<bool> InvCapReg(
    "cheri-invalidate-cap-reg", cl::init(true), cl::Hidden,
    cl::desc("M6.0 D87: at a loan last-use, clear the capability register "
             "(including a callee-saved one) and, after RA, a spill slot "
             "reloaded into it"));
// [LLM-generated] R6 (D41): a loan slot may have its address passed to a
// call or stored (fmt's `&&T` arguments). Every Rust pointer to the slot is a
// borrow of it whose region is inside the slot's type region, which is inside
// L's region, so nothing can legitimately read the slot after L ends, and a
// callee's write leaves a value whose region is dead too. Only raw-pointer
// reads after L ends (the gadget class) see the clear.
static cl::opt<bool> InvLoanEscape(
    "cheri-invalidate-loan-escape", cl::init(true), cl::Hidden,
    cl::desc("M5r R6: loan slots may escape to calls/memory (NLL region "
             "containment); variable-offset stores and atomics still disqualify"));
static cl::opt<bool> InvLoanDebug(
    "cheri-invalidate-loan-debug", cl::init(false), cl::Hidden,
    cl::desc("M5r R6: print why each !mem.loan slot is (not) a loan slot"));
static cl::opt<bool> InvAsmNoEscape(
    "cheri-invalidate-asm-noescape", cl::init(true), cl::Hidden,
    cl::desc("R5 (D37): an inline asm with an empty template (black_box) does "
             "not capture, read or write the pointers it is given"));
static cl::opt<bool> InvLoanSkip(
    "cheri-invalidate-loan-skip", cl::init(true), cl::Hidden,
    cl::desc("R5 (D37): no range check at a scope/free event for a loan slot "
             "whose loan-end clear lies on every path from its stores"));
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
  bool Scope, Free, Loan, FLog = false, AFLog = false;
  unsigned AFLogSkipFree = 0, AFLogSkipCall = 0;
  unsigned FLogFrees = 0, FLogCalls = 0;
  unsigned ScopeEvents = 0, FreeEvents = 0, OwnNulled = 0, RangeChecks = 0,
           Slots = 0, LUFrameCopies = 0, LUCarriers = 0, Filtered = 0;
  unsigned LoanFacts = 0, LoanSlots = 0, LoanClears = 0, LoanSkipped = 0, LoanEscaped = 0,
           AsmNoEscape = 0;
  // Provenance of the capabilities stored into each slot (R4 filter):
  // the identified underlying objects, and whether any origin is unknown.
  struct Prov {
    SmallPtrSet<const Value *, 4> Objs;
    bool Unknown = false;
  };
  DenseMap<std::pair<AllocaInst *, int64_t>, Prov> SlotProv;
  Inv(Module &M, bool Scope, bool Free, bool Loan)
      : M(M), DL(M.getDataLayout()), Scope(Scope), Free(Free), Loan(Loan) {}

  // R5 (D37): `asm sideeffect ""` (core::hint::black_box) executes nothing,
  // so it cannot capture, read or write anything at run time. Only this late
  // pass treats it so; the generic passes keep their conservative view.
  static bool isEmptyAsm(const CallBase *CB) {
    auto *IA = dyn_cast<InlineAsm>(CB->getCalledOperand());
    if (!IA)
      return false;
    StringRef T = StringRef(IA->getAsmString()).trim();
    while (T.consume_front("/*")) {
      size_t E = T.find("*/");
      if (E == StringRef::npos)
        return false;
      T = T.drop_front(E + 2).trim();
    }
    return T.empty();
  }
  struct NoAsmTracker : CaptureTracker {
    bool Captured = false, SawAsm = false;
    void tooManyUses() override { Captured = true; }
    Action captured(const Use *U, UseCaptureInfo) override {
      // A volatile access only uses the address (LLVM counts it as a
      // capture); it hands the pointer to nobody.
      if (auto *LI = dyn_cast<LoadInst>(U->getUser()))
        if (U->getOperandNo() == LI->getPointerOperandIndex())
          return ContinueIgnoringReturn;
      if (auto *SI = dyn_cast<StoreInst>(U->getUser()))
        if (U->getOperandNo() == SI->getPointerOperandIndex())
          return ContinueIgnoringReturn;
      if (auto *CB = dyn_cast<CallBase>(U->getUser()))
        if (InvAsmNoEscape && isEmptyAsm(CB)) {
          SawAsm = true;
          return ContinueIgnoringReturn;
        }
      // Reading a capability's address/bounds/tag (e.g. this pass's own
      // range-check operands) hands out no provenance.
      if (auto *II = dyn_cast<IntrinsicInst>(U->getUser()))
        switch (II->getIntrinsicID()) {
        case Intrinsic::cheri_cap_address_get:
        case Intrinsic::cheri_cap_base_get:
        case Intrinsic::cheri_cap_length_get:
        case Intrinsic::cheri_cap_tag_get:
        case Intrinsic::cheri_cap_invalidate:
          return ContinueIgnoringReturn;
        default:
          break;
        }
      Captured = true;
      return Stop;
    }
  };
  DenseMap<const Value *, bool> EscCache;
  bool escapes(const Value *V) {
    auto It = EscCache.find(V);
    if (It != EscCache.end())
      return It->second;
    NoAsmTracker T;
    PointerMayBeCaptured(V, &T);
    if (!T.Captured && T.SawAsm)
      ++AsmNoEscape;
    return EscCache[V] = T.Captured;
  }

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
    if (It->second.Unknown && escapes(A))
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
    bool R = escapes(S);
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
          if (auto *CB = dyn_cast<CallBase>(I))
            if (InvAsmNoEscape && isEmptyAsm(CB))
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
  void checkAndClear(IRBuilder<> &B, Slot S, Value *Lo, Value *Len,
                     StringRef RangeSec) {
    Type *CapTy = PointerType::get(M.getContext(), 200);
    Value *P = S.Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), S.A, S.Off) : S.A;
    LoadInst *C = B.CreateAlignedLoad(CapTy, P, Align(16), "cheri.inv.cap");
    Value *T = B.CreateCall(decl(Intrinsic::cheri_cap_tag_get), {C});
    Value *Bs = B.CreateCall(decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {C});
    Value *In = B.CreateICmpULT(B.CreateSub(Bs, Lo), Len);
    Value *Kill = B.CreateAnd(T, In);
    Value *Cl = B.CreateCall(decl(Intrinsic::cheri_cap_tag_clear), {C});
    markClear(B.CreateAlignedStore(B.CreateSelect(Kill, Cl, C), P, Align(16)),
              RangeSec);
    ++RangeChecks;
  }

  // ---- R5 (D36): loan-end invalidation ------------------------------------
  // A loan slot is a frame cap slot whose every capability store carries the
  // rustc slot fact !mem.loan with a common loan id L, and which nothing else
  // can write (no overlapping non-capability store, memory intrinsic or call,
  // and the alloca does not escape). At L's last use nothing can read the
  // reference any more (borrowck), so the slot is nulled right after it.
  struct LoanSlot {
    SmallVector<StoreInst *, 2> Stores;
    SmallVector<memannot::LoanRef, 2> Ids; // common to every store
    SmallVector<Instruction *, 2> Clears;
    bool OK = true;
  };
  MapVector<std::pair<AllocaInst *, int64_t>, LoanSlot> LS;

  static bool refsOverlap(ArrayRef<memannot::LoanRef> A,
                          ArrayRef<memannot::LoanRef> B) {
    for (const memannot::LoanRef &X : A)
      for (const memannot::LoanRef &Y : B)
        if (X.sameCopy(Y))
          return true;
    return false;
  }

  void collectLoanSlots(Function &F) {
    LS.clear();
    BadWhy.clear();
    unsigned LoanKind = M.getContext().getMDKindID(memannot::LoanMD);
    SmallPtrSet<AllocaInst *, 8> Bad;
    for (Instruction &I : instructions(F)) {
      if (auto *SI = dyn_cast<StoreInst>(&I)) {
        int64_t Off = 0;
        Value *Base = GetPointerBaseWithConstantOffset(SI->getPointerOperand(), Off, DL);
        auto *A = dyn_cast_or_null<AllocaInst>(Base);
        if (!A) {
          if (auto *U = dyn_cast<AllocaInst>(getUnderlyingObject(SI->getPointerOperand()))) {
            Bad.insert(U); // variable offset: may hit any slot
            BadWhy[U] = "var-offset-store";
          }
          continue;
        }
        MDNode *N = SI->getMetadata(LoanKind);
        if (N)
          ++LoanFacts;
        if (DL.isFatPointer(SI->getValueOperand()->getType()) && Off >= 0 && Off % 16 == 0) {
          LoanSlot &L = LS[{A, Off}];
          SmallVector<memannot::LoanRef, 2> Ids;
          memannot::appendLoanRefs(N, Ids);
          if (Ids.empty())
            L.OK = false;
          else if (L.Stores.empty())
            L.Ids = Ids;
          else
            erase_if(L.Ids, [&](const memannot::LoanRef &X) {
              return !any_of(Ids, [&](const memannot::LoanRef &Y) {
                return X.sameCopy(Y);
              });
            });
          L.Stores.push_back(SI);
          continue;
        }
        // A non-capability store overlapping a slot of A.
        uint64_t Sz = DL.getTypeStoreSize(SI->getValueOperand()->getType()).getKnownMinValue();
        for (int64_t O = (Off / 16) * 16; O < Off + (int64_t)Sz; O += 16)
          LS[{A, O}].OK = false;
        continue;
      }
      if (isa<AtomicRMWInst>(I) || isa<AtomicCmpXchgInst>(I)) {
        Value *P = isa<AtomicRMWInst>(I) ? cast<AtomicRMWInst>(I).getPointerOperand()
                                         : cast<AtomicCmpXchgInst>(I).getPointerOperand();
        if (auto *U = dyn_cast<AllocaInst>(getUnderlyingObject(P))) {
          Bad.insert(U);
          BadWhy[U] = "atomic";
        }
        continue;
      }
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        if (CB->isLifetimeStartOrEnd() || isa<DbgInfoIntrinsic>(CB) ||
            (InvAsmNoEscape && isEmptyAsm(CB)) || memannot::isMemFact(CB))
          continue;
        for (Value *Arg : CB->args())
          if (Arg->getType()->isPointerTy())
            if (auto *U = dyn_cast<AllocaInst>(getUnderlyingObject(Arg))) {
              Bad.insert(U); // memcpy/memset destination or a callee
              if (BadWhy[U].empty())
                BadWhy[U] = (Twine("call:") + (CB->getCalledFunction() ? CB->getCalledFunction()->getName() : StringRef("indirect"))).str();
            }
      }
    }
    for (auto &[K, L] : LS) {
      bool HadFact = any_of(L.Stores, [&](StoreInst *S) { return S->getMetadata(LoanKind); });
      const char *Why = !L.OK ? "untagged-or-overlap" : nullptr;
      if (!Why && Bad.count(K.first) && BadWhy.lookup(K.first).empty())
        Why = "bad";
      std::string BW = Bad.count(K.first) ? BadWhy.lookup(K.first) : "";
      if (!Why && !BW.empty() && !(InvLoanEscape && StringRef(BW).starts_with("call:") &&
                                            !StringRef(BW).starts_with("call:llvm.")))
        Why = BW.c_str();
      if (!Why && L.Ids.empty())
        Why = "no-common-id";
      if (!Why && L.Stores.empty())
        Why = "no-stores";
      if (!Why && !InvLoanEscape && escapes(K.first))
        Why = "escapes";
      if (!Why && InvLoanEscape && (!BW.empty() || escapes(K.first)))
        ++LoanEscaped;
      if (Why)
        L.OK = false;
      if (L.OK)
        ++LoanSlots;
      if (InvLoanDebug && HadFact)
        errs() << "loan-slot " << F.getName() << " " << K.first->getName() << "+"
               << K.second << " stores=" << L.Stores.size() << ": "
               << (Why ? Why : "OK") << "\n";
    }
  }
  DenseMap<AllocaInst *, std::string> BadWhy;

  // Capability value to clear at this last-use. Prefer the pointer the
  // carrier actually uses: that is the copy which may sit in a callee-saved
  // register or have been spilled. Otherwise the value stored into the slot.
  Value *loanCapValue(LoanSlot &L, Instruction *C, Instruction *At,
                      DominatorTree &DT) {
    const Value *Slot = nullptr;
    if (!L.Stores.empty())
      Slot = getUnderlyingObject(L.Stores.front()->getPointerOperand());
    auto Usable = [&](Value *V) {
      if (!V || !V->getType()->isPointerTy() || isa<Constant>(V))
        return false;
      if (Slot && getUnderlyingObject(V) == Slot)
        return false;
      if (auto *I = dyn_cast<Instruction>(V))
        return DT.dominates(I, At);
      return isa<Argument>(V);
    };
    if (auto *LI = dyn_cast<LoadInst>(C))
      if (LI->getType()->isPointerTy() && Slot &&
          getUnderlyingObject(LI->getPointerOperand()) == Slot &&
          DT.dominates(LI, At))
        return LI;
    if (Value *P = getLoadStorePointerOperand(C))
      if (Usable(P))
        return P;
    if (auto *CB = dyn_cast<CallBase>(C))
      for (Value *A : CB->args())
        if (Usable(A))
          return A;
    Value *Best = nullptr;
    const Instruction *BestAt = nullptr;
    for (StoreInst *S : L.Stores) {
      Value *V = S->getValueOperand();
      if (!Usable(V))
        continue;
      const Instruction *Where = dyn_cast<Instruction>(V);
      if (!Best || (Where && (!BestAt || DT.dominates(BestAt, Where)))) {
        Best = V;
        BestAt = Where;
      }
    }
    return Best;
  }

  void loanClears(Function &F, DominatorTree &DT) {
    unsigned LUKind = M.getContext().getMDKindID(memannot::LastUseMD);
    Type *CapTy = PointerType::get(M.getContext(), 200);
    SmallVector<Instruction *, 16> Carriers;
    auto bundleIds = [](Instruction &I, SmallVectorImpl<memannot::LoanRef> &Out) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB || !memannot::isMemFact(CB))
        return;
      memannot::appendBundleLoanRefs(*CB, Out);
    };
    for (Instruction &I : instructions(F)) {
      bool Meta = I.getMetadata(LUKind);
      SmallVector<memannot::LoanRef, 2> Bundle;
      bundleIds(I, Bundle);
      if (Meta || !Bundle.empty())
        Carriers.push_back(&I);
    }
    IRBuilder<> B(M.getContext());
    for (Instruction *C : Carriers) {
      if (C->isTerminator())
        continue; // invoke: the normal edge may be shared
      SmallVector<memannot::LoanRef, 4> Ids;
      memannot::appendLoanRefs(C->getMetadata(LUKind), Ids);
      bundleIds(*C, Ids);
      for (auto &[K, L] : LS) {
        if (!L.OK || !refsOverlap(L.Ids, Ids))
          continue;
        Instruction *At = C->getNextNode();
        if (!liveAt(K.first, At, DT))
          continue; // never store to a dead (possibly recoloured) slot
        B.SetInsertPoint(At);
        Value *P = K.second ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), K.first, K.second)
                            : K.first;
        L.Clears.push_back(B.CreateAlignedStore(ConstantPointerNull::get(
                                                    cast<PointerType>(CapTy)),
                                                P, Align(16), InvVolatile));
        markClear(L.Clears.back(), "cheri_inv_loan");
        // D89: the clear's identity for the rest of codegen is this
        // !pcsections tag, not a loan id on the store's MachineMemOperand.
        if (InvCapReg)
          if (Value *Cap = loanCapValue(L, C, At, DT))
            B.CreateCall(decl(Intrinsic::cheri_cap_invalidate), {Cap});
        ++LoanClears;
      }
    }
    if (InvLoanDebug)
      for (auto &[K, L] : LS)
        if (L.OK && L.Clears.empty()) {
          bool Any = any_of(Carriers, [&](Instruction *C) {
            SmallVector<memannot::LoanRef, 4> Ids;
            memannot::appendLoanRefs(C->getMetadata(LUKind), Ids);
            bundleIds(*C, Ids);
            return refsOverlap(L.Ids, Ids);
          });
          errs() << "loan-noclear " << F.getName() << " " << K.first->getName()
                 << ": " << (Any ? "carrier-not-live-or-terminator" : "no-carrier") << "\n";
        }
  }

  // Can From reach To without passing one of Block?
  static bool reachAvoid(Instruction *From, Instruction *To,
                         const SmallPtrSetImpl<Instruction *> &Block) {
    auto Scan = [&](BasicBlock::iterator It, BasicBlock *BB) -> int {
      for (; It != BB->end(); ++It) {
        if (&*It == To)
          return 1;
        if (Block.count(&*It))
          return 0;
      }
      return -1;
    };
    int R = Scan(std::next(From->getIterator()), From->getParent());
    if (R >= 0)
      return R == 1;
    SmallVector<BasicBlock *, 8> WL(successors(From->getParent()));
    SmallPtrSet<BasicBlock *, 32> Seen;
    while (!WL.empty()) {
      BasicBlock *BB = WL.pop_back_val();
      if (!Seen.insert(BB).second)
        continue;
      R = Scan(BB->begin(), BB);
      if (R == 1)
        return true;
      if (R == 0)
        continue;
      append_range(WL, successors(BB));
    }
    return false;
  }

  // R5 (D37): a loan slot whose clear lies on every path from each of its
  // stores to the event cannot hold a stale capability there.
  bool loanCovered(AllocaInst *A, int64_t Off, Instruction *E) {
    if (!InvLoanSkip || !Loan)
      return false;
    auto It = LS.find({A, Off});
    if (It == LS.end() || !It->second.OK || It->second.Clears.empty())
      return false;
    SmallPtrSet<Instruction *, 4> Blk(It->second.Clears.begin(), It->second.Clears.end());
    for (StoreInst *St : It->second.Stores)
      if (reachAvoid(St, E, Blk))
        return false;
    ++LoanSkipped;
    return true;
  }

  // [LLM-generated] R10 (D72) free log: a small global ring of the last
  // freed [base, len) ranges and a free counter. A free event appends; a
  // caller whose live heap-capable frame slots are read after a call checks
  // them against the entries the call appended (frees in other frames, hu5).
  // Fail-safe: an overflowed ring only misses clears, it never adds one.
  // R11 (D77): ring size and entries checked per call are options; the
  // global's name carries the size so differently built crates cannot mix.
  unsigned FLogN = 8, FLogCheck = 4;
  SmallPtrSet<const Function *, 32> MayFree;
  bool callMayFree(const CallBase *C) const {
    if (C->hasFnAttr(Attribute::NoFree))
      return false;
    if (C->getOperandBundle(memannot::TagFree))
      return true;
    const Function *Fn = C->getCalledFunction();
    if (!Fn)
      return true;
    if (Fn->isIntrinsic())
      return false;
    if (Fn->isDeclaration())
      return !Fn->doesNotFreeMemory();
    return MayFree.count(Fn);
  }
  void computeMayFree() {
    bool Changed = true;
    while (Changed) {
      Changed = false;
      for (Function &F : M) {
        if (F.isDeclaration() || MayFree.count(&F))
          continue;
        for (Instruction &I : instructions(F))
          if (auto *CB = dyn_cast<CallBase>(&I); CB && callMayFree(CB)) {
            MayFree.insert(&F);
            Changed = true;
            break;
          }
      }
    }
  }
  // [LLM-generated] R12 (D80, "aflog"): argument-free free log. Only frees of
  // objects reached from a function argument append to the log, and only calls
  // passing a pointer to a callee that may free through that argument check it
  // (lu6: an owner moved into a callee that drops it). Frees of a function's
  // own allocations and calls that cannot free a caller's object stay unchecked.
  DenseMap<const Function *, SmallBitVector> FreesArg;
  static int argOf(Value *V) {
    SmallPtrSet<Value *, 16> Seen;
    SmallVector<Value *, 8> W{V};
    while (!W.empty()) {
      Value *X = W.pop_back_val()->stripPointerCasts();
      if (!Seen.insert(X).second)
        continue;
      if (auto *A = dyn_cast<Argument>(X))
        return A->getArgNo();
      if (auto *G = dyn_cast<GetElementPtrInst>(X))
        W.push_back(G->getPointerOperand());
      else if (auto *L = dyn_cast<LoadInst>(X))
        W.push_back(L->getPointerOperand());
      else if (auto *P = dyn_cast<PHINode>(X))
        for (Value *In : P->incoming_values())
          W.push_back(In);
      else if (auto *S = dyn_cast<SelectInst>(X)) {
        W.push_back(S->getTrueValue());
        W.push_back(S->getFalseValue());
      } else if (auto *C = dyn_cast<CallBase>(X); C && C->arg_size() &&
                 C->getCalledFunction() && C->getCalledFunction()->isIntrinsic() &&
                 C->getArgOperand(0)->getType()->isPointerTy())
        W.push_back(C->getArgOperand(0));
      else if (auto *C = dyn_cast<CallBase>(X); C && C->getCalledFunction() &&
                 C->getCalledFunction()->getName().starts_with("llvm.mem.claim"))
        W.push_back(C->getArgOperand(0));
      else if (auto *I2P = dyn_cast<IntToPtrInst>(X))
        W.push_back(I2P->getOperand(0));
    }
    return -1;
  }
  bool callFreesArg(const CallBase *C, unsigned J) const {
    const Function *Fn = C->getCalledFunction();
    if (!Fn)
      return false;
    auto It = FreesArg.find(Fn);
    return It != FreesArg.end() && J < It->second.size() && It->second.test(J);
  }
  void computeFreesArg() {
    bool Changed = true;
    while (Changed) {
      Changed = false;
      for (Function &F : M) {
        if (F.isDeclaration())
          continue;
        SmallBitVector &BV = FreesArg[&F];
        if (BV.size() < F.arg_size())
          BV.resize(F.arg_size());
        for (Instruction &I : instructions(F)) {
          auto *CB = dyn_cast<CallBase>(&I);
          if (!CB)
            continue;
          SmallVector<Value *, 4> Freed;
          if (auto OB = CB->getOperandBundle(memannot::TagFree))
            Freed.push_back(OB->Inputs[0]);
          for (unsigned J = 0; J < CB->arg_size(); ++J)
            if (callFreesArg(CB, J))
              Freed.push_back(CB->getArgOperand(J));
          for (Value *P : Freed) {
            int A = argOf(P);
            if (A >= 0 && !BV.test(A)) {
              BV.set(A);
              Changed = true;
            }
          }
        }
      }
    }
  }
  GlobalVariable *FLogGV = nullptr;
  GlobalVariable *flog() {
    if (FLogGV)
      return FLogGV;
    Type *I64 = Type::getInt64Ty(M.getContext());
    auto *Ent = ArrayType::get(I64, 2 * FLogN);
    auto *Ty = StructType::get(M.getContext(), {I64, Ent});
    std::string Name = FLogN == 8 ? "__cheri_free_log" : "__cheri_free_log" + std::to_string(FLogN);
    FLogGV = M.getGlobalVariable(Name);
    if (!FLogGV) {
      FLogGV = new GlobalVariable(M, Ty, false, GlobalValue::LinkOnceODRLinkage,
                                  Constant::getNullValue(Ty), Name,
                                  nullptr, GlobalValue::NotThreadLocal, 200);
      FLogGV->setVisibility(GlobalValue::HiddenVisibility);
      FLogGV->setAlignment(Align(16));
    }
    return FLogGV;
  }
  Value *flogCount(IRBuilder<> &B) {
    return B.CreateAlignedLoad(B.getInt64Ty(), flog(), Align(8), true, "cheri.flog.n");
  }
  Value *flogEnt(IRBuilder<> &B, Value *Idx, unsigned Field) {
    Type *I64 = B.getInt64Ty();
    Value *I = B.CreateAdd(B.CreateShl(B.CreateAnd(Idx, FLogN - 1), 1), B.getInt64(Field));
    return B.CreateInBoundsGEP(flog()->getValueType(), flog(), {B.getInt32(0), B.getInt32(1), I});
    (void)I64;
  }
  void flogAppend(IRBuilder<> &B, Value *Lo, Value *Len) {
    Value *N = flogCount(B);
    B.CreateAlignedStore(Lo, flogEnt(B, N, 0), Align(8), true);
    B.CreateAlignedStore(Len, flogEnt(B, N, 1), Align(8), true);
    B.CreateAlignedStore(B.CreateAdd(N, B.getInt64(1)), flog(), Align(8), true);
    ++FLogFrees;
  }
  void flogCalls(Function &F, MapVector<AllocaInst *, SmallVector<int64_t, 2>> &CapSlots,
                 DominatorTree &DT) {
    SmallVector<CallBase *, 8> Calls;
    for (Instruction &I : instructions(F))
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        if (isa<IntrinsicInst>(CB) || CB->isInlineAsm() || isa<InvokeInst>(CB) ||
            CB->getOperandBundle(memannot::TagFree) || CB->doesNotReturn() ||
            CB->onlyReadsMemory() || CB->onlyAccessesInaccessibleMemory())
          continue;
        if (FLogMayFree && !callMayFree(CB)) {
          ++FLogNoFree;
          continue;
        }
        if (AFLog) {
          bool Any = false;
          for (unsigned J = 0; J < CB->arg_size() && !Any; ++J)
            Any = CB->getArgOperand(J)->getType()->isPointerTy() && callFreesArg(CB, J);
          if (!Any) {
            ++AFLogSkipCall;
            continue;
          }
        }
        Calls.push_back(CB);
      }
    // Decide every call first: the splits below invalidate DT.
    SmallVector<std::pair<CallBase *, SmallVector<Slot, 4>>, 8> Todo;
    for (CallBase *C : Calls) {
      SmallVector<Slot, 4> Ss;
      // An escaping slot may be rewritten by the callee with a capability to
      // an object allocated in a block the same call freed: not checked.
      for (auto &[S, Offs] : CapSlots)
        if (!escapes(S) && liveAt(S, C, DT) && readLater(S, C, DT))
          for (int64_t Off : Offs)
            if (mayHoldHeap({S, Off}))
              Ss.push_back({S, Off});
      if (!Ss.empty())
        Todo.push_back({C, Ss});
    }
    for (auto &[C, Ss] : Todo) {
      IRBuilder<> B(C);
      Value *N0 = flogCount(B);
      B.SetInsertPoint(C->getNextNode());
      Value *N1 = flogCount(B);
      Value *D = B.CreateSub(N1, N0);
      Instruction *Then = SplitBlockAndInsertIfThen(B.CreateICmpNE(D, B.getInt64(0)),
                                                    &*B.GetInsertPoint(), false);
      IRBuilder<> TB(Then);
      for (unsigned K = 0; K < FLogCheck; ++K) {
        Value *Idx = TB.CreateSub(N1, TB.getInt64(K + 1));
        Value *Lo = TB.CreateAlignedLoad(TB.getInt64Ty(), flogEnt(TB, Idx, 0), Align(8), true);
        Value *Len = TB.CreateAlignedLoad(TB.getInt64Ty(), flogEnt(TB, Idx, 1), Align(8), true);
        Len = TB.CreateSelect(TB.CreateICmpUGT(D, TB.getInt64(K)), Len, TB.getInt64(0));
        for (Slot S : Ss)
          checkAndClear(TB, S, Lo, Len, "cheri_inv_free");
      }
      ++FLogCalls;
    }
  }

  void runOn(Function &F) {
    MapVector<AllocaInst *, SmallVector<int64_t, 2>> CapSlots;
    collectSlots(F, CapSlots);
    if (FLog) {
      // R10 (D72): every free event of every function appends to the log.
      for (Instruction &I : instructions(F))
        if (auto *CB = dyn_cast<CallBase>(&I))
          if (!isa<InvokeInst>(CB))
            if (auto OB = CB->getOperandBundle(memannot::TagFree))
              if (DL.isFatPointer(OB->Inputs[0]->getType())) {
                if (AFLog && argOf(OB->Inputs[0]) < 0) {
                  ++AFLogSkipFree;
                  continue;
                }
                IRBuilder<> B(CB);
                Value *P = OB->Inputs[0];
                Value *Lo = B.CreateCall(decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {P});
                Value *Len = B.CreateCall(decl(Intrinsic::cheri_cap_length_get, {B.getInt64Ty()}), {P});
                Value *T = B.CreateCall(decl(Intrinsic::cheri_cap_tag_get), {P});
                flogAppend(B, Lo, B.CreateSelect(T, Len, B.getInt64(0)));
              }
    }
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
    collectLoanSlots(F);
    if (Loan)
      loanClears(F, DT);
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
        if (It != CapSlots.end() && InvOwnNullEff)
          for (int64_t Off : It->second) {
            Value *P = Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), A, Off) : A;
            markClear(B.CreateAlignedStore(
                ConstantPointerNull::get(PointerType::get(M.getContext(), 200)), P,
                Align(16), InvVolatile), "cheri_inv_own");
            ++OwnNulled;
          }
        Value *Lo = nullptr;
        for (auto &[S, Offs] : CapSlots) {
          if (S == A || !liveAt(S, E, DT) || !readLater(S, E, DT))
            continue;
          if (!Lo)
            Lo = B.CreateCall(decl(Intrinsic::cheri_cap_address_get, {B.getInt64Ty()}), {A});
          for (int64_t Off : Offs)
            if (mayHoldFrame({S, Off}, A) && !loanCovered(S, Off, E))
              checkAndClear(B, {S, Off}, Lo, B.getInt64(Sz->getFixedValue()),
                            "cheri_inv_scope");
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
            if (mayHoldHeap({S, Off}) && !loanCovered(S, Off, C))
              checkAndClear(B, {S, Off}, Lo, Len, "cheri_inv_free");
        }
      }
    if (FLog)
      flogCalls(F, CapSlots, DT); // last: it splits blocks
  }

  void run() {
    FLogN = FLogRing;
    FLogCheck = std::min<unsigned>(FLogChecks, FLogN);
    if (FLog && FLogMayFree)
      computeMayFree();
    if (AFLog)
      computeFreesArg();
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
           << " lu_frame_copies=" << LUFrameCopies << " filtered=" << Filtered
           << " loan_facts=" << LoanFacts << " loan_slots=" << LoanSlots
           << " loan_clears=" << LoanClears << " loan_skipped=" << LoanSkipped << " loan_escaped=" << LoanEscaped
           << " asm_noescape=" << AsmNoEscape << " flog_frees=" << FLogFrees
         << " flog_calls=" << FLogCalls << " flog_nofree=" << FLogNoFree
         << " aflog_skip_free=" << AFLogSkipFree << " aflog_skip_call=" << AFLogSkipCall << "\n";
    }
  }
};
} // namespace

// [LLM-generated] R9 (D67 gating): the inliner keeps an inlined
// deallocator's free fact only when free mode is on.
bool memannot::cheriInvalidateFreeActive() {
  StringRef Mode = InvalidateOpt;
  return Mode == "all" || Mode.contains("free");
}

bool memannot::runCheriInvalidate(Module &M) {
  StringRef Mode = InvalidateOpt;
  bool All = Mode == "all";
  // [LLM-generated] R10 (D73 default): "slite" = scope without own nulls.
  bool SLite = Mode.contains("slite");
  bool Scope = All || Mode.contains("scope") || SLite;
  InvOwnNullEff = InvOwnNull && !(SLite && !Mode.contains("scope") && !All);
  bool Free = All || Mode.contains("free");
  bool Loan = All || Mode.contains("loan");
  bool FLogOn = Mode.contains("flog");
  if (!Scope && !Free && !Loan && !FLogOn && InvStatsOut.empty())
    return false;
  Inv I(M, Scope, Free, Loan);
  I.FLog = FLogOn;
  I.AFLog = Mode.contains("aflog");
  I.run();
  return Scope || Free || Loan || FLogOn;
}
