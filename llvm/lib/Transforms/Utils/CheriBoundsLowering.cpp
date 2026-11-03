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
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/LoopInfo.h"
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
#include "llvm/IR/PatternMatch.h"
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
static cl::opt<bool> CoverageCheck(
    "cheri-bounds-coverage", cl::init(true), cl::Hidden,
    cl::desc("R3 (D19): remove a check only if every access in its success "
             "region that depends on the checked index is covered"));
static cl::opt<bool> Relink(
    "cheri-bounds-relink", cl::init(true), cl::Hidden,
    cl::desc("R3 (D19): re-link markers whose guard was merged (e.g. sunk "
             "into a common successor) by site group and index PHI"));
static cl::opt<bool> ClaimCoalesce(
    "cheri-claim-coalesce", cl::init(true), cl::Hidden,
    cl::desc("R3 (D20): one narrow for constant-size claims of one base in a "
             "block whose ranges form one contiguous extent"));
static cl::opt<bool> SingleTagTest(
    "cheri-bounds-single-tag-test", cl::init(true), cl::Hidden,
    cl::desc("R4 (D22): two-version sites merge the exact and rounded "
             "capability with a PHI (one tag test) instead of a select"));
static cl::opt<bool> SplitMerged(
    "cheri-bounds-split-merged", cl::init(true), cl::Hidden,
    cl::desc("R4 (D26): one marker per conditional predecessor of a shared "
             "panic block"));
static cl::opt<bool> AdoptOrphans(
    "cheri-bounds-adopt", cl::init(true), cl::Hidden,
    cl::desc("R4 (D26): a marker adopts guards of proved-away sites that "
             "index its base with its checked index"));
static cl::opt<bool> BorrowDeref(
    "cheri-bounds-borrow-deref", cl::init(true), cl::Hidden,
    cl::desc("R4: a borrow check whose borrow is only dereferenced in the Ok "
             "block, with no side effect before the access, is treated as an "
             "access check (Vec/SmallVec Index borrows after inlining)"));
static cl::opt<bool> RecoverConst(
    "cheri-bounds-recover-const", cl::init(true), cl::Hidden,
    cl::desc("R5 (D30): a split marker whose index is a constant on its edge "
             "recovers the constant-offset accesses of its base in its Ok "
             "block as guards (fully unrolled loops)"));
static cl::opt<std::string> StatsOut(
    "cheri-bounds-stats-out", cl::init(""), cl::Hidden,
    cl::desc("Append one line of per-module decision counts to this file"));

namespace {
enum Policy { P_Off, P_Narrow, P_Elide, P_UB, P_Drop };
enum Exactness { E_Always, E_Never, E_Dynamic };

struct Stats {
  unsigned Markers = 0, Merged = 0, Raw = 0, Borrow = 0, Unlinked = 0,
           Narrowed = 0, Skipped = 0, Removed = 0, TwoVersion = 0,
           Kept = 0, Guards = 0, NoEdge = 0, Hoisted = 0, CSEd = 0, AlreadyNarrow = 0;
  unsigned TwoVersionInLoop = 0, SplitMarkers = 0, Adopted = 0, BorrowDeref = 0;
  unsigned Uncovered = 0, Relinked = 0, RelinkGuards = 0, ParentFirst = 0;
  unsigned Recovered = 0, RecoveredMarkers = 0;
  unsigned Claims = 0, ClaimNarrowed = 0, ClaimVerified = 0, ClaimProof = 0,
           ClaimCoalesced = 0, CoalesceGroups = 0;
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

using Builder = IRBuilder<ConstantFolder, IRBuilderCallbackInserter>;

struct Lowering {
  Module &M;
  SmallVector<Instruction *, 32> Created; // pure instructions this pass made
  Builder Bld;
  Builder &mk(Instruction *At) {
    Bld.SetInsertPoint(At);
    return Bld;
  }
  const DataLayout &DL;
  Policy Pol;
  bool Skip;
  Stats S;
  DenseSet<const Value *> Facts; // values with a mem.alloc_inbounds fact

  Lowering(Module &M, Policy Pol, bool Skip)
      : M(M),
        Bld(M.getContext(), ConstantFolder(),
            IRBuilderCallbackInserter(
                [this](Instruction *I) { Created.push_back(I); })),
        DL(M.getDataLayout()), Pol(Pol), Skip(Skip) {}

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
  // X*c, X<<k and the same constant compare equal.
  static bool sameBytes(Value *A, Value *B) {
    using namespace PatternMatch;
    if (A == B)
      return true;
    auto Split = [](Value *V, Value *&X, uint64_t &C) {
      const APInt *K;
      if (match(V, m_Mul(m_Value(X), m_APInt(K))) && K->getActiveBits() <= 64) {
        C = K->getZExtValue();
        return true;
      }
      if (match(V, m_Shl(m_Value(X), m_APInt(K))) && K->ult(63)) {
        C = 1ULL << K->getZExtValue();
        return true;
      }
      X = V;
      C = 1;
      return true;
    };
    if (auto *CA = dyn_cast<ConstantInt>(A))
      if (auto *CB = dyn_cast<ConstantInt>(B))
        return CA->getValue() == CB->getValue();
    Value *XA, *XB;
    uint64_t CA, CB;
    Split(A, XA, CA);
    Split(B, XB, CB);
    return XA == XB && CA == CB;
  }

