//===- MemAnnotCensus.cpp - M5r annotation census and late stub -----------===//
// [LLM-generated] CHERI M5r R0/R1. See MemAnnotCensus.h.
#include "llvm/Transforms/Utils/MemAnnotCensus.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/DepthFirstIterator.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/MemAnnot.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Local.h"
#include <map>
#include <set>
#include <memory>
#include <mutex>

using namespace llvm;

static cl::opt<bool> CensusAtStart(
    "mem-annot-census", cl::init(false), cl::Hidden,
    cl::desc("M5r: run the memory-annotation census at pipeline start (the "
             "late census runs in CheriBoundsLowering)"));
static cl::opt<bool> CensusStrict(
    "mem-annot-census-strict", cl::init(false), cl::Hidden,
    cl::desc("M5r: fatal error on an unexplained loss of a mem.check, "
             "mem.claim or mem.free annotation"));
static cl::opt<std::string> CensusOut(
    "mem-annot-census-out", cl::init(""), cl::Hidden,
    cl::desc("M5r: append census lines to this file instead of stderr"));
static cl::opt<bool> CensusVerbose(
    "mem-annot-census-verbose", cl::init(false), cl::Hidden,
    cl::desc("M5r: also print a census line for modules without "
             "annotations"));

static cl::opt<bool> CensusPerPass(
    "mem-annot-census-per-pass", cl::init(false), cl::Hidden,
    cl::desc("M5r: attribute annotation count changes to the passes that "
             "made them (reported with the late census)"));

static cl::opt<bool> CensusTestErase(
    "mem-annot-census-test-erase", cl::init(false), cl::Hidden,
    cl::desc("M5r (testing only): after the start census, fold the first "
             "llvm.mem.claim into its operand to simulate a pass that loses "
             "it"));

bool memannot::censusAtPipelineStart() { return CensusAtStart; }
bool memannot::censusPerPass() { return CensusPerPass; }

