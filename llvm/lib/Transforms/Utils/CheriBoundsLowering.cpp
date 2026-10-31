//===- CheriBoundsLowering.cpp - M5r R2 late CHERI bounds decisions -------===//
// [LLM-generated] CHERI M5r R2.
//
// The decision half of the late CHERI pass (RISCVCheriBoundsLowering runs it
// before LoopStrengthReduce, at every opt level). rustc and the generic
// passes only carry facts; every CHERI decision is made here, per check and
// per claim, following the Track A rule:
//   1. a fact or proof shows the access cannot go out of bounds: no software
//      check change and no narrow (class-1 sites whose "mem.check" marker the
//      optimizer already deleted; skip mode: alloc_inbounds-proved bases);
//   2. the check needs finer grain than a capability can express (raw sites,
//      Never/Dynamic lengths, borrows): keep the software check;
//   3. a capability narrow subsumes the check: insert the narrow from the
//      "mem.check" marker (base, len, esz) before the !mem.guard GEP and
//      remove the software check.
// Policies (module flag "cheri.bounds-policy" from rustc, overridden by
// -cheri-bounds-policy): off, narrow, elide, ub (M5.0 elide upper bound),
// drop (late drop, measurement only). -cheri-skip-narrow=false (local/m5
// option) is the noskip mode. Claims are lowered independently of the policy:
// an untrusted claim becomes llvm.cheri.cap.bounds.set unless discharged
// (CF_Verified or an allocation-bounded operand; never for CK_Param).
//===----------------------------------------------------------------------===//
#include "llvm/Transforms/Utils/MemAnnotCensus.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
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
#include "llvm/Support/KnownBits.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/CheriSkipNarrow.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;

static cl::opt<std::string> PolicyOpt(
    "cheri-bounds-policy", cl::init(""), cl::Hidden,
    cl::desc("Override the cheri.bounds-policy module flag: off, narrow, "
             "elide, ub, drop"));
static cl::opt<bool> ClaimNarrow(
    "cheri-claim-narrow", cl::init(true), cl::Hidden,
    cl::desc("Lower untrusted llvm.mem.claim to capability narrows (R2)"));
static cl::opt<bool> LenRange(
    "cheri-bounds-len-range", cl::init(true), cl::Hidden,
    cl::desc("Classify a run-time length whose known-bits maximum is "
             "always exact as Always (R2; M5.0 used static types only)"));
static cl::opt<std::string> StatsOut(
    "cheri-bounds-stats-out", cl::init(""), cl::Hidden,
    cl::desc("Append one line of per-module decision counts to this file"));

namespace {
enum Policy { P_Off, P_Narrow, P_Elide, P_UB, P_Drop };
enum Exactness { E_Always, E_Never, E_Dynamic };

struct Stats {
  unsigned Markers = 0, Merged = 0, Raw = 0, Borrow = 0, Unlinked = 0,
           Narrowed = 0, Skipped = 0, Removed = 0, TwoVersion = 0,
           Kept = 0, Guards = 0, NoEdge = 0;
  unsigned Claims = 0, ClaimNarrowed = 0, ClaimVerified = 0, ClaimProof = 0;
};

uint64_t rv64LLVMMask(uint64_t Len) {
  if (Len == 0)
    return ~0ULL;
  uint64_t Slice = Len >> 13;
  unsigned E = Slice ? 64 - llvm::countl_zero(Slice) : 0;
  bool IE = E != 0 || ((Len >> 12) & 1);
  unsigned EP = IE ? E + 3 : 0;
  return EP >= 64 ? 0 : ~0ULL << EP;
}
// Hardware-correct RV64 ISAv9 (MW=14) mask (as M5.0's rv64_alignment_mask).
uint64_t rv64Mask(uint64_t Len) {
  uint64_t M = rv64LLVMMask(Len);
  return rv64LLVMMask((Len + ~M) & M);
}

Exactness constExactness(unsigned AddrBits, uint64_t Bytes, uint64_t Align) {
  if (AddrBits == 64) {
    if (Bytes <= 4095)
      return E_Always;
    uint64_t M = rv64Mask(Bytes);
    if (Bytes & ~M)
      return E_Never;
    return Align >= (~M) + 1 ? E_Always : E_Dynamic;
  }
  return Bytes <= 511 ? E_Always : E_Dynamic; // CHERIoT
}

struct Lowering {
  Module &M;
  const DataLayout &DL;
  Policy Pol;
  bool Skip;
  Stats S;
  DenseSet<const Value *> Facts; // values with a mem.alloc_inbounds fact