  Value *narrow(Builder &B, Value *Base, Value *Bytes, bool Exact) {
    // Rule 1: the base is already narrowed to exactly these bytes (e.g. a
    // manual bounds_set_exact): no second narrow.
    // A claim only narrows further. R3: a claim this pass narrowed is also
    // looked through to its original operand, so a check narrow after a claim
    // narrow (claims run first) still sees a manual narrow under the claim
    // (R2 parity for k5_sub_index ub; claim lengths are not structurally
    // equal to check lengths, D24).
    auto Already = [&](Value *Inner) {
      auto *II = dyn_cast<IntrinsicInst>(Inner);
      return II &&
             (II->getIntrinsicID() == Intrinsic::cheri_cap_bounds_set_exact ||
              (!Exact && II->getIntrinsicID() == Intrinsic::cheri_cap_bounds_set)) &&
             sameBytes(II->getArgOperand(1), Bytes);
    };
    Value *Inner = Base->stripPointerCasts();
    while (memannot::isMemClaim(Inner)) {
      auto *CB = cast<CallBase>(Inner);
      auto It = ClaimOrig.find(CB);
      if (It != ClaimOrig.end() && Already(It->second->stripPointerCasts())) {
        ++S.AlreadyNarrow;
        return Base;
      }
      Inner = CB->getArgOperand(0)->stripPointerCasts();
    }
    if (Already(Inner)) {
      ++S.AlreadyNarrow;
      return Base;
    }
    Function *F = Intrinsic::getOrInsertDeclaration(
        &M,
        Exact ? Intrinsic::cheri_cap_bounds_set_exact
              : Intrinsic::cheri_cap_bounds_set,
        {Bytes->getType()});
    CallInst *N = B.CreateCall(F, {Base, Bytes});
    // R3 (D23): name the origin of this pass's narrows the way M5.0 named its
    // early ones, so tests on emitted IR can tell them apart. No pass reads it.
    if (NarrowTag)
      N->setMetadata(NarrowTag, MDNode::get(M.getContext(), {}));
    return N;
  }
  const char *NarrowTag = nullptr;
  DenseMap<CallBase *, Value *> ClaimOrig; // claim -> operand before narrowing
  // Entry claims (Param) are M3.0's entry narrows; every other claim kind is
  // a conversion (M3.3 contract) narrow.
  static const char *claimTag(CallBase *C) {
    auto *FC = dyn_cast<ConstantInt>(C->getArgOperand(2));
    if (FC && (FC->getZExtValue() & memannot::CF_KindMask) == memannot::CK_Param)
      return "cheri.entry_narrow";
    return "cheri.contract_narrow";
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
    Value *ParentBase = nullptr, *ParentLen = nullptr; // range markers (R3)
    Value *Index = nullptr; // the checked index, from Pred's compare (R3)
    ConstantInt *ConstIdx = nullptr; // R5 (D30): constant index on this edge
    SmallVector<GetElementPtrInst *, 2> Recov; // R5 (D30): its recovered guards
    SmallVector<GetElementPtrInst *, 2> Group; // re-linked shared guards
  };

  // R4: the borrow made by each guard is only used as the address of loads
  // and stores (directly or through constant-offset GEPs) in the Ok block,
  // and nothing before the last such access in that block can write memory,
  // unwind or not return. A fault at the access is then indistinguishable
  // from the panic at the borrow (nothing observable happens in between).
  static bool borrowOnlyDereferenced(const Marker &Mk,
                                     ArrayRef<GetElementPtrInst *> Gs) {
    if (!Mk.Ok || Gs.empty() || !Mk.Group.empty())
      return false;
    SmallPtrSet<const Instruction *, 8> Acc;
    for (GetElementPtrInst *G : Gs) {
      if (G->getParent() != Mk.Ok)
        return false;
      SmallVector<const Value *, 8> WL{G};
      while (!WL.empty()) {
        const Value *V = WL.pop_back_val();
        for (const User *U : V->users()) {
          auto *I = dyn_cast<Instruction>(U);
          if (!I || I->getParent() != Mk.Ok)
            return false;
          if (auto *GG = dyn_cast<GetElementPtrInst>(I)) {
            if (GG->getPointerOperand() != V || !GG->hasAllConstantIndices())
              return false;
            WL.push_back(GG);
          } else if (auto *L = dyn_cast<LoadInst>(I)) {
            if (L->isVolatile())
              return false;
            Acc.insert(L);
          } else if (auto *St = dyn_cast<StoreInst>(I)) {
            if (St->getPointerOperand() != V || St->isVolatile())
              return false;
            Acc.insert(St);
          } else
            return false;
        }
      }
    }
    if (Acc.empty())
      return false;
    unsigned Left = Acc.size();
    for (const Instruction &I : *Mk.Ok) {
      if (Acc.count(&I)) {
        if (--Left == 0)
          return true;
        continue;
      }
      if (isa<DbgInfoIntrinsic>(I) || I.isLifetimeStartOrEnd() ||
          isa<AssumeInst>(I) || memannot::isMemClaim(&I))
        continue;
      if (I.mayWriteToMemory() || I.mayThrow() || !I.willReturn())
        return false;
    }
    return false;
  }

  // R3: the index X of `X <u Len` (or `Len >u X`) that holds on the Ok edge.
  static Value *checkedIndex(const Marker &Mk) {
    using namespace PatternMatch;
    if (!Mk.Pred)
      return nullptr;
    auto *Br = cast<CondBrInst>(Mk.Pred->getTerminator());
    CmpPredicate P;
    Value *A, *B;
    if (!match(Br->getCondition(), m_ICmp(P, m_Value(A), m_Value(B))))
      return nullptr;
    ICmpInst::Predicate Pr = P;
    if (Br->getSuccessor(0) != Mk.Ok)
      Pr = ICmpInst::getInversePredicate(Pr);
    if (Pr == ICmpInst::ICMP_ULT && B == Mk.Len)
      return A;
    if (Pr == ICmpInst::ICMP_UGT && A == Mk.Len)
      return B;
    return nullptr;
  }

  // R3: V is X or computed from X by a short chain of integer arithmetic.
  static bool dependsOn(const Value *V, const Value *X, unsigned D = 0) {
    if (V == X)
      return true;
    if (D > 4)
      return false;
    if (const auto *BO = dyn_cast<BinaryOperator>(V))
      return dependsOn(BO->getOperand(0), X, D + 1) ||
             dependsOn(BO->getOperand(1), X, D + 1);
    if (const auto *C = dyn_cast<CastInst>(V))
      return dependsOn(C->getOperand(0), X, D + 1);
    if (const auto *PN = dyn_cast<PHINode>(V))
      return D == 0 && is_contained(PN->incoming_values(), X);
    return false;
  }