namespace {
constexpr unsigned NumCensusKindsLocal = 8;
enum Kind : unsigned {
  K_Check, K_Guard, K_Claim, K_AllocInbounds, K_Inbounds, K_Free,
  K_LastUse, K_Dropped, K_NumKinds
};
const char *KindName[K_NumKinds] = {"check",    "guard",  "claim",
                                    "alloc_inbounds", "inbounds", "free",
                                    "last_use", "dropped"};
// Kinds counted only (fail-safe hints; cloning may add some).
bool isHintKind(unsigned K) { return K == K_Guard || K == K_LastUse; }

bool kindFromTag(StringRef T, Kind &K) {
  if (T == memannot::TagAllocInbounds) K = K_AllocInbounds;
  else if (T == memannot::TagInbounds) K = K_Inbounds;
  else if (T == memannot::TagDropped) K = K_Dropped;
  else return false;
  return true;
}

// Watches a claim: a RAUW to a non-claim value means a pass folded the claim
// into its operand (a real loss); deletion without RAUW means it was unused.
static thread_local std::string CurrentPass;

struct ClaimVH final : CallbackVH {
  bool FoldedAway = false;
  std::string FoldInfo;
  bool ObjectExact = false;
  explicit ClaimVH(Value *V) : CallbackVH(V) {}
  void allUsesReplacedWith(Value *New) override {
    auto *Old = dyn_cast_or_null<Instruction>(getValPtr());
    if (Old && Old->getMetadata(memannot::ObjectExactMD))
      ObjectExact = true;
    else if (!memannot::isMemClaim(New) && !isa<PoisonValue>(New) &&
             !isa<UndefValue>(New)) {
      FoldedAway = true;
      std::string K = isa<Instruction>(New)
                          ? cast<Instruction>(New)->getOpcodeName()
                          : isa<Argument>(New) ? "argument" : "constant";
      FoldInfo = (CurrentPass.empty() ? std::string("?") : CurrentPass) +
                 " -> " + K;
    }
    setValPtr(New);
  }
  void deleted() override { setValPtr(nullptr); }
};

struct Entry {
  Kind K;
  WeakVH BB;
  std::string Fn;
  std::optional<uint64_t> Site; // "mem.check" site (merge-robust identity)
};

// Constant sites reachable through PHIs/selects (merged failure calls).
void collectSites(Value *V, DenseSet<uint64_t> &Out,
                  SmallPtrSetImpl<Value *> &Visited) {
  if (!Visited.insert(V).second)
    return;
  if (auto *C = dyn_cast<ConstantInt>(V)) {
    Out.insert(C->getZExtValue());
  } else if (auto *P = dyn_cast<PHINode>(V)) {
    for (Value *In : P->incoming_values())
      collectSites(In, Out, Visited);
  } else if (auto *Sel = dyn_cast<SelectInst>(V)) {
    collectSites(Sel->getTrueValue(), Out, Visited);
    collectSites(Sel->getFalseValue(), Out, Visited);
  }
}

std::optional<uint64_t> constSite(const CallBase &CB) {
  if (auto OB = CB.getOperandBundle(memannot::TagCheck))
    if (OB->Inputs.size() >= 4)
      if (auto *C = dyn_cast<ConstantInt>(OB->Inputs[3]))
        return C->getZExtValue();
  return std::nullopt;
}

// [LLM-generated] M5r R3 (D18): watches one !mem.last_use carrier so the
// late census can say why a loan id vanished: its carrier accessed a stack
// slot that was promoted to SSA (nothing left in memory to invalidate), the
// carrier was deleted for another reason, or the metadata was dropped.
// R5: loan ids are counted by their original id (the LLVM inliner re-keys a
// cloned body's ids in the high bits, D35).
static Metadata *loanKey(Metadata *M) {
  // Packed and extended copies share the census key: the low 42 bits.
  // Which copy a last-use clears is the full id, not this key.
  // decodeLoanRef rejects a bare !{i64, i64}, so a multi-loan list is not
  // folded into the first integer.
  memannot::LoanRef R;
  if (!memannot::decodeLoanRef(M, R))
    return M;
  const ConstantInt *TySrc = mdconst::dyn_extract_or_null<ConstantInt>(M);
  if (!TySrc)
    if (auto *N = dyn_cast<MDNode>(M))
      TySrc = mdconst::dyn_extract_or_null<ConstantInt>(N->getOperand(1));
  if (!TySrc)
    return M;
  return ConstantAsMetadata::get(
      ConstantInt::get(TySrc->getType(), R.Orig & memannot::LoanKeyMask));
}

struct LUWatch final : CallbackVH {
  SmallVector<Metadata *, 2> Loans;
  WeakVH Alloca; // underlying alloca of a load/store carrier
  bool AllocaAccess = false;
  bool Deleted = false;
  std::string DelPass; // R7 (D50): the pass that deleted the carrier
  explicit LUWatch(Instruction *I, MDNode *LU) : CallbackVH(I) {
    for (const MDOperand &Op : LU->operands())
      Loans.push_back(loanKey(Op.get()));
    if (Value *P = getLoadStorePointerOperand(I))
      if (auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(P))) {
        Alloca = A;
        AllocaAccess = true;
      }
  }
  void deleted() override {
    Deleted = true;
    DelPass = CurrentPass.empty() ? std::string("?") : CurrentPass;
    setValPtr(nullptr);
  }
  void allUsesReplacedWith(Value *) override {}
};

struct State {
  std::map<uint64_t, Entry> Entries; // id -> entry
  DenseMap<const Instruction *, std::unique_ptr<LUWatch>> LUWatches;
  std::vector<std::unique_ptr<LUWatch>> LURetired;
  void watch(Instruction &I) {
    MDNode *LU = I.getMetadata(memannot::LastUseMD);
    if (!LU)
      return;
    auto &W = LUWatches[&I];
    if (W && static_cast<Value *>(*W) == &I)
      return;
    if (W)
      LURetired.push_back(std::move(W));
    W = std::make_unique<LUWatch>(&I, LU);
  }
  std::map<uint64_t, std::unique_ptr<ClaimVH>> Claims; // id -> watcher
  uint64_t NextId = 1;
  unsigned Start[K_NumKinds] = {};
  DenseSet<uint64_t> Redundant;      // fact ids erased as redundant
  StringMap<unsigned> CheckCallees; // callee -> calls with mem.check at start
  StringMap<unsigned> PlainCallees; // callee -> calls without at start
};