  Lowering(Module &M, Policy Pol, bool Skip)
      : M(M), DL(M.getDataLayout()), Pol(Pol), Skip(Skip) {}

  // ---- proofs -------------------------------------------------------------
  bool hasAllocInbounds(const Value *V) {
    for (unsigned D = 0; D < 16; ++D) {
      V = V->stripPointerCasts();
      if (Facts.count(V))
        return true;
      if (const auto *A = dyn_cast<Argument>(V))
        return A->getParent()->getAttributes().hasParamAttr(
            A->getArgNo(), memannot::TagAllocInbounds);
      if (memannot::isTriviallyAllocInbounds(V, DL))
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

  bool allocBounded(const Value *V, SmallPtrSetImpl<const Value *> &Seen,
                    unsigned D) {
    if (D > 32)
      return false;
    V = V->stripPointerCasts();
    if (!Seen.insert(V).second)
      return true;
    if (Facts.count(V))
      return true;
    if (const auto *A = dyn_cast<Argument>(V))
      return A->getParent()->getAttributes().hasParamAttr(
          A->getArgNo(), memannot::TagAllocInbounds);
    if (isa<AllocaInst>(V) || isa<GlobalVariable>(V))
      return true;
    if (memannot::isMemClaim(V))
      return true; // narrowed or discharged by this pass
    if (const auto *GEP = dyn_cast<GEPOperator>(V))
      return allocBounded(GEP->getPointerOperand(), Seen, D + 1);
    if (const auto *PN = dyn_cast<PHINode>(V)) {
      for (const Value *In : PN->incoming_values())
        if (!allocBounded(In, Seen, D + 1))
          return false;
      return true;
    }
    if (const auto *SI = dyn_cast<SelectInst>(V))
      return allocBounded(SI->getTrueValue(), Seen, D + 1) &&
             allocBounded(SI->getFalseValue(), Seen, D + 1);
    if (const auto *II = dyn_cast<IntrinsicInst>(V))
      switch (II->getIntrinsicID()) {
      case Intrinsic::cheri_cap_address_set:
      case Intrinsic::cheri_cap_offset_set:
      case Intrinsic::ptrmask:
        return allocBounded(II->getArgOperand(0), Seen, D + 1);
      case Intrinsic::cheri_cap_bounds_set:
      case Intrinsic::cheri_cap_bounds_set_exact:
        return true;
      default:
        return false;
      }
    return false;
  }

  // ---- IR helpers ---------------------------------------------------------
  Value *narrow(IRBuilder<> &B, Value *Base, Value *Bytes, bool Exact) {
    Function *F = Intrinsic::getOrInsertDeclaration(
        &M,
        Exact ? Intrinsic::cheri_cap_bounds_set_exact
              : Intrinsic::cheri_cap_bounds_set,
        {Bytes->getType()});
    return B.CreateCall(F, {Base, Bytes});
  }

  Exactness exactness(Value *Base, Value *Len, uint64_t Esz,
                      std::optional<uint64_t> &ConstBytes) {
    unsigned AddrBits =
        DL.getIndexSizeInBits(Base->getType()->getPointerAddressSpace());
    if (auto *C = dyn_cast<ConstantInt>(Len)) {
      ConstBytes = C->getZExtValue() * Esz;
      return constExactness(AddrBits, *ConstBytes,
                            Base->getPointerAlignment(DL).value());
    }
    if (LenRange) {
      KnownBits K = computeKnownBits(Len, DL);
      APInt Max = K.getMaxValue();
      bool Ov = false;
      APInt MaxBytes = Max.umul_ov(APInt(Max.getBitWidth(), Esz), Ov);
      if (!Ov && MaxBytes.ule(AddrBits == 64 ? 4095 : 511))
        return E_Always;
    }
    return E_Dynamic;
  }

  // ---- checks -------------------------------------------------------------
  struct Marker {
    CallBase *Panic;
    Value *Base, *Len;
    uint64_t Esz, Site, Kind;
    BasicBlock *Pred = nullptr; // single conditional predecessor
    BasicBlock *Ok = nullptr;
  };

  void runChecks(Function &F) {
    SmallVector<Marker, 8> Markers;
    DenseMap<uint64_t, SmallVector<GetElementPtrInst *, 2>> Guards;
    for (Instruction &I : instructions(F)) {
      if (auto *GEP = dyn_cast<GetElementPtrInst>(&I))
        if (MDNode *G = I.getMetadata(memannot::GuardMD))
          if (G->getNumOperands() == 1)
            if (auto *C = mdconst::dyn_extract<ConstantInt>(G->getOperand(0)))
              Guards[C->getZExtValue()].push_back(GEP);
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      auto OB = CB->getOperandBundle(memannot::TagCheck);
      if (!OB)
        continue;
      ++S.Markers;
      auto *Esz = dyn_cast<ConstantInt>(OB->Inputs[2].get());
      auto *Site = dyn_cast<ConstantInt>(OB->Inputs[3].get());
      auto *Kind = dyn_cast<ConstantInt>(OB->Inputs[4].get());
      if (!Esz || !Site || !Kind) {
        ++S.Merged; // checks merged by the optimizer: keep
        continue;
      }
      if (!DL.isFatPointer(OB->Inputs[0]->getType()))
        continue; // not a capability: nothing to decide
      Marker Mk{CB, OB->Inputs[0].get(), OB->Inputs[1].get(),
                Esz->getZExtValue(), Site->getZExtValue(),
                Kind->getZExtValue()};
      BasicBlock *P = CB->getParent();
      if (BasicBlock *Pr = P->getSinglePredecessor())
        if (auto *Br = dyn_cast<CondBrInst>(Pr->getTerminator()))
          if (Br->getSuccessor(0) != Br->getSuccessor(1)) {
            Mk.Pred = Pr;
            Mk.Ok = Br->getSuccessor(Br->getSuccessor(0) == P ? 1 : 0);
          }
      Markers.push_back(Mk);
    }
    if (Markers.empty())
      return;
    DominatorTree DT(F);
    SmallPtrSet<GetElementPtrInst *, 8> Done;
    SmallVector<BasicBlock *, 4> DeadPanics;
    for (Marker &Mk : Markers) {
      unsigned CK = Mk.Kind & memannot::CHKF_KindMask;
      bool Borrow = Mk.Kind & memannot::CHKF_Borrow;
      bool RawSite = CK == memannot::CHK_RawChecked;
      // Guards of this marker: same site, same base.
      SmallVector<GetElementPtrInst *, 2> Mine, OnEdge;
      for (GetElementPtrInst *G : Guards.lookup(Mk.Site)) {
        if (Done.count(G) || G->getPointerOperand() != Mk.Base)
          continue;
        if (auto *LI = dyn_cast<Instruction>(Mk.Len))
          if (!DT.dominates(LI, G))
            continue;
        Mine.push_back(G);
        if (Mk.Pred && DT.dominates(BasicBlockEdge(Mk.Pred, Mk.Ok),
                                    G->getParent()))
          OnEdge.push_back(G);
      }
      S.Guards += Mine.size();
      if (Pol == P_Drop) {
        if (Mk.Pred) {
          removeCheck(Mk, DeadPanics);
          ++S.Removed;
        } else
          ++S.Kept;
        continue;
      }
      if (Borrow)
        ++S.Borrow;
      if (RawSite)
        ++S.Raw;
      if (Mine.empty()) {
        ++S.Unlinked; // no guard left: nothing to narrow, keep the check
        continue;
      }
      std::optional<uint64_t> CB;
      Exactness Ex = exactness(Mk.Base, Mk.Len, Mk.Esz, CB);
      bool Proved = hasAllocInbounds(Mk.Base);
      auto BytesAt = [&](IRBuilder<> &B) -> Value * {
        if (CB)
          return B.getInt64(*CB);
        Value *L = Mk.Len;
        return Mk.Esz == 1 ? L
                           : B.CreateMul(L, ConstantInt::get(L->getType(),
                                                             Mk.Esz),
                                         "", /*NUW=*/true, /*NSW=*/true);
      };
      // Narrow at each guard and keep the check (narrow mode, Never sites,
      // borrows in narrow mode); skippable with a proof (rule 1).
      auto NarrowKeep = [&](bool Exact) {
        if (Skip && Proved) {
          ++S.Skipped;
          return;
        }
        for (GetElementPtrInst *G : Mine) {
          IRBuilder<> B(G);
          G->setOperand(0, narrow(B, Mk.Base, BytesAt(B), Exact));
          Done.insert(G);
        }
        ++S.Narrowed;
      };
      bool CanRemove = Mk.Pred && !OnEdge.empty() && OnEdge.size() == Mine.size() &&
                       !Borrow && dominatesTerm(DT, Mk);
      if (Pol == P_Narrow) {
        if (RawSite) {
          ++S.Kept;
          continue;
        }
        NarrowKeep(Ex == E_Always);
        ++S.Kept;
        continue;
      }
      // elide / ub
      if (Borrow || (RawSite && Pol != P_UB) || !CanRemove) {
        if (!CanRemove && !Borrow && !RawSite)
          ++S.NoEdge;
        ++S.Kept;
        continue;
      }
      IRBuilder<> B(Mk.Pred->getTerminator());
      Value *Bytes = BytesAt(B);
      if (Ex == E_Always || (Pol == P_UB && Ex == E_Dynamic)) {
        rewriteGuards(OnEdge, narrow(B, Mk.Base, Bytes, true), Done);
        removeCheck(Mk, DeadPanics);
        ++S.Removed;
      } else if (Pol == P_UB) { // Never
        rewriteGuards(OnEdge, narrow(B, Mk.Base, Bytes, false), Done);
        removeCheck(Mk, DeadPanics);
        ++S.Removed;
      } else if (Ex == E_Dynamic) {
        Value *Exact = narrow(B, Mk.Base, Bytes, true);
        Function *TagF = Intrinsic::getOrInsertDeclaration(
            &M, Intrinsic::cheri_cap_tag_get);
        Value *Tag = B.CreateCall(TagF, {Exact});
        Value *Rounded = narrow(B, Mk.Base, Bytes, false);
        Value *Cap = B.CreateSelect(Tag, Exact, Rounded);
        rewriteGuards(OnEdge, Cap, Done);
        auto *Br = cast<CondBrInst>(Mk.Pred->getTerminator());
        Value *C = Br->getCondition();
        // Fail only when the software check fails and the exact narrow
        // did not keep the tag.
        Value *NewC = Br->getSuccessor(0) == Mk.Panic->getParent()
                          ? B.CreateAnd(C, B.CreateNot(Tag))
                          : B.CreateOr(C, Tag);
        Br->setCondition(NewC);
        ++S.TwoVersion;
      } else { // elide, Never: rounded narrow, keep the check
        NarrowKeep(false);
        ++S.Kept;
      }
    }
    for (BasicBlock *BB : DeadPanics)
      if (pred_empty(BB))
        DeleteDeadBlock(BB);
  }

  static bool dominatesTerm(DominatorTree &DT, const Marker &Mk) {
    Instruction *T = Mk.Pred->getTerminator();
    for (Value *V : {Mk.Base, Mk.Len})
      if (auto *I = dyn_cast<Instruction>(V))
        if (!DT.dominates(I, T))
          return false;
    return true;
  }

  static void rewriteGuards(ArrayRef<GetElementPtrInst *> Gs, Value *Cap,
                            SmallPtrSetImpl<GetElementPtrInst *> &Done) {
    for (GetElementPtrInst *G : Gs) {
      G->setOperand(0, Cap);
      // The software check is gone: an out-of-range index is now caught by
      // the capability, so the GEP may leave the object.
      G->setNoWrapFlags(GEPNoWrapFlags::none());
      Done.insert(G);
    }
  }

  void removeCheck(const Marker &Mk, SmallVectorImpl<BasicBlock *> &Dead) {
    auto *Br = cast<CondBrInst>(Mk.Pred->getTerminator());
    Value *C = Br->getCondition();
    BasicBlock *P = Mk.Panic->getParent();
    P->removePredecessor(Mk.Pred);
    UncondBrInst::Create(Mk.Ok, Br->getIterator());
    Br->eraseFromParent();
    RecursivelyDeleteTriviallyDeadInstructions(C);
    Dead.push_back(P);
  }

  // ---- claims -------------------------------------------------------------
  void runClaims(Function &F) {
    SmallVector<CallBase *, 8> Claims;
    for (Instruction &I : instructions(F))
      if (memannot::isMemClaim(&I))
        Claims.push_back(cast<CallBase>(&I));
    bool Discharge = cheriSkipNarrowEnabled() && cheriContractDischargeEnabled();
    for (CallBase *C : Claims) {
      ++S.Claims;
      Value *P = C->getArgOperand(0);
      auto *FlagsC = dyn_cast<ConstantInt>(C->getArgOperand(2));
      uint64_t Flags = FlagsC ? FlagsC->getZExtValue() : memannot::CF_Untrusted;
      uint64_t Kind = Flags & memannot::CF_KindMask;
      if (!(Flags & memannot::CF_Untrusted) || !DL.isFatPointer(P->getType()))
        continue; // trusted or not a capability: identity (stripped later)
      if (Discharge && Kind != memannot::CK_Param) {
        if (Flags & memannot::CF_Verified) {
          ++S.ClaimVerified;
          continue;
        }
        SmallPtrSet<const Value *, 16> Seen;
        Seen.insert(C);
        if (allocBounded(P, Seen, 0)) {
          ++S.ClaimProof;
          continue;
        }
      }
      IRBuilder<> B(C);
      Value *Bytes = C->getArgOperand(1);
      if (Bytes->getType() != B.getInt64Ty())
        Bytes = B.CreateZExtOrTrunc(Bytes, B.getInt64Ty());
      Value *N = narrow(B, P, Bytes, false);
      // The claim stays (its operand becomes the narrow) so the census and
      // stripAnnotations treat it as before; strip replaces it with N.
      C->setArgOperand(0, N);
      ++S.ClaimNarrowed;
    }
  }

  void collectFacts(Function &F) {
    for (Instruction &I : instructions(F))
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        if (II->getIntrinsicID() == Intrinsic::mem_fact)
          for (unsigned B = 0, E = II->getNumOperandBundles(); B != E; ++B) {
            OperandBundleUse OBU = II->getOperandBundleAt(B);
            if (OBU.getTagName() == memannot::TagAllocInbounds &&
                !OBU.Inputs.empty())
              Facts.insert(OBU.Inputs[0]->stripPointerCasts());
          }
  }

  void run() {
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      Facts.clear();
      collectFacts(F);
      if (Pol != P_Off)
        runChecks(F);
      if (ClaimNarrow)
        runClaims(F);
    }
    if (!StatsOut.empty() && (S.Markers || S.Claims)) {
      std::error_code EC;
      raw_fd_ostream OS(StatsOut, EC, sys::fs::OF_Append | sys::fs::OF_Text);
      if (!EC)
        OS << "cheri-bounds-lowering: " << M.getModuleIdentifier()
           << " policy=" << Pol << " skip=" << Skip << " markers=" << S.Markers
           << " merged=" << S.Merged << " raw=" << S.Raw
           << " borrow=" << S.Borrow << " unlinked=" << S.Unlinked
           << " guards=" << S.Guards << " narrowed=" << S.Narrowed
           << " skipped=" << S.Skipped << " removed=" << S.Removed
           << " twoversion=" << S.TwoVersion << " noedge=" << S.NoEdge
           << " kept=" << S.Kept << " claims=" << S.Claims
           << " claim_narrowed=" << S.ClaimNarrowed
           << " claim_verified=" << S.ClaimVerified
           << " claim_proof=" << S.ClaimProof << "\n";
    }
  }
};

Policy readPolicy(Module &M) {
  StringRef P = PolicyOpt;
  if (P.empty())
    if (auto *MD = dyn_cast_or_null<MDString>(M.getModuleFlag("cheri.bounds-policy")))
      P = MD->getString();
  if (P == "narrow")
    return P_Narrow;
  if (P == "elide")
    return P_Elide;
  if (P == "ub")
    return P_UB;
  if (P == "drop")
    return P_Drop;
  return P_Off;
}
} // namespace

bool memannot::runCheriBoundsLowering(Module &M) {
  runCensusLate(M);
  Lowering L(M, readPolicy(M), cheriSkipNarrowEnabled());
  L.run();
  stripAnnotations(M);
  return true;
}