  // R3 (D19, design 3.3.1): every memory access in the region the success
  // edge dominates whose address depends on the checked index must be
  // covered: by a !mem.guard GEP (its own check decides it) or by a guard
  // this pass narrows. Otherwise removing the check could leave an access
  // that only the software check protected (e.g. a GVN-merged check).
  bool covered(const Marker &Mk, DominatorTree &DT,
               const SmallPtrSetImpl<GetElementPtrInst *> &Narrowed) {
    if (!CoverageCheck)
      return true;
    if (!Mk.Index && Mk.ConstIdx)
      return coveredConst(Mk, DT, Narrowed);
    if (!Mk.Index)
      return false;
    BasicBlockEdge E(Mk.Pred, Mk.Ok);
    auto AddrOK = [&](Value *Ptr) {
      for (unsigned D = 0; D < 4; ++D) {
        auto *G = dyn_cast<GetElementPtrInst>(Ptr);
        if (!G)
          return true;
        if (G->getMetadata(memannot::GuardMD) || Narrowed.count(G))
          return true;
        for (Value *Idx : G->indices())
          if (dependsOn(Idx, Mk.Index))
            return false;
        Ptr = G->getPointerOperand();
      }
      return true;
    };
    for (BasicBlock &BB : *Mk.Pred->getParent()) {
      if (!DT.dominates(E, &BB))
        continue;
      for (Instruction &I : BB) {
        if (Value *Ptr = getLoadStorePointerOperand(&I)) {
          if (!AddrOK(Ptr))
            return false;
        } else if (auto *CB = dyn_cast<CallBase>(&I)) {
          for (Value *A : CB->args())
            if (A->getType()->isPointerTy() && !AddrOK(A))
              return false;
        }
      }
    }
    return true;
  }

  // R5 (D30): coverage for a constant-index marker. Every access in the
  // region its success edge dominates whose address is the marker's base
  // plus anything must go through a guard (its own, a recovered one of a
  // sibling marker, or a !mem.guard GEP); a call taking a pointer derived
  // from the base is not covered.
  bool coveredConst(const Marker &Mk, DominatorTree &DT,
                    const SmallPtrSetImpl<GetElementPtrInst *> &Narrowed) {
    BasicBlockEdge E(Mk.Pred, Mk.Ok);
    auto FromBase = [&](Value *P) {
      return getUnderlyingObject(P, 8) == getUnderlyingObject(Mk.Base, 8);
    };
    // A guard GEP, or an address computed from a capability this pass (or
    // an earlier one) already narrowed: the hardware checks it.
    auto IsGuard = [&](Value *P) {
      for (unsigned D = 0; D < 6; ++D) {
        if (auto *G = dyn_cast<GetElementPtrInst>(P)) {
          if (G->getMetadata(memannot::GuardMD) || Narrowed.count(G) ||
              RecoveredG.count(G))
            return true;
          P = G->getPointerOperand();
        } else if (auto *CI = dyn_cast<CallBase>(P)) {
          return CI->doesNotAccessMemory() && P != Mk.Base;
        } else if (auto *PN = dyn_cast<PHINode>(P)) {
          return PN->getName().starts_with("cheri.cap");
        } else
          return false;
      }
      return false;
    };
    for (BasicBlock &BB : *Mk.Pred->getParent()) {
      if (!DT.dominates(E, &BB))
        continue;
      for (Instruction &I : BB) {
        if (Value *Ptr = getLoadStorePointerOperand(&I)) {
          if (FromBase(Ptr) && !IsGuard(Ptr))
            return false;
        } else if (auto *CB = dyn_cast<CallBase>(&I)) {
          if (CB == Mk.Panic || memannot::isMemFact(CB) || isa<DbgInfoIntrinsic>(CB) ||
              CB->doesNotAccessMemory())
            continue;
          for (Value *A : CB->args())
            if (A->getType()->isPointerTy() && FromBase(A))
              return false;
        }
      }
    }
    return true;
  }

  // R5 (D30): the Ok edge of Mk's compare excludes the constant K as an
  // out-of-range index: `Len != K` (an unrolled `icmp eq` loop exit; the
  // earlier unrolled checks give Len >= K) or `K <u Len`.
  static bool edgeExcludes(const Marker &Mk, ConstantInt *K) {
    using namespace PatternMatch;
    auto *Br = cast<CondBrInst>(Mk.Pred->getTerminator());
    CmpPredicate P;
    Value *A, *B;
    if (!match(Br->getCondition(), m_ICmp(P, m_Value(A), m_Value(B))))
      return false;
    ICmpInst::Predicate Pr = P;
    if (Br->getSuccessor(0) != Mk.Ok)
      Pr = ICmpInst::getInversePredicate(Pr);
    auto IsK = [&](Value *V) {
      auto *C = dyn_cast<ConstantInt>(V);
      return C && C->getValue() == K->getValue();
    };
    if (Pr == ICmpInst::ICMP_NE)
      return (A == Mk.Len && IsK(B)) || (B == Mk.Len && IsK(A));
    if (Pr == ICmpInst::ICMP_ULT)
      return IsK(A) && B == Mk.Len;
    if (Pr == ICmpInst::ICMP_UGT)
      return A == Mk.Len && IsK(B);
    return false;
  }