std::mutex &stateLock() {
  static std::mutex L;
  return L;
}
DenseMap<const Module *, std::unique_ptr<State>> &states() {
  static DenseMap<const Module *, std::unique_ptr<State>> S;
  return S;
}

// The fact kind of an llvm.mem.fact call (one bundle by verifier rule).
bool factKind(const IntrinsicInst *II, Kind &K) {
  if (II->getNumOperandBundles() == 0)
    return false;
  return kindFromTag(II->getOperandBundleAt(0).getTagName(), K);
}

std::optional<uint64_t> getId(const Instruction &I) {
  if (MDNode *N = I.getMetadata(memannot::IdMD))
    if (N->getNumOperands() == 1)
      if (auto *C = mdconst::dyn_extract_or_null<ConstantInt>(N->getOperand(0)))
        return C->getZExtValue();
  return std::nullopt;
}

StringRef calleeName(const CallBase &CB) {
  if (const Function *F = CB.getCalledFunction())
    return F->getName();
  return "<indirect>";
}

raw_ostream &out(std::unique_ptr<raw_fd_ostream> &Holder) {
  if (CensusOut.empty())
    return errs();
  std::error_code EC;
  Holder = std::make_unique<raw_fd_ostream>(CensusOut, EC,
                                            sys::fs::OF_Append);
  if (EC)
    return errs();
  return *Holder;
}
} // namespace

bool memannot::runCensusStart(Module &M) {
  std::lock_guard<std::mutex> G(stateLock());
  auto &SP = states()[&M];
  SP = std::make_unique<State>();
  State &S = *SP;
  LLVMContext &Ctx = M.getContext();
  Type *I64 = Type::getInt64Ty(Ctx);
  bool Changed = false;
  auto Tag = [&](Instruction &I, Kind K) {
    uint64_t Id = S.NextId++;
    I.setMetadata(memannot::IdMD,
                  MDNode::get(Ctx, ConstantAsMetadata::get(
                                       ConstantInt::get(I64, Id))));
    std::optional<uint64_t> Site;
    if (K == K_Check)
      Site = constSite(cast<CallBase>(I));
    if (K == K_Claim)
      S.Claims[Id] = std::make_unique<ClaimVH>(&I);
    S.Entries[Id] = Entry{K, WeakVH(I.getParent()),
                          I.getFunction()->getName().str(), Site};
    ++S.Start[K];
    Changed = true;
  };
  // R2: last_use is counted as distinct loan ids (D16 moves ids between
  // instructions on inlining).
  DenseSet<Metadata *> StartLoans;
  auto CountLoans = [](Instruction &I, DenseSet<Metadata *> &Set) {
    if (MDNode *LU = I.getMetadata(memannot::LastUseMD))
      for (const MDOperand &Op : LU->operands())
        Set.insert(loanKey(Op.get()));
  };
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      if (I.getMetadata(memannot::GuardMD))
        ++S.Start[K_Guard];
      CountLoans(I, StartLoans);
      S.watch(I);
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      if (auto *II = dyn_cast<IntrinsicInst>(CB);
          II && II->getIntrinsicID() == Intrinsic::mem_fact) {
        Kind K;
        if (factKind(II, K))
          Tag(I, K);
        continue;
      }
      if (memannot::isMemClaim(CB)) {
        Tag(I, K_Claim);
        continue;
      }
      if (memannot::hasMemCheck(*CB)) {
        ++S.CheckCallees[calleeName(*CB)];
        Tag(I, K_Check);
        if (CB->getOperandBundle(memannot::TagFree))
          ++S.Start[K_Free]; // untracked (one id per call)
      } else if (CB->getOperandBundle(memannot::TagFree)) {
        ++S.PlainCallees[calleeName(*CB)];
        Tag(I, K_Free);
      } else {
        ++S.PlainCallees[calleeName(*CB)];
      }
    }
  S.Start[K_LastUse] = StartLoans.size();
  if (CensusTestErase)
    for (Function &F : M)
      for (Instruction &I : instructions(F))
        if (memannot::isMemClaim(&I)) {
          I.replaceAllUsesWith(cast<CallBase>(I).getArgOperand(0));
          I.eraseFromParent();
          return true;
        }
  return Changed;
}

