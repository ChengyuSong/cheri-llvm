//===- MemAnnotCensus.cpp - M5r annotation census and late stub -----------===//
// [LLM-generated] CHERI M5r R0. See MemAnnotCensus.h.
#include "llvm/Transforms/Utils/MemAnnotCensus.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/DepthFirstIterator.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringMap.h"
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

static cl::opt<bool> CensusTestErase(
    "mem-annot-census-test-erase", cl::init(false), cl::Hidden,
    cl::desc("M5r (testing only): after the start census, erase the first "
             "mem.claim fact to simulate a pass that loses it"));

bool memannot::censusAtPipelineStart() { return CensusAtStart; }

namespace {
enum Kind : unsigned {
  K_Check, K_Guard, K_Claim, K_AllocInbounds, K_Inbounds, K_Free,
  K_Invalidate, K_Dropped, K_NumKinds
};
const char *KindName[K_NumKinds] = {"check",      "guard",  "claim",
                                    "alloc_inbounds", "inbounds", "free",
                                    "invalidate", "dropped"};

bool kindFromTag(StringRef T, Kind &K) {
  if (T == memannot::TagClaim) K = K_Claim;
  else if (T == memannot::TagAllocInbounds) K = K_AllocInbounds;
  else if (T == memannot::TagInbounds) K = K_Inbounds;
  else if (T == memannot::TagFree) K = K_Free;
  else if (T == memannot::TagInvalidate) K = K_Invalidate;
  else if (T == memannot::TagDropped) K = K_Dropped;
  else return false;
  return true;
}

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

struct State {
  std::map<uint64_t, Entry> Entries; // id -> entry
  uint64_t NextId = 1;
  unsigned Start[K_NumKinds] = {};
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
    S.Entries[Id] = Entry{K, WeakVH(I.getParent()),
                          I.getFunction()->getName().str(), Site};
    ++S.Start[K];
    Changed = true;
  };
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      if (I.getMetadata(memannot::GuardMD))
        ++S.Start[K_Guard];
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
      if (memannot::hasMemCheck(*CB)) {
        ++S.CheckCallees[calleeName(*CB)];
        Tag(I, K_Check);
      } else {
        ++S.PlainCallees[calleeName(*CB)];
      }
    }
  if (CensusTestErase)
    for (Function &F : M)
      for (Instruction &I : instructions(F))
        if (auto *II = dyn_cast<IntrinsicInst>(&I);
            II && II->getIntrinsicID() == Intrinsic::mem_fact &&
            II->getOperandBundleAt(0).getTagName() == memannot::TagClaim) {
          I.eraseFromParent();
          return true;
        }
  return Changed;
}

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
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      if (I.getMetadata(memannot::GuardMD))
        ++Late[K_Guard];
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
      } else if (memannot::hasMemCheck(*CB)) {
        K = K_Check;
        IsAnnot = true;
        SmallPtrSet<Value *, 8> Visited;
        collectSites(CB->getOperandBundle(memannot::TagCheck)->Inputs[3],
                     SeenSites, Visited);
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

  unsigned Total = 0;
  for (unsigned K = 0; K < K_NumKinds; ++K)
    Total += Late[K] + (SP ? SP->Start[K] : 0);
  if (!CensusVerbose && Total == 0)
    return;

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

  // Classify the losses.
  enum { R_BlockDeleted, R_Unreachable, R_Dropped, R_IdStripped,
         R_Unexplained, R_Num };
  const char *RName[R_Num] = {"block-deleted", "unreachable-block", "dropped",
                              "id-stripped", "unexplained"};
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
    if (!BB || !BB->getParent())
      R = R_BlockDeleted;
    else if (!Reachable(BB))
      R = R_Unreachable;
    else if (NoId[E.K]) {
      --NoId[E.K];
      R = R_IdStripped;
    } else {
      R = R_Unexplained;
      Unexplained.push_back(std::string(KindName[E.K]) + " #" +
                            std::to_string(Id) + " in " + E.Fn);
    }
    ++Lost[E.K][R];
  }
  std::string LostStr;
  raw_string_ostream LOS(LostStr);
  for (unsigned K = 0; K < K_NumKinds; ++K) {
    if (K == K_Guard) {
      // Guards are not tracked individually (cloning may add some); a net
      // decrease is reported as fail-safe.
      unsigned S = SP->Start[K], L = Late[K];
      if (S > L)
        LOS << " guard=" << (S - L) << "(fail-safe)";
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

bool memannot::stripAnnotations(Module &M) {
  bool Changed = false;
  SmallVector<Instruction *, 32> Facts;
  SmallVector<CallBase *, 32> Bundled;
  unsigned GuardKind = M.getContext().getMDKindID(memannot::GuardMD);
  unsigned IdKind = M.getContext().getMDKindID(memannot::IdMD);
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      if (I.getMetadata(GuardKind)) {
        I.setMetadata(GuardKind, nullptr);
        Changed = true;
      }
      if (I.getMetadata(IdKind)) {
        I.setMetadata(IdKind, nullptr);
        Changed = true;
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
  return Changed || !Facts.empty() || !Bundled.empty();
}

bool memannot::runCheriBoundsLoweringStub(Module &M) {
  // R0: no decisions. Census, then strip so ISel is unchanged.
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
  return memannot::runCheriBoundsLoweringStub(M) ? PreservedAnalyses::none()
                                                 : PreservedAnalyses::all();
}