  // R5 (D30): base-wide guard recovery for fully unrolled loops. After full
  // unrolling the per-iteration accesses are constant-offset GEPs of the
  // base (or the base itself) and carry no !mem.guard, and the exit tests
  // are `icmp eq Len, K`. A split marker whose panic index is the constant K
  // on its edge, and whose edge excludes K, adopts the accesses of its Ok
  // block at exactly base + K * esz (access size <= esz) as its guards. A
  // narrow of (base, Len * esz) then traps exactly where the compare would
  // have panicked.
  void recoverConst(SmallVectorImpl<Marker> &Ms,
                    DenseMap<uint64_t, SmallVector<GetElementPtrInst *, 2>> &Guards) {
    if (!RecoverConst)
      return;
    for (Marker &Mk : Ms) {
      if (!Mk.Pred || Mk.Index || !Mk.Group.empty() ||
          (Mk.Kind & memannot::CHKF_KindMask) != memannot::CHK_Index ||
          Mk.Esz == 0 || Mk.Panic->arg_size() < 2)
        continue;
      bool Has = false;
      for (GetElementPtrInst *G : Guards.lookup(Mk.Site))
        Has |= G->getPointerOperand() == Mk.Base && !RecoveredG.count(G);
      if (Has)
        continue;
      Value *IdxV = Mk.Panic->getArgOperand(0);
      if (auto *PN = dyn_cast<PHINode>(IdxV))
        if (PN->getParent() == Mk.Panic->getParent())
          IdxV = PN->getIncomingValueForBlock(Mk.Pred);
      auto *K = dyn_cast<ConstantInt>(IdxV);
      if (!K || K->getValue().getActiveBits() > 32 || !edgeExcludes(Mk, K))
        continue;
      if (auto *LI = dyn_cast<Instruction>(Mk.Len))
        if (LI->getParent() == Mk.Ok)
          continue;
      int64_t Want = (int64_t)(K->getZExtValue() * Mk.Esz);
      SmallVector<Instruction *, 2> Acc;
      for (Instruction &I : *Mk.Ok) {
        Value *P = getLoadStorePointerOperand(&I);
        if (!P)
          continue;
        if (auto *SI = dyn_cast<StoreInst>(&I))
          if (SI->getValueOperand() == Mk.Base)
            continue;
        int64_t C = 0;
        if (P != Mk.Base) {
          auto *G = dyn_cast<GetElementPtrInst>(P);
          if (!G || G->getPointerOperand() != Mk.Base)
            continue;
          APInt Off(DL.getIndexTypeSizeInBits(G->getType()), 0);
          if (!G->accumulateConstantOffset(DL, Off))
            continue;
          C = Off.getSExtValue();
        }
        Type *T = isa<LoadInst>(&I) ? I.getType()
                                    : cast<StoreInst>(&I)->getValueOperand()->getType();
        if (C != Want || DL.getTypeStoreSize(T).getKnownMinValue() > Mk.Esz)
          continue;
        Acc.push_back(&I);
      }
      if (Acc.empty())
        continue;
      for (Instruction *I : Acc) {
        unsigned PI = isa<LoadInst>(I) ? 0 : 1;
        Value *P = I->getOperand(PI);
        auto *G = dyn_cast<GetElementPtrInst>(P);
        if (!G || G->getParent() != Mk.Ok || !G->hasOneUse()) {
          // A private guard GEP for this access (the original may be
          // shared, or the access may use the base directly).
          IRBuilder<> IB(I);
          G = cast<GetElementPtrInst>(IB.CreateGEP(
              IB.getInt8Ty(), Mk.Base, IB.getInt64(Want), "cheri.recovered"));
          I->setOperand(PI, G);
        }
        Mk.Recov.push_back(G);
        RecoveredG.insert(G);
        ++S.Recovered;
      }
      Mk.ConstIdx = K;
      ++S.RecoveredMarkers;
    }
  }
  SmallPtrSet<GetElementPtrInst *, 16> RecoveredG;

  // R3 (D19): a marker whose guard GEP was merged with another site's (e.g.
  // SimplifyCFG sinking two `store out[i]` into a common block drops both
  // !mem.guard ids) is re-linked to the merged GEP G when G indexes the same
  // base with the same element size and every incoming value of G's index
  // PHI is the checked index of a same-(base, len, esz) marker whose success
  // edge dominates that incoming block.
  void relink(SmallVectorImpl<Marker> &Ms, DominatorTree &DT,
              const DenseMap<uint64_t, SmallVector<GetElementPtrInst *, 2>> &Guards,
              Function &F) {
    if (!Relink)
      return;
    auto HasGuard = [&](const Marker &Mk) {
      for (GetElementPtrInst *G : Guards.lookup(Mk.Site))
        if (G->getPointerOperand() == Mk.Base)
          return true;
      return false;
    };
    SmallVector<unsigned, 4> Unlinked;
    for (unsigned I = 0; I < Ms.size(); ++I)
      if (Ms[I].Pred && Ms[I].Index && !HasGuard(Ms[I]))
        Unlinked.push_back(I);
    if (Unlinked.empty())
      return;
    for (Instruction &I : instructions(F)) {
      auto *G = dyn_cast<GetElementPtrInst>(&I);
      if (!G || G->getMetadata(memannot::GuardMD) || G->getNumIndices() != 1)
        continue;
      auto *PN = dyn_cast<PHINode>(G->idx_begin()->get());
      if (!PN)
        continue;
      SmallVector<unsigned, 4> Members;
      bool All = true;
      for (unsigned K = 0; K < PN->getNumIncomingValues() && All; ++K) {
        Value *V = PN->getIncomingValue(K);
        BasicBlock *In = PN->getIncomingBlock(K);
        bool Found = false;
        for (unsigned U : Unlinked) {
          Marker &Mk = Ms[U];
          if (Mk.Base != G->getPointerOperand() || Mk.Index != V ||
              DL.getTypeAllocSize(G->getSourceElementType()) != Mk.Esz)
            continue;
          // The success edge must dominate the PHI's incoming edge (for a
          // PHI use, dominates(Edge, Use) tests the edge In -> PN's block).
          (void)In;
          if (!DT.dominates(BasicBlockEdge(Mk.Pred, Mk.Ok), PN->getOperandUse(K)))
            continue;
          if (!is_contained(Members, U))
            Members.push_back(U);
          Found = true;
          break;
        }
        All = Found;
      }
      if (!All || Members.size() < 2)
        continue;
      // Same object and length for the whole group; base/len dominate G.
      Marker &M0 = Ms[Members[0]];
      bool Same = true;
      for (unsigned U : Members)
        Same &= Ms[U].Len == M0.Len;
      for (Value *V : {M0.Base, M0.Len})
        if (auto *VI = dyn_cast<Instruction>(V))
          Same &= DT.dominates(VI, G);
      if (!Same)
        continue;
      for (unsigned U : Members)
        Ms[U].Group.push_back(G);
      ++S.Relinked;
      S.RelinkGuards += Members.size();
    }
  }