// [LLM-generated] M5r R1: per-pass attribution of annotation count changes.
namespace {
struct PassDelta {
  unsigned Lost[NumCensusKindsLocal] = {};
  unsigned Gained[NumCensusKindsLocal] = {};
};
std::map<const Module *, std::map<std::string, PassDelta>> &passDeltas() {
  static std::map<const Module *, std::map<std::string, PassDelta>> D;
  return D;
}
} // namespace
static void reportPassDeltas(Module &M, raw_ostream &OS);
static void runCensusLateImpl(Module &M) {
  std::lock_guard<std::mutex> G(stateLock());
  std::unique_ptr<State> SP;
  auto It = states().find(&M);
  if (It != states().end()) {
    SP = std::move(It->second);
    states().erase(It);
  }
  unsigned Late[K_NumKinds] = {}, NoId[K_NumKinds] = {};
  DenseMap<uint64_t, unsigned> Seen;      // id -> copies
  DenseMap<uint64_t, bool> SeenDropped;   // id -> seen as mem.dropped
  DenseSet<uint64_t> SeenSites;           // "mem.check" sites still present
  unsigned Stripped = 0;                  // checked-callee calls w/o bundle
  DenseSet<Metadata *> LateLoans;
  DenseSet<Metadata *> LateSlotLoans; // R7 (D50): loans of slots still in memory
  DenseMap<Metadata *, std::string> SlotLoanFn; // R8: function of the slot
  unsigned LoanKindID = M.getContext().getMDKindID(memannot::LoanMD);
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      if (MDNode *LN = I.getMetadata(LoanKindID))
        for (const MDOperand &Op : LN->operands()) {
          LateSlotLoans.insert(loanKey(Op.get()));
          SlotLoanFn.try_emplace(loanKey(Op.get()), F.getName().str());
        }
      if (I.getMetadata(memannot::GuardMD))
        ++Late[K_Guard];
      if (MDNode *LU = I.getMetadata(memannot::LastUseMD))
        for (const MDOperand &Op : LU->operands())
          LateLoans.insert(loanKey(Op.get()));
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      Kind K;
      bool IsAnnot = false;
      if (auto *II = dyn_cast<IntrinsicInst>(CB);
          II && II->getIntrinsicID() == Intrinsic::mem_fact) {
        if (!factKind(II, K))
          continue;
        IsAnnot = true;
      } else if (memannot::isMemClaim(CB)) {
        K = K_Claim;
        IsAnnot = true;
      } else if (memannot::hasMemCheck(*CB)) {
        K = K_Check;
        IsAnnot = true;
        SmallPtrSet<Value *, 8> Visited;
        collectSites(CB->getOperandBundle(memannot::TagCheck)->Inputs[3],
                     SeenSites, Visited);
        if (CB->getOperandBundle(memannot::TagFree))
          ++Late[K_Free];
      } else if (CB->getOperandBundle(memannot::TagFree)) {
        K = K_Free;
        IsAnnot = true;
      } else if (SP && SP->CheckCallees.count(calleeName(*CB)) &&
                 !SP->PlainCallees.count(calleeName(*CB))) {
        ++Stripped;
      }
      if (!IsAnnot)
        continue;
      ++Late[K];
      if (auto Id = getId(I)) {
        ++Seen[*Id];
        if (K == K_Dropped)
          SeenDropped[*Id] = true;
      } else {
        ++NoId[K];
      }
    }

  Late[K_LastUse] = LateLoans.size();
  unsigned Total = 0;
  for (unsigned K = 0; K < K_NumKinds; ++K)
    Total += Late[K] + (SP ? SP->Start[K] : 0);
  if (!CensusVerbose && Total == 0) {
    passDeltas().erase(&M);
    return;
  }

  std::unique_ptr<raw_fd_ostream> Holder;
  raw_ostream &OS = out(Holder);
  auto Line = [&](const char *What, unsigned *V) {
    OS << "mem-annot-census: " << M.getModuleIdentifier() << " " << What
       << ":";
    for (unsigned K = 0; K < K_NumKinds; ++K)
      OS << " " << KindName[K] << "=" << V[K];
    OS << "\n";
  };
  if (!SP) {
    // No start census in this process (e.g. plain llc): only report when
    // the census was requested.
    if (CensusAtStart || CensusVerbose)
      Line("late(no-start)", Late);
    return;
  }
  Line("start", SP->Start);
  Line("late", Late);
  reportPassDeltas(M, OS);

  // Classify the losses.
  enum { R_BlockDeleted, R_Unreachable, R_Dropped, R_Dead, R_IdStripped,
         R_ObjectExact, R_Redundant, R_Unexplained, R_Num };
  const char *RName[R_Num] = {"block-deleted", "unreachable-block", "dropped",
                              "dead",          "id-stripped",       "object-exact",
                              "redundant",     "unexplained"};
  unsigned Lost[K_NumKinds][R_Num] = {};
  DenseMap<const Function *, SmallPtrSet<const BasicBlock *, 32>> Reach;
  auto Reachable = [&](BasicBlock *BB) {
    Function *F = BB->getParent();
    if (!F)
      return false;
    auto [RI, New] = Reach.try_emplace(F);
    if (New)
      for (BasicBlock *R : depth_first(&F->getEntryBlock()))
        RI->second.insert(R);
    return RI->second.count(BB) != 0;
  };
  std::vector<std::string> Unexplained;
  for (auto &[Id, E] : SP->Entries) {
    if (SeenDropped.count(Id)) {
      ++Lost[E.K][R_Dropped];
      continue;
    }
    if (Seen.count(Id))
      continue;
    if (E.Site && SeenSites.count(*E.Site))
      continue; // merged into another failure call (site PHI) or id dropped
    BasicBlock *BB = cast_or_null<BasicBlock>((Value *)E.BB);
    unsigned R;
    ClaimVH *CV = nullptr;
    if (E.K == K_Claim) {
      auto CI = SP->Claims.find(Id);
      if (CI != SP->Claims.end())
        CV = CI->second.get();
    }
    if (SP->Redundant.count(Id)) {
      R = R_Redundant;
    } else if (CV && CV->ObjectExact) {
      R = R_ObjectExact;
    } else if (CV && CV->FoldedAway) {
      R = R_Unexplained;
      Unexplained.push_back("claim #" + std::to_string(Id) + " in " + E.Fn +
                            " (folded into a non-claim value: " + CV->FoldInfo + ")");
    } else if (!BB || !BB->getParent())
      R = R_BlockDeleted;
    else if (!Reachable(BB))
      R = R_Unreachable;
    else if (NoId[E.K]) {
      --NoId[E.K];
      R = R_IdStripped;
    } else if (E.K == K_Claim) {
      R = R_Dead; // deleted while unused (trivially dead)
    } else {
      R = R_Unexplained;
      Unexplained.push_back(std::string(KindName[E.K]) + " #" +
                            std::to_string(Id) + " in " + E.Fn);
    }
    ++Lost[E.K][R];
  }
  // R3 (D18): why each lost loan id vanished.
  unsigned LUPromoted = 0, LUCarrierDeleted = 0, LUDropped = 0;
  // R7 (D50): the same for loans whose slot survived (Track B can clear it).
  unsigned SLWith = 0, SLPromoted = 0, SLDeleted = 0, SLDropped = 0, SLNone = 0;
  std::map<std::string, unsigned> SLByPass;
  std::vector<std::string> SLLostInfo;
  {
    DenseMap<Metadata *, SmallVector<LUWatch *, 2>> ByLoan;
    auto Add = [&](LUWatch *W) {
      for (Metadata *L : W->Loans)
        ByLoan[L].push_back(W);
    };
    for (auto &[I, W] : SP->LUWatches)
      Add(W.get());
    for (auto &W : SP->LURetired)
      Add(W.get());
    for (Metadata *L : LateSlotLoans) {
      if (LateLoans.count(L)) {
        ++SLWith;
        continue;
      }
      auto BI = ByLoan.find(L);
      if (BI == ByLoan.end()) {
        ++SLNone;
        if (CensusVerbose)
          SLLostInfo.push_back(
              std::to_string(mdconst::extract<ConstantInt>(L)->getZExtValue()) +
              " none-at-start");
        continue;
      }
      bool Promoted = false, AllDeleted = true;
      std::set<std::string> Ps;
      for (LUWatch *W : BI->second) {
        Promoted |= W->Deleted && W->AllocaAccess && !W->Alloca;
        AllDeleted &= W->Deleted;
        if (W->Deleted)
          Ps.insert(W->DelPass);
      }
      if (CensusVerbose) {
        std::string Why = Promoted ? "promoted" : AllDeleted ? "carrier-deleted" : "md-dropped";
        for (const std::string &P : Ps)
          Why += " " + P;
        SLLostInfo.push_back(std::to_string(
            mdconst::extract<ConstantInt>(L)->getZExtValue()) + " " + Why);
      }
      if (Promoted)
        ++SLPromoted;
      else if (AllDeleted) {
        ++SLDeleted;
        for (const std::string &P : Ps)
          ++SLByPass[P];
      } else
        ++SLDropped;
    }
    for (auto &[L, Ws] : ByLoan) {
      if (LateLoans.count(L))
        continue;
      bool Promoted = false, AllDeleted = true;
      for (LUWatch *W : Ws) {
        Promoted |= W->Deleted && W->AllocaAccess && !W->Alloca;
        AllDeleted &= W->Deleted;
      }
      if (Promoted)
        ++LUPromoted;
      else if (AllDeleted)
        ++LUCarrierDeleted;
      else
        ++LUDropped;
    }
  }
  std::string LostStr;
  raw_string_ostream LOS(LostStr);
  for (unsigned K = 0; K < K_NumKinds; ++K) {
    if (K == K_LastUse) {
      unsigned S = SP->Start[K], L = Late[K];
      if (S > L || LUPromoted || LUCarrierDeleted || LUDropped)
        LOS << " last_use=" << (S > L ? S - L : 0) << "(fail-safe:promoted="
            << LUPromoted << ",carrier-deleted=" << LUCarrierDeleted
            << ",md-dropped=" << LUDropped << ")";
      continue;
    }
    if (isHintKind(K)) {
      // Hints are not tracked individually (cloning may add some); a net
      // decrease is reported as fail-safe.
      unsigned S = SP->Start[K], L = Late[K];
      if (S > L)
        LOS << " " << KindName[K] << "=" << (S - L) << "(fail-safe)";
      continue;
    }
    unsigned Sum = 0;
    for (unsigned R = 0; R < R_Num; ++R)
      Sum += Lost[K][R];
    if (!Sum)
      continue;
    LOS << " " << KindName[K] << "=" << Sum << "(";
    bool First = true;
    for (unsigned R = 0; R < R_Num; ++R)
      if (Lost[K][R]) {
        LOS << (First ? "" : ",") << RName[R] << "=" << Lost[K][R];
        First = false;
      }
    LOS << ")";
  }
  if (Stripped)
    LOS << " check-bundle-stripped=" << Stripped;
  LOS.flush();
  // R7 (D51): survival over the ids that can still be used (promoted slots
  // have nothing left in memory, so they leave the starting set).
  {
    unsigned S = SP->Start[K_LastUse], L = Late[K_LastUse];
    OS << "mem-annot-census: " << M.getModuleIdentifier()
       << " last_use-live: start=" << (S > LUPromoted ? S - LUPromoted : 0)
       << " late=" << L << " promoted=" << LUPromoted << "\n";
    OS << "mem-annot-census: " << M.getModuleIdentifier()
       << " slot-loans: live=" << LateSlotLoans.size() << " with_carrier=" << SLWith
       << " lost(promoted=" << SLPromoted << ",carrier-deleted=" << SLDeleted
       << ",md-dropped=" << SLDropped << ",none-at-start=" << SLNone << ")";
    for (auto &[P, N] : SLByPass)
      OS << " " << P << "=" << N;
    OS << "\n";
    for (const std::string &X : SLLostInfo)
      OS << "mem-annot-census: slot-loan lost: " << X << "\n";
    if (CensusVerbose)
      for (Metadata *L : LateSlotLoans)
        OS << "mem-annot-census: slot-loan fn: "
           << mdconst::extract<ConstantInt>(L)->getZExtValue() << " "
           << SlotLoanFn.lookup(L) << " "
           << (LateLoans.count(L) ? "carrier" : "lost") << "\n";
  }
  OS << "mem-annot-census: " << M.getModuleIdentifier() << " lost:"
     << (LostStr.empty() ? std::string(" none") : LostStr) << "\n";
  for (const std::string &U : Unexplained)
    OS << "mem-annot-census: unexplained loss: " << U << "\n";
  OS.flush();

  bool Fatal = Stripped != 0;
  for (unsigned K : {K_Check, K_Claim, K_Free})
    Fatal |= Lost[K][R_Unexplained] != 0;
  if (CensusStrict && Fatal)
    report_fatal_error("mem-annot-census: unexplained loss of a mem.check / "
                       "mem.claim / mem.free annotation (strict mode)");
}

void memannot::runCensusLate(Module &M) {
  runCensusLateImpl(M);
  // The census ids are only meaningful between the two census points.
  for (Function &F : M)
    for (Instruction &I : instructions(F))
      I.setMetadata(memannot::IdMD, nullptr);
}

void memannot::noteRedundantFact(const Instruction &I) {
  auto Id = getId(I);
  if (!Id)
    return;
  std::lock_guard<std::mutex> G(stateLock());
  auto It = states().find(I.getModule());
  if (It != states().end())
    It->second->Redundant.insert(*Id);
}

bool memannot::censusActive(const Module &M) {
  std::lock_guard<std::mutex> G(stateLock());
  return states().count(&M) != 0;
}

bool memannot::stripAnnotations(Module &M) {
  bool Changed = false;
  SmallVector<Instruction *, 32> Facts;
  SmallVector<CallBase *, 32> Bundled;
  SmallVector<Instruction *, 32> Claims;
  unsigned GuardKind = M.getContext().getMDKindID(memannot::GuardMD);
  unsigned LastUseKind = M.getContext().getMDKindID(memannot::LastUseMD);
  unsigned IdKind = M.getContext().getMDKindID(memannot::IdMD);
  unsigned LoanKind = M.getContext().getMDKindID(memannot::LoanMD);
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      for (unsigned MK : {GuardKind, LastUseKind, IdKind, LoanKind})
        if (I.getMetadata(MK)) {
          I.setMetadata(MK, nullptr);
          Changed = true;
        }
      if (memannot::isMemClaim(&I)) {
        Claims.push_back(&I);
        continue;
      }
      if (memannot::isMemFact(&I)) {
        Facts.push_back(&I);
        continue;
      }
      if (auto *CB = dyn_cast<CallBase>(&I))
        for (unsigned B = 0, E = CB->getNumOperandBundles(); B != E; ++B)
          if (memannot::isMemTag(CB->getOperandBundleAt(B).getTagName())) {
            Bundled.push_back(CB);
            break;
          }
    }
  // Operands kept alive only by annotations (e.g. a GEP feeding a claim or a
  // select of merged check sites) are deleted afterwards, so ISel sees the
  // same IR as an unannotated build.
  SmallVector<WeakTrackingVH, 32> MaybeDead;
  auto NoteOps = [&](CallBase *CB, bool AllOps) {
    for (unsigned B = 0, E = CB->getNumOperandBundles(); B != E; ++B) {
      OperandBundleUse OBU = CB->getOperandBundleAt(B);
      if (AllOps || memannot::isMemTag(OBU.getTagName()))
        for (const Use &U : OBU.Inputs)
          if (isa<Instruction>(U.get()))
            MaybeDead.push_back(U.get());
    }
  };
  for (Instruction *I : Facts) {
    NoteOps(cast<CallBase>(I), true);
    I->eraseFromParent();
  }
  // A claim is the identity on its pointer: replace it with its operand.
  for (Instruction *I : Claims) {
    I->replaceAllUsesWith(cast<CallBase>(I)->getArgOperand(0));
    I->eraseFromParent();
  }
  for (CallBase *CB : Bundled) {
    SmallVector<OperandBundleDef, 2> Keep;
    for (unsigned B = 0, E = CB->getNumOperandBundles(); B != E; ++B) {
      OperandBundleUse OBU = CB->getOperandBundleAt(B);
      if (!memannot::isMemTag(OBU.getTagName()))
        Keep.emplace_back(OBU);
    }
    NoteOps(CB, false);
    CallBase *New = CallBase::Create(CB, Keep, CB->getIterator());
    New->takeName(CB);
    CB->replaceAllUsesWith(New);
    CB->eraseFromParent();
  }
  RecursivelyDeleteTriviallyDeadInstructionsPermissive(MaybeDead);
  if (Function *Decl = M.getFunction("llvm.mem.fact"))
    if (Decl->use_empty())
      Decl->eraseFromParent();
  for (Function &F : make_early_inc_range(M))
    if (F.getIntrinsicID() == Intrinsic::mem_claim && F.use_empty())
      F.eraseFromParent();
  return Changed || !Facts.empty() || !Bundled.empty() || !Claims.empty();
}