  // R4 (D26): a guard GEP whose own check the optimizer proved redundant
  // against another site's check (GVN: `i ^ 1 < 8` and `i < 8` are the same
  // compare) has no marker left. It is adopted by the marker whose success
  // edge dominates it and whose compare checks exactly its index against the
  // same object: same base, one index equal to the checked index, element
  // size equal to the marker's. Narrowing it to (base, len * esz) is then the
  // hardware form of that very compare.
  void adopt(SmallVectorImpl<Marker> &Ms, DominatorTree &DT,
             DenseMap<uint64_t, SmallVector<GetElementPtrInst *, 2>> &Guards) {
    if (!AdoptOrphans)
      return;
    DenseSet<uint64_t> Live;
    for (Marker &Mk : Ms)
      Live.insert(Mk.Site);
    SmallVector<std::pair<uint64_t, GetElementPtrInst *>, 4> Add;
    for (auto &[Site, Gs] : Guards) {
      if (Live.count(Site))
        continue;
      for (GetElementPtrInst *G : Gs) {
        if (G->getNumIndices() != 1)
          continue;
        for (Marker &Mk : Ms) {
          if (!Mk.Pred || !Mk.Index || G->getPointerOperand() != Mk.Base ||
              G->idx_begin()->get() != Mk.Index ||
              DL.getTypeAllocSize(G->getSourceElementType()) != Mk.Esz ||
              !DT.dominates(BasicBlockEdge(Mk.Pred, Mk.Ok), G->getParent()))
            continue;
          if (auto *LI = dyn_cast<Instruction>(Mk.Len))
            if (!DT.dominates(LI, G))
              continue;
          Add.push_back({Mk.Site, G});
          ++S.Adopted;
          break;
        }
      }
    }
    for (auto &[Site, G] : Add)
      Guards[Site].push_back(G);
  }

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
      BasicBlock *P = CB->getParent();
      // R4 (D26): a panic block that several checks share (SimplifyCFG/GVN
      // merged their panics; differing bundle inputs became PHIs in P) is
      // split into one marker per conditional predecessor, with the inputs
      // that predecessor contributes. R2/R3 kept every merged check.
      SmallVector<BasicBlock *, 4> Preds;
      if (BasicBlock *Pr = P->getSinglePredecessor())
        Preds.push_back(Pr);
      else if (SplitMerged)
        for (BasicBlock *Pr : predecessors(P))
          if (!is_contained(Preds, Pr))
            Preds.push_back(Pr);
      if (Preds.empty())
        Preds.push_back(nullptr);
      bool Split = Preds.size() > 1;
      bool Any = false;
      for (BasicBlock *Pr : Preds) {
        auto In = [&](unsigned K) -> Value * {
          Value *V = OB->Inputs[K].get();
          if (auto *PN = dyn_cast<PHINode>(V))
            if (PN->getParent() == P && Pr)
              return PN->getIncomingValueForBlock(Pr);
          return V;
        };
        auto *Esz = dyn_cast<ConstantInt>(In(2));
        auto *Site = dyn_cast<ConstantInt>(In(3));
        auto *Kind = dyn_cast<ConstantInt>(In(4));
        if (!Esz || !Site || !Kind)
          continue;
        Value *Base = In(0), *Len = In(1);
        if (!DL.isFatPointer(Base->getType()) ||
            (isa<PHINode>(Base) && cast<PHINode>(Base)->getParent() == P))
          continue; // not a capability: nothing to decide
        Marker Mk{CB, Base, Len, Esz->getZExtValue(), Site->getZExtValue(),
                  Kind->getZExtValue()};
        if (OB->Inputs.size() >= 7 && DL.isFatPointer(In(5)->getType())) {
          Mk.ParentBase = In(5);
          Mk.ParentLen = In(6);
        }
        if (Pr)
          if (auto *Br = dyn_cast<CondBrInst>(Pr->getTerminator()))
            if (Br->getSuccessor(0) != Br->getSuccessor(1)) {
              Mk.Pred = Pr;
              Mk.Ok = Br->getSuccessor(Br->getSuccessor(0) == P ? 1 : 0);
            }
        if (Split && !Mk.Pred)
          continue;
        Mk.Index = checkedIndex(Mk);
        Markers.push_back(Mk);
        Any = true;
        if (Split)
          ++S.SplitMarkers;
      }
      if (!Any)
        ++S.Merged; // checks merged by the optimizer: keep
    }
    if (Markers.empty())
      return;
    DominatorTree DT(F);
    LoopInfo LI(DT); // computed before this pass changes the CFG
    relink(Markers, DT, Guards, F);
    // Guards this pass will narrow (for the coverage check): every marker's
    // own guards and the re-linked group guards.
    SmallPtrSet<GetElementPtrInst *, 16> Narrowable;
    for (Marker &Mk : Markers)
      for (GetElementPtrInst *G : Mk.Group)
        Narrowable.insert(G);
    adopt(Markers, DT, Guards);
    RecoveredG.clear();
    recoverConst(Markers, Guards);
    SmallPtrSet<GetElementPtrInst *, 8> Done;
    SmallVector<BasicBlock *, 4> DeadPanics;
    for (Marker &Mk : Markers) {
      unsigned CK = Mk.Kind & memannot::CHKF_KindMask;
      bool Borrow = Mk.Kind & memannot::CHKF_Borrow;
      bool RawSite = CK == memannot::CHK_RawChecked;
      // Guards of this marker: same site, same base.
      SmallVector<GetElementPtrInst *, 2> Mine, OnEdge;
      // R5 (D30): a constant-index marker owns exactly its recovered guards.
      for (GetElementPtrInst *G : Mk.Recov)
        if (!Done.count(G)) {
          Mine.push_back(G);
          OnEdge.push_back(G);
        }
      for (GetElementPtrInst *G : Guards.lookup(Mk.Site)) {
        if (Mk.ConstIdx)
          break;
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
      // Re-linked group guards count as on-edge: the group's checks jointly
      // dominate every path into them (relink()).
      SmallVector<GetElementPtrInst *, 2> GroupG;
      for (GetElementPtrInst *G : Mk.Group)
        if (!Done.count(G))
          GroupG.push_back(G);
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
      if (Mine.empty() && Mk.Group.empty()) {
        ++S.Unlinked; // no guard left: nothing to narrow, keep the check
        continue;
      }
      std::optional<uint64_t> CB;
      Exactness Ex = exactness(Mk.Base, Mk.Len, Mk.Esz, CB);
      // R4: a dereference-only borrow is lowered as an access check when the
      // check can then be removed outright (ub, or an exact narrow). Under
      // elide a Dynamic site would be two-versioned, which costs more than
      // the kept compare (measured: k_vec_hist +1173 instret).
      if (Borrow && BorrowDeref && Pol != P_Narrow &&
          (Pol == P_UB || Ex == E_Always) &&
          borrowOnlyDereferenced(Mk, Mine)) {
        Borrow = false;
        ++S.BorrowDeref;
      }
      bool Proved = hasAllocInbounds(Mk.Base);
      auto BytesAt = [&](Builder &B) -> Value * {
        if (CB)
          return B.getInt64(*CB);
        Value *L = Mk.Len;
        return Mk.Esz == 1 ? L
                           : B.CreateMul(L, ConstantInt::get(L->getType(),
                                                             Mk.Esz),
                                         "", /*NUW=*/true, /*NSW=*/true);
      };
      // R3 (design 3.3.3): a range marker narrows its parent first, then
      // the subrange from the narrowed parent (M5.0 s7b: a subrange narrow
      // from a wider capability can silently succeed past the parent).
      auto BaseAt = [&](Builder &B) -> Value * {
        Value *Base = Mk.Base;
        if (Mk.ParentBase && Mk.ParentLen) {
          Value *PL = Mk.ParentLen;
          if (Mk.Esz != 1)
            PL = B.CreateMul(PL, ConstantInt::get(PL->getType(), Mk.Esz), "",
                             true, true);
          Value *NP = narrow(B, Mk.ParentBase, PL, false);
          Function *AG = Intrinsic::getOrInsertDeclaration(
              &M, Intrinsic::cheri_cap_address_get, {B.getInt64Ty()});
          Value *Off = B.CreateSub(B.CreateCall(AG, {Mk.Base}),
                                   B.CreateCall(AG, {Mk.ParentBase}));
          Base = B.CreateGEP(B.getInt8Ty(), NP, Off);
          ++S.ParentFirst;
        }
        return Base;
      };
      auto NarrowAt = [&](Builder &B, bool Exact, Value *Bytes = nullptr,
                          Value *Base = nullptr) -> Value * {
        return narrow(B, Base ? Base : BaseAt(B), Bytes ? Bytes : BytesAt(B),
                      Exact);
      };
      // Narrow at each guard and keep the check (narrow mode, Never sites,
      // borrows in narrow mode); skippable with a proof (rule 1).
      auto NarrowKeep = [&](bool Exact) {
        if (Skip && Proved) {
          ++S.Skipped;
          return;
        }
        for (GetElementPtrInst *G : Mine) {
          Builder &B = mk(G);
          G->setOperand(0, NarrowAt(B, Exact));
          Done.insert(G);
        }
        for (GetElementPtrInst *G : GroupG) {
          Builder &B = mk(G);
          G->setOperand(0, NarrowAt(B, Exact));
          Done.insert(G);
        }
        ++S.Narrowed;
      };
      bool CanRemove = Mk.Pred && OnEdge.size() == Mine.size() &&
                       (!OnEdge.empty() || !Mk.Group.empty()) &&
                       !Borrow && dominatesTerm(DT, Mk);
      if (CanRemove && Pol != P_Narrow) {
        SmallPtrSet<GetElementPtrInst *, 16> Cov(Narrowable);
        for (GetElementPtrInst *G : Mine)
          Cov.insert(G);
        if (!covered(Mk, DT, Cov)) {
          CanRemove = false;
          ++S.Uncovered;
        }
      }
      // Group guards cannot be two-versioned per predecessor: elide removes
      // a grouped check only when the narrow is exact by construction.
      if (CanRemove && !Mk.Group.empty() && Pol == P_Elide && Ex != E_Always)
        CanRemove = false;
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
      Builder &B = mk(Mk.Pred->getTerminator());
      auto RewriteGroup = [&](bool Exact) {
        for (GetElementPtrInst *G : GroupG) {
          Builder &GB = mk(G);
          rewriteGuards({G}, NarrowAt(GB, Exact), Done);
        }
      };
      if (Ex == E_Always || (Pol == P_UB && Ex == E_Dynamic)) {
        if (!OnEdge.empty())
          rewriteGuards(OnEdge, NarrowAt(B, true), Done);
        RewriteGroup(true);
        removeCheck(Mk, DeadPanics);
        ++S.Removed;
      } else if (Pol == P_UB) { // Never
        if (!OnEdge.empty())
          rewriteGuards(OnEdge, NarrowAt(B, false), Done);
        RewriteGroup(false);
        removeCheck(Mk, DeadPanics);
        ++S.Removed;
      } else if (Ex == E_Dynamic) {
        Value *Bytes = BytesAt(B);
        Value *Base = BaseAt(B);
        Value *Exact = NarrowAt(B, true, Bytes, Base);
        Function *TagF = Intrinsic::getOrInsertDeclaration(
            &M, Intrinsic::cheri_cap_tag_get);
        Value *Tag = B.CreateCall(TagF, {Exact});
        // M5.0 shape: branch on the tag first; only the untagged (inexact)
        // path keeps the software check and computes the rounded narrow:
        //   Pred: br tag, Join, Slow   Slow: rounded; br cond, Join, Panic
        //   Join: cap = phi [exact, Pred], [rounded, Slow]
        // R4 (D22): the capability is a PHI, not a select on the tag, so the
        // tag is tested once (R2/R3 lowered the select to a second branch).
        auto *Br = cast<CondBrInst>(Mk.Pred->getTerminator());
        BasicBlock *P = Mk.Panic->getParent();
        BasicBlock *Slow = BasicBlock::Create(F.getContext(), "cheri.slowcheck",
                                              &F, P);
        BasicBlock *Join = Mk.Ok;
        bool NeedJoin = !SingleTagTest || Mk.Ok->getSinglePredecessor() != Mk.Pred;
        if (SingleTagTest && NeedJoin) {
          Join = BasicBlock::Create(F.getContext(), "cheri.twoversion", &F,
                                    Mk.Ok);
          UncondBrInst::Create(Mk.Ok, Join);
          for (PHINode &PN : Mk.Ok->phis())
            PN.replaceIncomingBlockWith(Mk.Pred, Join);
        }
        Br->removeFromParent();
        Br->insertInto(Slow, Slow->end());
        if (Join != Mk.Ok)
          for (unsigned K = 0; K < 2; ++K)
            if (Br->getSuccessor(K) == Mk.Ok)
              Br->setSuccessor(K, Join);
        CondBrInst::Create(Tag, Join, Slow, Mk.Pred);
        for (PHINode &PN : P->phis())
          PN.replaceIncomingBlockWith(Mk.Pred, Slow);
        if (SingleTagTest) {
          if (Join == Mk.Ok)
            for (PHINode &PN : Mk.Ok->phis())
              PN.addIncoming(PN.getIncomingValueForBlock(Mk.Pred), Slow);
          Value *Rounded = NarrowAt(mk(Br), false, Bytes, Base);
          PHINode *Cap = PHINode::Create(Exact->getType(), 2, "cheri.cap",
                                         Join->begin());
          Cap->addIncoming(Exact, Mk.Pred);
          Cap->addIncoming(Rounded, Slow);
          rewriteGuards(OnEdge, Cap, Done);
        } else {
          Value *Rounded = NarrowAt(B, false, Bytes, Base);
          Value *Cap = B.CreateSelect(Tag, Exact, Rounded);
          rewriteGuards(OnEdge, Cap, Done);
          for (PHINode &PN : Mk.Ok->phis())
            PN.addIncoming(PN.getIncomingValueForBlock(Mk.Pred), Slow);
        }
        if (LI.getLoopFor(Mk.Pred))
          ++S.TwoVersionInLoop;
        ++S.TwoVersion;
      } else { // elide, Never: rounded narrow, keep the check
        NarrowKeep(false);
        ++S.Kept;
      }
    }
    SmallPtrSet<BasicBlock *, 4> Gone; // R4: split markers share a panic block
    for (BasicBlock *BB : DeadPanics)
      if (Gone.insert(BB).second && pred_empty(BB))
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
    SmallVector<CallBase *, 8> ToNarrow;
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
      ToNarrow.push_back(C);
    }
    SmallPtrSet<CallBase *, 8> DoneC;
    if (ClaimCoalesce)
      coalesceClaims(ToNarrow, DoneC);
    for (CallBase *C : ToNarrow) {
      if (DoneC.count(C))
        continue;
      Value *P = C->getArgOperand(0);
      Builder &B = mk(C);
      Value *Bytes = C->getArgOperand(1);
      if (Bytes->getType() != B.getInt64Ty())
        Bytes = B.CreateZExtOrTrunc(Bytes, B.getInt64Ty());
      NarrowTag = claimTag(C);
      Value *N = narrow(B, P, Bytes, false);
      if (N != P)
        ClaimOrig[C] = P;
      // The claim stays (its operand becomes the narrow) so the census and
      // stripAnnotations treat it as before; strip replaces it with N.
      C->setArgOperand(0, N);
      ++S.ClaimNarrowed;
    }
  }

  // R3 (D20): claims of constant size on one base (constant offsets) in the
  // same block with the same flags share narrows:
  //  * claims whose result is only used as the address of loads/stores that
  //    fit in the claimed bytes ("access-only", e.g. a fully unrolled store
  //    loop) and whose ranges form one contiguous extent share one narrow of
  //    the union: such an access is in bounds of either capability, so the
  //    wider bounds are not observable (no capability escapes);
  //  * any other claims share a narrow only with identical (offset, bytes)
  //    claims, so a capability that escapes keeps exactly its claimed bounds
  //    (tests/ui/cheri/qemu/export-entry-bounds.rs: a 32 B and a 64 B claim on
  //    one base must not both become 64 B).
  bool accessOnly(CallBase *C, uint64_t Bytes) {
    for (User *U : C->users()) {
      Type *Ty = nullptr;
      if (auto *LI = dyn_cast<LoadInst>(U))
        Ty = LI->getType();
      else if (auto *SI = dyn_cast<StoreInst>(U)) {
        if (SI->getValueOperand() == C)
          return false;
        Ty = SI->getValueOperand()->getType();
      } else
        return false;
      if (!Ty->isSized() || DL.getTypeStoreSize(Ty).isScalable() ||
          DL.getTypeStoreSize(Ty).getFixedValue() > Bytes)
        return false;
    }
    return true;
  }