bool memannot::runCheriBoundsLoweringStub(Module &M) {
  // R0/R1: no decisions. Census, then strip so ISel is unchanged.
  runCensusLate(M);
  return stripAnnotations(M);
}

PreservedAnalyses MemAnnotCensusPass::run(Module &M, ModuleAnalysisManager &) {
  if (Late) {
    memannot::runCensusLate(M);
    return PreservedAnalyses::all();
  }
  // Metadata-only change; analyses stay valid.
  memannot::runCensusStart(M);
  return PreservedAnalyses::all();
}

PreservedAnalyses CheriBoundsLoweringPass::run(Module &M,
                                               ModuleAnalysisManager &) {
  return memannot::runCheriBoundsLowering(M) ? PreservedAnalyses::none()
                                                 : PreservedAnalyses::all();
}


void memannot::countAnnotations(const Function &F, unsigned *Out) {
  // R3 (D18): watch carriers created after the start census (D16 moves,
  // clones), so late loss reasons cover them too.
  State *St = nullptr;
  {
    std::lock_guard<std::mutex> G(stateLock());
    auto It = states().find(F.getParent());
    if (It != states().end())
      St = It->second.get();
  }
  for (const Instruction &I : instructions(F)) {
    if (I.getMetadata(memannot::GuardMD))
      ++Out[K_Guard];
    if (I.getMetadata(memannot::LastUseMD)) {
      ++Out[K_LastUse];
      if (St) {
        std::lock_guard<std::mutex> G(stateLock());
        St->watch(const_cast<Instruction &>(I));
      }
    }
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    if (auto *II = dyn_cast<IntrinsicInst>(CB);
        II && II->getIntrinsicID() == Intrinsic::mem_fact) {
      Kind K;
      if (factKind(II, K))
        ++Out[K];
      continue;
    }
    if (memannot::isMemClaim(CB))
      ++Out[K_Claim];
    if (memannot::hasMemCheck(*CB))
      ++Out[K_Check];
    if (CB->getOperandBundle(memannot::TagFree))
      ++Out[K_Free];
  }
}