  struct CItem { CallBase *C; int64_t Off; uint64_t Bytes; };

  // One narrow of [Lo, Hi) of Base before the first of Items; each claim
  // becomes an offset into it.
  void shareNarrow(Value *Base, ArrayRef<CItem> Items, int64_t Lo, int64_t Hi,
                   SmallPtrSetImpl<CallBase *> &DoneC) {
    CallBase *First = Items.front().C;
    for (const CItem &It : Items)
      if (It.C->comesBefore(First))
        First = It.C;
    if (auto *BI = dyn_cast<Instruction>(Base))
      if (BI->getParent() == First->getParent() && !BI->comesBefore(First))
        return;
    Builder &B = mk(First);
    NarrowTag = claimTag(First);
    Value *Start = Lo ? B.CreateGEP(B.getInt8Ty(), Base, B.getInt64(Lo)) : Base;
    Value *N = narrow(B, Start, B.getInt64(Hi - Lo), false);
    for (const CItem &It : Items) {
      Builder &CB = mk(It.C);
      Value *P = It.Off == Lo ? N
                              : CB.CreateGEP(CB.getInt8Ty(), N,
                                             CB.getInt64(It.Off - Lo));
      ClaimOrig[It.C] = It.C->getArgOperand(0);
      It.C->setArgOperand(0, P);
      DoneC.insert(It.C);
      ++S.ClaimNarrowed;
      ++S.ClaimCoalesced;
    }
    ++S.CoalesceGroups;
  }