void memannot::notePassDelta(const Module *M, StringRef Pass,
                             const unsigned *Before, const unsigned *After) {
  bool Any = false;
  for (unsigned K = 0; K < K_NumKinds; ++K)
    Any |= Before[K] != After[K];
  if (!Any)
    return;
  std::lock_guard<std::mutex> G(stateLock());
  PassDelta &D = passDeltas()[M][Pass.str()];
  for (unsigned K = 0; K < K_NumKinds; ++K) {
    if (After[K] < Before[K])
      D.Lost[K] += Before[K] - After[K];
    else
      D.Gained[K] += After[K] - Before[K];
  }
}

static void reportPassDeltas(Module &M, raw_ostream &OS) {
  auto It = passDeltas().find(&M);
  if (It == passDeltas().end())
    return;
  for (auto &[Pass, D] : It->second) {
    OS << "mem-annot-census-pass: " << M.getModuleIdentifier() << " " << Pass
       << ":";
    for (unsigned K = 0; K < K_NumKinds; ++K)
      if (D.Lost[K] || D.Gained[K])
        OS << " " << KindName[K] << "=-" << D.Lost[K] << "/+" << D.Gained[K];
    OS << "\n";
  }
  passDeltas().erase(It);
}

void memannot::setCurrentPass(StringRef Pass) { CurrentPass = Pass.str(); }