  void coalesceClaims(ArrayRef<CallBase *> Cs, SmallPtrSetImpl<CallBase *> &DoneC) {
    MapVector<std::tuple<BasicBlock *, Value *, uint64_t>, SmallVector<CItem, 4>> G;
    for (CallBase *C : Cs) {
      auto *BC = dyn_cast<ConstantInt>(C->getArgOperand(1));
      auto *FC = dyn_cast<ConstantInt>(C->getArgOperand(2));
      if (!BC || !FC || BC->isZero() || BC->getValue().getActiveBits() > 32)
        continue;
      int64_t Off = 0;
      Value *Base = GetPointerBaseWithConstantOffset(C->getArgOperand(0), Off, DL);
      if (!Base || !DL.isFatPointer(Base->getType()))
        continue;
      G[{C->getParent(), Base, FC->getZExtValue()}].push_back(
          {C, Off, BC->getZExtValue()});
    }
    for (auto &[Key, Items] : G) {
      if (Items.size() < 2)
        continue;
      Value *Base = std::get<1>(Key);
      SmallVector<CItem, 4> Acc;
      MapVector<std::pair<int64_t, uint64_t>, SmallVector<CItem, 2>> Same;
      for (const CItem &It : Items) {
        if (accessOnly(It.C, It.Bytes))
          Acc.push_back(It);
        else
          Same[{It.Off, It.Bytes}].push_back(It);
      }
      if (Acc.size() >= 2) {
        SmallVector<CItem, 4> Sorted(Acc);
        llvm::sort(Sorted,
                   [](const CItem &A, const CItem &B) { return A.Off < B.Off; });
        int64_t Lo = Sorted.front().Off, Hi = Lo;
        bool Contig = true;
        for (const CItem &It : Sorted) {
          if (It.Off > Hi) {
            Contig = false;
            break;
          }
          Hi = std::max<int64_t>(Hi, It.Off + (int64_t)It.Bytes);
        }
        if (Contig && Hi - Lo <= (1 << 20))
          shareNarrow(Base, Acc, Lo, Hi, DoneC);
        else
          for (const CItem &It : Acc)
            Same[{It.Off, It.Bytes}].push_back(It);
      } else {
        for (const CItem &It : Acc)
          Same[{It.Off, It.Bytes}].push_back(It);
      }
      for (auto &[R, Its] : Same)
        if (Its.size() >= 2)
          shareNarrow(Base, Its, R.first, R.first + (int64_t)R.second, DoneC);
    }
  }

  // Place this pass's own narrows the way the generic passes placed M5.0's
  // early narrows: hoist loop-invariant ones to the preheader (csetbounds
  // does not trap, so this is safe) and reuse a dominating identical one.
  void placeNarrows(Function &F) {
    if (Created.empty())
      return;
    DominatorTree DT(F);
    LoopInfo LI(DT);
    for (Instruction *I : Created) {
      while (Loop *L = LI.getLoopFor(I->getParent())) {
        BasicBlock *PH = L->getLoopPreheader();
        if (!PH || !L->hasLoopInvariantOperands(I))
          break;
        I->moveBefore(PH->getTerminator()->getIterator());
        ++S.Hoisted;
      }
    }
    SmallPtrSet<Instruction *, 32> Mine(llvm::from_range, Created);
    DenseMap<std::pair<Value *, std::pair<Value *, Value *>>,
             SmallVector<CallInst *, 2>> Seen;
    SmallVector<Instruction *, 8> Dead;
    DT.recalculate(F);
    ReversePostOrderTraversal<Function *> RPOT(&F);
    // R4: identical integer arithmetic this pass made (len * esz) first, so
    // the narrows that use it compare equal below.
    DenseMap<std::tuple<unsigned, Value *, Value *>, SmallVector<Instruction *, 2>> SeenBO;
    for (BasicBlock *BB : RPOT)
      for (Instruction &I : *BB) {
        auto *BO = dyn_cast<BinaryOperator>(&I);
        if (!BO || !Mine.count(BO))
          continue;
        auto &Bucket = SeenBO[{BO->getOpcode(), BO->getOperand(0), BO->getOperand(1)}];
        bool Replaced = false;
        for (Instruction *P : Bucket)
          if (DT.dominates(P, BO)) {
            BO->replaceAllUsesWith(P);
            Dead.push_back(BO);
            Replaced = true;
            break;
          }
        if (!Replaced)
          Bucket.push_back(BO);
      }
    for (BasicBlock *BB : RPOT)
      for (Instruction &I : *BB) {
        auto *CI = dyn_cast<CallInst>(&I);
        if (!CI || !Mine.count(CI) || CI->arg_size() != 2)
          continue;
        auto &Bucket = Seen[{CI->getCalledOperand(),
                             {CI->getArgOperand(0), CI->getArgOperand(1)}}];
        bool Replaced = false;
        for (CallInst *P : Bucket)
          if (DT.dominates(P, CI)) {
            CI->replaceAllUsesWith(P);
            Dead.push_back(CI);
            ++S.CSEd;
            Replaced = true;
            break;
          }
        if (!Replaced)
          Bucket.push_back(CI);
      }
    for (Instruction *I : Dead)
      I->eraseFromParent();
    Created.clear();
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
      ClaimOrig.clear();
      collectFacts(F);
      // R3: claims first, so a check narrow of a claimed value to the same
      // bytes sees the claim's narrow and is not repeated (k5_sub_index).
      NarrowTag = "cheri.contract_narrow";
      if (ClaimNarrow)
        runClaims(F);
      NarrowTag = "cheri.access_narrow";
      if (Pol != P_Off)
        runChecks(F);
      NarrowTag = nullptr;
      placeNarrows(F);
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
           << " twoversion=" << S.TwoVersion
           << " twoversion_loop=" << S.TwoVersionInLoop
           << " split=" << S.SplitMarkers << " adopted=" << S.Adopted << " borrow_deref=" << S.BorrowDeref << " noedge=" << S.NoEdge
           << " kept=" << S.Kept << " hoisted=" << S.Hoisted
           << " csed=" << S.CSEd << " already=" << S.AlreadyNarrow
           << " uncovered=" << S.Uncovered << " relinked=" << S.Relinked
           << " relink_markers=" << S.RelinkGuards
           << " parent_first=" << S.ParentFirst
           << " recovered=" << S.Recovered
           << " recovered_markers=" << S.RecoveredMarkers << " claims=" << S.Claims
           << " claim_narrowed=" << S.ClaimNarrowed
           << " claim_verified=" << S.ClaimVerified
           << " claim_proof=" << S.ClaimProof
           << " claim_coalesced=" << S.ClaimCoalesced
           << " coalesce_groups=" << S.CoalesceGroups << "\n";
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
  runCheriInvalidate(M); // R4 Track B (off by default), before the strip
  stripAnnotations(M);
  return true;
}
