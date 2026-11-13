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
//   * M7.1a: llvm.mem.fact ["mem.move"(ptr Slot)] nulls that frame slot and
//     clears a capability register still holding the moved-from value. The
//     slot may have escaped. The free-log loop is not involved.
//   * M7.1b: llvm.mem.fact ["mem.loan_into"(ptr Slot, ptr Loan, i64 Id)] at a
//     last use of Id re-reads Slot and, when that buffer is still live,
//     nulls each 16-byte element exactly equal to Loan. The scan is a loop
//     in this function. A promoted slot keeps a "mem.loan_into.promoted"
//     marker and is counted, not scanned. Promotion that recovers the buffer
//     pointer rewrites the fact to "mem.loan_into.val"(ptr buf, ptr loan, i64 id)
//     and the scan uses that capability directly.
//   * M7.1d A: a mem.move of the owner slot no longer drops the scan when
//     the buffer is still live (clear/forget of a live Vec, or finish_grow).
//     The scan uses the still-named carrier, or the buffer capability, and
//     is off with -cheri-invalidate-loan-into-moved-live=false.
//   * M7.1d B1: a loan_into the pass would skip as skipped_freed (or
//     skipped_val_freed) instead scans the still-live buffer through the
//     ready dealloc capability immediately before mem.free, when the loan
//     is a capability. Off with -cheri-invalidate-loan-into-freed-wipe=false.
// Only capabilities into dead storage (or of an ended loan) are touched
// (fail-safe). -cheri-invalidate=none|scope|slite|free|loan|all, or a
// '+'-list. Default is loan+free+scope+aflog (M7.1c: own-slot nulls on).
//===----------------------------------------------------------------------===//
#include "llvm/ADT/DenseSet.h"
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
    "cheri-invalidate", cl::init("loan+free+scope+aflog"), cl::Hidden,
    cl::desc("M5r Track B: none, scope, slite (scope range checks without "
             "own-slot nulls, R10 D73), free, loan, flog (R10 D72 free log, "
             "opt-in), aflog (R12 D80 argument free log), "
             "loan+free+scope+aflog (default since M7.1c, own-slot nulls on; "
             "R14 D83 through M7.1b: loan+free+slite+aflog; R10-R13: "
             "loan+free+slite, which disables aflog; R9 D69: "
             "loan+free; R8 D57: loan), all, or a "
             "'+'-list (scope+free = R4 all). slite remains selectable."));
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
// [LLM-generated] M7.1c-2a. A static alloca filled by memcpy/memmove, or
// written by a capability store at a variable index, has no constant-offset
// slot, so own-null at lifetime.end never sees it. Widen it to every aligned
// word, up to a byte cap. Off is the pre-A1 slot set.
enum class WideToggle { Off, On };
static cl::opt<WideToggle> WideSlotsOpt(
    "cheri-invalidate-wide-slots", cl::init(WideToggle::On), cl::Hidden,
    cl::desc("M7.1c-2a: capability slots for memcpy/memmove destinations and "
             "variable-index capability stores into a static alloca"),
    cl::values(clEnumValN(WideToggle::Off, "off", "fixed-offset stores only"),
               clEnumValN(WideToggle::On, "on", "widen (default)")));
// [LLM-generated] M7.1c-2b. At a mem.free, null this function's live capability
// slots that no path reads again. A non-escaping slot is a plain null. An
// escaping one is a range check against the freed region. Off leaves the
// free site as it was on 978c1f75.
enum class FreeDeadToggle { Off, On };
static cl::opt<FreeDeadToggle> FreeDeadOpt(
    "cheri-invalidate-free-dead-slots", cl::init(FreeDeadToggle::On), cl::Hidden,
    cl::desc("M7.1c-2b: at mem.free, clear live alloca capability slots that "
             "are not read again"),
    cl::values(clEnumValN(FreeDeadToggle::Off, "off", "do not clear"),
               clEnumValN(FreeDeadToggle::On, "on", "clear (default)")));
// Call-site half of B1. drop_in_place / drop_glue free the owner in the
// callee, so the caller's dead slots never see an inline mem.free. Off keeps
// only the inline mem.free triggers. The main switch off disables both.
static cl::opt<FreeDeadToggle> FreeDeadCallsOpt(
    "cheri-invalidate-free-dead-calls", cl::init(FreeDeadToggle::On), cl::Hidden,
    cl::desc("M7.1c-2b: also clear dead slots after an out-of-line drop of "
             "their owner"),
    cl::values(clEnumValN(FreeDeadToggle::Off, "off", "inline mem.free only"),
               clEnumValN(FreeDeadToggle::On, "on", "drop calls too (default)")));
static cl::opt<unsigned> WideBytesOpt(
    "cheri-invalidate-wide-bytes", cl::init(512), cl::Hidden,
    cl::desc("M7.1c-2a: largest static alloca (bytes) widened into per-word "
             "nulls. 512 is 32 words. Larger allocas are skipped."));
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
// [LLM-generated] M6.0 D87, M6.1 D90. Off leaves only the slot stores. On also
// emits llvm.cheri.cap.invalidate so the capability cannot survive in a
// register (including a callee-saved one) past a loan last-use, a free, or a
// scope end. The post-RA pass nulls RA spill slots that still hold that value.
// Callee-saved save slots (the caller's incoming register) are not written.
// D89: this does not put loan ids on MMOs.
static cl::opt<bool> InvCapReg(
    "cheri-invalidate-cap-reg", cl::init(true), cl::Hidden,
    cl::desc("M6.1 D90: at a loan last-use, free, or scope end, clear the "
             "capability register (including a callee-saved one) and, after "
             "RA, spill slots that still hold it"));
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
static cl::opt<bool> InvLoanIntoMovedLive(
    "cheri-invalidate-loan-into-moved-live", cl::init(true), cl::Hidden,
    cl::desc("M7.1d A: do not skip a mem.loan_into scan after mem.move when "
             "the moved owner's buffer is still live (default on; false is "
             "byte-identical to the pre-1d-A pass)"));
static cl::opt<bool> InvLoanIntoFreedWipe(
    "cheri-invalidate-loan-into-freed-wipe", cl::init(true), cl::Hidden,
    cl::desc("M7.1d B1: wipe capability slots of a buffer a mem.loan_into "
             "would skip as freed, through the ready dealloc cap before "
             "mem.free (default on; false is byte-identical to 94303ea2)"));
static cl::opt<bool> InvFilter(
    "cheri-invalidate-filter", cl::init(true), cl::Hidden,
    cl::desc("Only range-check a slot whose stored capabilities may point "
             "into the dead object (underlying-object provenance)"));
static cl::opt<std::string> InvStatsOut(
    "cheri-invalidate-stats-out", cl::init(""), cl::Hidden,
    cl::desc("Append one line of per-module invalidation counts"));
// D96. The machine pass increments these; flushSpillInvalidateStats appends.
static unsigned SpillSearchAborts = 0;
static unsigned SpillNulls = 0;
static unsigned CapRegSkippedLive = 0;
static unsigned CapRegSkippedNoEscape = 0;
static unsigned CapRegSkippedCSR = 0;
static unsigned CapRegSkippedSoon = 0;
static unsigned CapRegSkippedEdge = 0;
static unsigned CapRegSkippedDup = 0;
void llvm::memannot::noteSpillSearchAbort() { ++SpillSearchAborts; }
void llvm::memannot::noteSpillNull() { ++SpillNulls; }
void llvm::memannot::noteCapRegSkippedLive() { ++CapRegSkippedLive; }
void llvm::memannot::noteCapRegSkippedNoEscape() { ++CapRegSkippedNoEscape; }
void llvm::memannot::noteCapRegSkippedCSR() { ++CapRegSkippedCSR; }
void llvm::memannot::noteCapRegSkippedSoonRedef() { ++CapRegSkippedSoon; }
void llvm::memannot::noteCapRegSkippedEdge() { ++CapRegSkippedEdge; }
void llvm::memannot::noteCapRegSkippedDup() { ++CapRegSkippedDup; }
void llvm::memannot::appendInvalidateStatsLine(StringRef Line) {
  if (InvStatsOut.empty() || Line.empty())
    return;
  std::error_code EC;
  raw_fd_ostream OS(InvStatsOut, EC, sys::fs::OF_Append | sys::fs::OF_Text);
  if (!EC)
    OS << Line << "\n";
}

void llvm::memannot::flushSpillInvalidateStats() {
  if (InvStatsOut.empty())
    return;
  std::error_code EC;
  raw_fd_ostream OS(InvStatsOut, EC, sys::fs::OF_Append | sys::fs::OF_Text);
  if (!EC)
    OS << "cheri-invalidate-spill: aborts=" << SpillSearchAborts
       << " nulls=" << SpillNulls
       << " capreg_skipped_live=" << CapRegSkippedLive
       << " capreg_skipped_noescape=" << CapRegSkippedNoEscape
       << " capreg_skipped_csr=" << CapRegSkippedCSR
       << " capreg_skipped_soon_redef=" << CapRegSkippedSoon
       << " capreg_skipped_edge=" << CapRegSkippedEdge
       << " capreg_skipped_dup=" << CapRegSkippedDup << "\n";
  SpillSearchAborts = 0;
  SpillNulls = 0;
  CapRegSkippedLive = 0;
  CapRegSkippedNoEscape = 0;
  CapRegSkippedCSR = 0;
  CapRegSkippedSoon = 0;
  CapRegSkippedEdge = 0;
  CapRegSkippedDup = 0;
}

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
  unsigned FLogFrees = 0, FLogCalls = 0, FLogLoops = 0;
  unsigned ScopeEvents = 0, FreeEvents = 0, OwnNulled = 0, RangeChecks = 0,
           Slots = 0, LUFrameCopies = 0, LUCarriers = 0, Filtered = 0;
  unsigned LoanFacts = 0, LoanSlots = 0, LoanClears = 0, LoanSkipped = 0, LoanEscaped = 0,
           AsmNoEscape = 0;
  // M6.1 D90: register clears emitted, by kind.
  unsigned CapRegLoan = 0, CapRegFree = 0, CapRegScope = 0;
  // M7.1a: source slots nulled at a "mem.move" fact, and facts skipped
  // because the slot may still be read after the fact.
  unsigned MoveNulls = 0, MoveNullSkippedLive = 0;
  // M7.1b: heap loans. nulls is the number of null stores emitted (one per
  // scan loop), not the number of elements a run of the loop clears.
  unsigned LoanIntoFacts = 0, LoanIntoScans = 0, LoanIntoNulls = 0;
  unsigned LoanIntoSkippedFreed = 0, LoanIntoSkippedMoved = 0;
  unsigned LoanIntoMovedLive = 0;
  unsigned LoanIntoFreedWipe = 0;
  unsigned LoanIntoSkippedPromoted = 0, LoanIntoSkippedNoval = 0;
  unsigned LoanIntoValFacts = 0, LoanIntoSkippedValFreed = 0;
  unsigned LoanIntoSkippedValReassigned = 0;
  // M7.1c-2a: words nulled only at lifetime.end. They are not CapSlots, so
  // free-log, free-site and scope range checks, and loan bookkeeping ignore
  // them. A fixed-offset store stays in CapSlots and is not repeated here.
  unsigned WideAllocas = 0, WideSkippedLarge = 0, OwnNulledWide = 0;
  // M7.1c-2b: plain nulls and range-checked clears of slots dead after a free.
  unsigned FreeDeadPlain = 0, FreeDeadChecked = 0;
  unsigned FreeDeadCallPlain = 0, FreeDeadCallChecked = 0;
  DenseMap<std::pair<AllocaInst *, int64_t>, SmallVector<Value *, 2>> SlotStored;
  // Every pointer store into an alloca, any index. Unknown if a copy or too
  // many stores hide the values. Used to see through a load from a local
  // array such as s1's %array.i.
  struct AllocaFill {
    SmallVector<Value *, 4> Vals;
    bool Unknown = false;
  };
  DenseMap<AllocaInst *, AllocaFill> Fills;
  MapVector<AllocaInst *, SmallVector<int64_t, 4>> WideByAlloca;
  struct LoanIntoScan {
    Instruction *At;
    Value *Slot; // slot address, or the buffer cap when Direct
    Value *Loan;
    bool Direct = false;
  };
  SmallVector<LoanIntoScan, 4> PendingLoanInto;
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
  // capability-typed store. memcpy/memmove destinations and variable-index
  // capability stores are recorded separately and only own-nulled.
  void addWide(AllocaInst *A,
               const MapVector<AllocaInst *, SmallVector<int64_t, 2>> &Fixed) {
    if (!A->isStaticAlloca())
      return;
    std::optional<TypeSize> Sz = A->getAllocationSize(DL);
    if (!Sz || Sz->isScalable())
      return;
    uint64_t N = Sz->getFixedValue();
    if (A->getAlign().value() < 16 || N < 16)
      return;
    if (N > WideBytesOpt) {
      ++WideSkippedLarge;
      return;
    }
    const SmallVector<int64_t, 2> *Have = nullptr;
    if (auto It = Fixed.find(A); It != Fixed.end())
      Have = &It->second;
    bool Added = false;
    auto &V = WideByAlloca[A];
    for (uint64_t Off = 0; Off + 16 <= N; Off += 16) {
      // A constant-offset store is already a normal slot. Leaving it there
      // keeps free-log and range checks identical to the fixed-offset set.
      if (Have && is_contained(*Have, (int64_t)Off))
        continue;
      if (is_contained(V, (int64_t)Off))
        continue;
      V.push_back((int64_t)Off);
      Added = true;
    }
    if (V.empty())
      WideByAlloca.erase(A);
    if (Added)
      ++WideAllocas;
  }
  void collectWide(Function &F,
                   const MapVector<AllocaInst *, SmallVector<int64_t, 2>> &Fixed) {
    if (WideSlotsOpt != WideToggle::On)
      return;
    SmallPtrSet<AllocaInst *, 8> Seen;
    auto Consider = [&](AllocaInst *A) {
      if (Seen.insert(A).second)
        addWide(A, Fixed);
    };
    for (Instruction &I : instructions(F)) {
      if (auto *MT = dyn_cast<MemTransferInst>(&I)) {
        if (auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(MT->getDest())))
          Consider(A);
        continue;
      }
      auto *SI = dyn_cast<StoreInst>(&I);
      if (!SI || !DL.isFatPointer(SI->getValueOperand()->getType()))
        continue;
      int64_t Off = 0;
      Value *Base = GetPointerBaseWithConstantOffset(SI->getPointerOperand(), Off, DL);
      if (isa<AllocaInst>(Base) && Off >= 0 && (Off % 16) == 0)
        continue;
      if (auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(SI->getPointerOperand())))
        Consider(A);
    }
  }
  void collectSlots(Function &F, MapVector<AllocaInst *, SmallVector<int64_t, 2>> &Out) {
    WideByAlloca.clear();
    SlotStored.clear();
    Fills.clear();
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
      auto &Stored = SlotStored[{A, Off}];
      if (Stored.size() < 4)
        Stored.push_back(SI->getValueOperand());
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
    collectWide(F, Out);
    for (auto &[A, Offs] : Out)
      Slots += Offs.size();
    Fills.clear();
    for (Instruction &I : instructions(F)) {
      if (auto *MT = dyn_cast<MemTransferInst>(&I)) {
        if (auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(MT->getRawDest())))
          Fills[A].Unknown = true;
        continue;
      }
      auto *SI = dyn_cast<StoreInst>(&I);
      if (!SI || !DL.isFatPointer(SI->getValueOperand()->getType()))
        continue;
      auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(SI->getPointerOperand()));
      if (!A)
        continue;
      AllocaFill &Fill = Fills[A];
      if (Fill.Vals.size() >= 32)
        Fill.Unknown = true;
      else
        Fill.Vals.push_back(SI->getValueOperand());
    }
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

  // A real read of A's stored words reachable after At, including a load
  // reached by a loop back edge. Escape alone is not a read: an address that
  // was passed to an earlier call can still be dead from here on.
  bool readAfter(AllocaInst *A, Instruction *At, DominatorTree &DT) {
    auto It = ReadAfter.find({A, At});
    if (It != ReadAfter.end())
      return It->second;
    bool R = false;
    SmallVector<const Value *, 8> WL{A};
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
        if (I != At && isPotentiallyReachable(At, I, nullptr, &DT)) {
          R = true;
          break;
        }
      }
    }
    ReadAfter[{A, At}] = R;
    return R;
  }
  DenseMap<std::pair<AllocaInst *, Instruction *>, bool> ReadAfter;

  static bool isAlias(const Value *V, ArrayRef<const Value *> Aliases) {
    if (!V)
      return false;
    for (const Value *A : Aliases)
      if (V == A)
        return true;
    return false;
  }
  // Stored capability comes from one of Aliases: the pointer itself, a field
  // or element, a load of it (Vec's heap buffer), or that value passed
  // through black_box / empty asm. If the walk goes through such a load,
  // *Heap is that load: its bounds are the freed allocation, not the Vec
  // header that drop_glue receives.
  bool derivedFrom(const Value *V, ArrayRef<const Value *> Aliases,
                   const Value **Heap, unsigned Depth = 0) {
    SmallVector<const Value *, 8> WL{V};
    SmallPtrSet<const Value *, 8> Seen;
    for (unsigned Steps = 0; Steps < 16 && !WL.empty(); ++Steps) {
      const Value *X = WL.pop_back_val();
      if (!X || !Seen.insert(X).second)
        continue;
      if (isAlias(X, Aliases) || isAlias(getUnderlyingObject(X), Aliases))
        return true;
      if (auto *GEP = dyn_cast<GEPOperator>(X)) {
        WL.push_back(GEP->getPointerOperand());
        continue;
      }
      if (auto *CI = dyn_cast<CastInst>(X)) {
        WL.push_back(CI->getOperand(0));
        continue;
      }
      if (auto *LI = dyn_cast<LoadInst>(X)) {
        const Value *P = LI->getPointerOperand();
        const Value *PU = getUnderlyingObject(P);
        if (isAlias(P, Aliases) || isAlias(PU, Aliases)) {
          if (Heap && !*Heap)
            *Heap = LI;
          return true;
        }
        // s1: rN = load %array.i, and %array.i was filled with gep(load %v).
        // Follow every store, at any index. Give up if the array escapes, a
        // store is unknown, or the chain is too deep.
        auto *SrcA = dyn_cast<AllocaInst>(PU);
        if (!SrcA || Depth >= 3 || escapes(SrcA))
          continue;
        auto Fit = Fills.find(SrcA);
        if (Fit == Fills.end() || Fit->second.Unknown || Fit->second.Vals.empty())
          continue;
        bool All = true;
        for (const Value *S : Fit->second.Vals)
          if (!derivedFrom(S, Aliases, Heap, Depth + 1)) {
            All = false;
            break;
          }
        if (All)
          return true;
        continue;
      }
      if (auto *PHI = dyn_cast<PHINode>(X)) {
        for (const Value *Inc : PHI->incoming_values())
          WL.push_back(Inc);
        continue;
      }
      if (auto *Sel = dyn_cast<SelectInst>(X)) {
        WL.push_back(Sel->getTrueValue());
        WL.push_back(Sel->getFalseValue());
        continue;
      }
      if (const auto *CB = dyn_cast<CallBase>(X)) {
        bool Through = isEmptyAsm(CB);
        if (!Through)
          if (const Function *CF = CB->getCalledFunction())
            Through = CF->getName().contains("black_box");
        if (!Through)
          continue;
        for (const Value *Arg : CB->args())
          if (Arg->getType()->isPointerTy())
            WL.push_back(Arg);
      }
    }
    return false;
  }
  // drop(%tmp) after memcpy(%tmp, %src) + mem.move(%src): %tmp aliases %src,
  // so a load of %src is a load of the dropped object. A whole-object copy
  // before the drop aliases even without the fact. Chains stay short.
  void ownerAliases(const Value *Owner, Instruction *Drop, DominatorTree &DT,
                    SmallVectorImpl<const Value *> &Out) {
    const Value *Root = getUnderlyingObject(Owner);
    Out.push_back(Root);
    SmallPtrSet<const Value *, 4> Seen;
    Seen.insert(Root);
    SmallVector<const Value *, 4> WL{Root};
    Function *Fn = Drop->getFunction();
    while (!WL.empty() && Out.size() < 4) {
      const Value *Dest = WL.pop_back_val();
      for (Instruction &I : instructions(*Fn)) {
        auto *MT = dyn_cast<MemTransferInst>(&I);
        if (!MT || !DT.dominates(MT, Drop))
          continue;
        if (getUnderlyingObject(MT->getRawDest()) != Dest)
          continue;
        const Value *Src = getUnderlyingObject(MT->getRawSource());
        if (!Src || !Seen.insert(Src).second)
          continue;
        bool Moved = false;
        for (Instruction &J : instructions(*Fn)) {
          if (!memannot::isMemMoveFact(&J) || !DT.dominates(&J, Drop))
            continue;
          const Value *Slot = memannot::slotClobber(&J);
          if (Slot && getUnderlyingObject(Slot) == Src)
            Moved = true;
        }
        bool Whole = false;
        if (auto *Len = dyn_cast<ConstantInt>(MT->getLength())) {
          uint64_t N = Len->getZExtValue();
          uint64_t Need = 0;
          auto NeedOf = [&](const Value *Obj) {
            if (auto *SA = dyn_cast<AllocaInst>(Obj))
              if (auto Sz = SA->getAllocationSize(DL))
                if (!Sz->isScalable())
                  Need = std::max(Need, Sz->getFixedValue());
          };
          NeedOf(Src);
          NeedOf(Dest);
          Whole = Need && N >= Need && N >= 16;
        }
        if (!Moved && !Whole)
          continue;
        Out.push_back(Src);
        WL.push_back(Src);
      }
    }
  }
  bool slotHoldsOwner(AllocaInst *A, int64_t Off, ArrayRef<const Value *> Aliases,
                      const Value **Heap) {
    auto It = SlotStored.find({A, Off});
    if (It != SlotStored.end()) {
      for (const Value *S : It->second)
        if (derivedFrom(S, Aliases, Heap, 0))
          return true;
      return false;
    }
    // No constant-offset store (s1's %array.i). If every pointer stored into
    // it, at any index, is derived from the owner, the array itself is too.
    if (escapes(A))
      return false;
    auto Fit = Fills.find(A);
    if (Fit == Fills.end() || Fit->second.Unknown || Fit->second.Vals.empty())
      return false;
    for (const Value *S : Fit->second.Vals)
      if (!derivedFrom(S, Aliases, Heap, 0))
        return false;
    return true;
  }
  static bool isOwnerFreeCall(const CallBase &CB) {
    if (CB.getOperandBundle(memannot::TagFree) || CB.isInlineAsm())
      return false;
    if (const Function *CF = CB.getCalledFunction()) {
      StringRef N = CF->getName();
      if (N.contains("drop_in_place") || N.contains("drop_glue"))
        return true;
    }
    return memannot::isDeallocCall(CB);
  }
  // O1 inlines past drop_glue to RawVecInner::deallocate(%tmp). The callee
  // name is not special: the argument is the mem.move'd owner, or the
  // memcpy temp whose source that fact covers.
  bool takesMovedOwner(const CallBase &CB, DominatorTree &DT) {
    const Function *Fn = CB.getFunction();
    SmallVector<const Value *, 4> Moved;
    for (const Instruction &J : instructions(*Fn)) {
      if (!memannot::isMemMoveFact(&J) || !DT.dominates(&J, &CB))
        continue;
      if (const Value *Slot = memannot::slotClobber(&J))
        Moved.push_back(getUnderlyingObject(Slot));
    }
    if (Moved.empty())
      return false;
    for (const Value *Arg : CB.args()) {
      if (!DL.isFatPointer(Arg->getType()))
        continue;
      const Value *U = getUnderlyingObject(Arg);
      for (const Value *Mv : Moved)
        if (U == Mv)
          return true;
      for (const Instruction &I : instructions(*Fn)) {
        auto *MT = dyn_cast<MemTransferInst>(&I);
        if (!MT || !DT.dominates(MT, &CB))
          continue;
        if (getUnderlyingObject(MT->getRawDest()) != U)
          continue;
        const Value *Src = getUnderlyingObject(MT->getRawSource());
        for (const Value *Mv : Moved)
          if (Src == Mv)
            return true;
      }
    }
    return false;
  }

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

  // M6.1 D91/D92. Root plus dominating copies of that capability: bitcast,
  // addrspacecast, freeze, GEP, a phi or select whose incoming caps are all
  // already copies, and an empty inline asm that returns its pointer operand.
  // Bound: 8 values and 32 users. A phi/select that mixes in another object
  // is left alone (the register at the merge is not this capability on every
  // path).
  bool fatCap(const Value *V) const {
    return V && !isa<Constant>(V) && DL.isFatPointer(V->getType());
  }
  bool dominatesAt(const Value *V, Instruction *At, DominatorTree &DT) const {
    if (const auto *I = dyn_cast<Instruction>(V))
      return DT.dominates(I, At);
    return isa<Argument>(V);
  }
  // Trunc is set when the copy walk hits its bound, so a missed user is
  // treated as an escape rather than dropped.
  void capCopies(Value *Root, Instruction *At, DominatorTree &DT,
                 SmallVectorImpl<Value *> &Out, bool &Trunc) {
    Trunc = false;
    if (!At || !fatCap(Root) || !dominatesAt(Root, At, DT))
      return;
    SmallPtrSet<Value *, 16> In;
    SmallVector<Value *, 8> Wave;
    auto Push = [&](Value *V) {
      if (!fatCap(V) || !dominatesAt(V, At, DT))
        return;
      if (Out.size() >= 8) {
        Trunc = true;
        return;
      }
      if (!In.insert(V).second)
        return;
      Out.push_back(V);
      Wave.push_back(V);
    };
    Push(Root);
    unsigned SeenUsers = 0;
    while (!Wave.empty() && Out.size() < 8 && SeenUsers < 32) {
      Value *V = Wave.pop_back_val();
      for (User *U : V->users()) {
        if (Out.size() >= 8 || SeenUsers >= 32) {
          Trunc = true;
          break;
        }
        ++SeenUsers;
        auto *I = dyn_cast<Instruction>(U);
        if (!I || !fatCap(I) || !dominatesAt(I, At, DT))
          continue;
        bool Take = false;
        if (isa<BitCastInst>(I) || isa<AddrSpaceCastInst>(I) ||
            isa<FreezeInst>(I) || isa<GetElementPtrInst>(I))
          Take = true;
        else if (auto *PN = dyn_cast<PHINode>(I))
          Take = any_of(PN->incoming_values(),
                        [&](Value *Inc) { return In.count(Inc); }) &&
                 all_of(PN->incoming_values(), [&](Value *Inc) {
                   return isa<UndefValue>(Inc) || In.count(Inc);
                 });
        else if (auto *Sel = dyn_cast<SelectInst>(I))
          Take = (In.count(Sel->getTrueValue()) ||
                  In.count(Sel->getFalseValue())) &&
                 (isa<UndefValue>(Sel->getTrueValue()) ||
                  In.count(Sel->getTrueValue())) &&
                 (isa<UndefValue>(Sel->getFalseValue()) ||
                  In.count(Sel->getFalseValue()));
        else if (auto *CB = dyn_cast<CallBase>(I))
          if (InvAsmNoEscape && isEmptyAsm(CB)) {
            bool Any = false, All = true;
            for (Value *A : CB->args()) {
              if (!A->getType()->isPointerTy())
                continue;
              if (In.count(A))
                Any = true;
              else
                All = false;
            }
            Take = Any && All;
          }
        if (Take)
          Push(I);
      }
    }
  }
  static bool realCall(const Instruction &I) {
    const auto *CB = dyn_cast<CallBase>(&I);
    return CB && !CB->isInlineAsm() &&
           CB->getIntrinsicID() == Intrinsic::not_intrinsic;
  }
  // Blocks that contain a real call, or can reach one. Built per function.
  DenseSet<BasicBlock *> CallReach;
  void buildCallReach(Function &F) {
    CallReach.clear();
    SmallVector<BasicBlock *, 16> Work;
    for (BasicBlock &BB : F)
      for (Instruction &I : BB)
        if (realCall(I)) {
          Work.push_back(&BB);
          break;
        }
    while (!Work.empty()) {
      BasicBlock *BB = Work.pop_back_val();
      if (!CallReach.insert(BB).second)
        continue;
      for (BasicBlock *P : predecessors(BB))
        Work.push_back(P);
    }
  }
  // D94. A callee after this point can save a callee-saved register that
  // still holds the cap. With no later call, the epilogue restores the
  // incoming register before any other function runs, so a dead address
  // does not need a clear (and adding one forces a save).
  bool callAfter(Instruction *E) const {
    BasicBlock *BB = E->getParent();
    for (auto It = std::next(E->getIterator()); It != BB->end(); ++It)
      if (realCall(*It))
        return true;
    for (BasicBlock *S : successors(BB))
      if (CallReach.count(S))
        return true;
    return false;
  }
  // 0 loan/free, 1 scope that escapes, 2 scope that does not.
  static constexpr unsigned KindLoanFree = 0;
  static constexpr unsigned KindScopeEscape = 1;
  static constexpr unsigned KindScopeLocal = 2;

  // D104. PHIs must stay grouped at the top of the block. A last use that is
  // a PHI (or the next instruction, which is still a PHI) is not a valid
  // insertion point. The first non-PHI is after every PHI, so it is still
  // after that use.
  static Instruction *afterPhiGroup(Instruction *At) {
    if (!At || !isa<PHINode>(At))
      return At;
    return At->getParent()->getFirstNonPHI();
  }
  void emitOne(IRBuilder<> &B, Value *V, Instruction *At, unsigned Kind,
               unsigned &Counter) {
    At = afterPhiGroup(At);
    if (!At)
      return;
    // One invalidate of this value and kind per block. A scope end that is
    // visited again, or several copies that share this value, must not stack
    // identical calls between (or after) the PHIs.
    for (Instruction &I : *At->getParent()) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB || CB->getIntrinsicID() != Intrinsic::cheri_cap_invalidate ||
          CB->arg_size() < 2 || CB->getArgOperand(0) != V)
        continue;
      if (auto *K = dyn_cast<ConstantInt>(CB->getArgOperand(1)))
        if (K->getZExtValue() == Kind)
          return;
    }
    B.SetInsertPoint(At);
    B.CreateCall(decl(Intrinsic::cheri_cap_invalidate),
                 {V, B.getInt32(Kind)});
    ++Counter;
  }
  // Latest use of V that dominates End, ignoring lifetime markers and the
  // invalidate itself. The pseudo goes immediately after this use so the
  // live range does not stretch to lifetime.end across a later call (D100).
  Instruction *latestUse(Value *V, Instruction *End, DominatorTree &DT) const {
    Instruction *Best = nullptr;
    for (User *U : V->users()) {
      auto *I = dyn_cast<Instruction>(U);
      if (!I || I == End || isa<DbgInfoIntrinsic>(I))
        continue;
      if (auto *CB = dyn_cast<CallBase>(I)) {
        if (CB->isLifetimeStartOrEnd() ||
            CB->getIntrinsicID() == Intrinsic::cheri_cap_invalidate)
          continue;
      }
      if (!DT.dominates(I, End))
        continue;
      if (!Best || DT.dominates(Best, I))
        Best = I;
    }
    return Best;
  }
  static bool memIntrinsic(const CallBase &CB) {
    switch (CB.getIntrinsicID()) {
    case Intrinsic::memcpy:
    case Intrinsic::memcpy_inline:
    case Intrinsic::memset:
    case Intrinsic::memset_inline:
    case Intrinsic::memmove:
      return true;
    default:
      return false;
    }
  }
  // D99. The address leaves this function: passed to a real call, stored,
  // returned, or handed to something that is not a local use of the memory.
  // memcpy/memset and an empty asm do not capture it. A truncated copy walk
  // counts as escape so a missed user is not treated as local.
  bool allocaEscapes(ArrayRef<Value *> Copies, bool Trunc) const {
    if (Trunc)
      return true;
    SmallPtrSet<const Value *, 8> In;
    for (Value *V : Copies)
      In.insert(V);
    for (Value *V : Copies) {
      for (User *U : V->users()) {
        auto *I = dyn_cast<Instruction>(U);
        if (!I)
          continue;
        if (auto *SI = dyn_cast<StoreInst>(I)) {
          if (In.count(SI->getValueOperand()))
            return true;
          continue;
        }
        if (isa<ReturnInst>(I))
          return true;
        if (auto *CB = dyn_cast<CallBase>(I)) {
          if (CB->isLifetimeStartOrEnd() || isa<DbgInfoIntrinsic>(CB) ||
              CB->getIntrinsicID() == Intrinsic::cheri_cap_invalidate)
            continue;
          if (InvAsmNoEscape && isEmptyAsm(CB))
            continue;
          if (memIntrinsic(*CB))
            continue;
          for (Value *A : CB->args())
            if (In.count(A))
              return true;
          continue;
        }
        if (isa<LoadInst>(I) || isa<AtomicRMWInst>(I) || isa<ICmpInst>(I) ||
            isa<PtrToIntInst>(I) || isa<GetElementPtrInst>(I) ||
            isa<BitCastInst>(I) || isa<AddrSpaceCastInst>(I) ||
            isa<FreezeInst>(I) || isa<PHINode>(I) || isa<SelectInst>(I))
          continue;
        if (auto *CX = dyn_cast<AtomicCmpXchgInst>(I)) {
          if (CX->getPointerOperand() == V)
            continue;
          return true;
        }
        return true;
      }
    }
    return false;
  }
  // D97 decides at the physical register whether this use is a kill. Loan
  // and free pass kind 0. Scope passes 1 or 2 (D99).
  void emitCapRegs(IRBuilder<> &B, Value *Root, Instruction *At,
                   DominatorTree &DT, unsigned &Counter) {
    emitCapRegsKind(B, Root, At, DT, Counter, KindLoanFree);
  }
  void emitCapRegsKind(IRBuilder<> &B, Value *Root, Instruction *At,
                       DominatorTree &DT, unsigned &Counter, unsigned Kind) {
    if (!InvCapReg)
      return;
    SmallVector<Value *, 8> Vs;
    bool Trunc = false;
    capCopies(Root, At, DT, Vs, Trunc);
    if (Kind == KindScopeLocal && allocaEscapes(Vs, Trunc))
      Kind = KindScopeEscape;
    for (Value *V : Vs) {
      // Loan and free stay at At: after the call and after the range-check
      // loads inserted at the same point. Moving them earlier breaks the
      // free sequence and can clear a register the call still needs.
      if (Kind == KindLoanFree) {
        emitOne(B, V, At, Kind, Counter);
        continue;
      }
      Instruction *U = latestUse(V, At, DT);
      // Loan, free, and an escaping scope still name a copy that has no
      // further use: a pinned register can hold the capability with no
      // other instruction reading it. A local scope object does not.
      if (!U && Kind == KindScopeLocal)
        continue;
      // After the last real use when that use is before End, so the live
      // range is not stretched across a later call. With no such use, End
      // itself is the point.
      Instruction *Ins = At;
      if (U && !U->isTerminator())
        if (Instruction *N = U->getNextNode())
          Ins = N;
      emitOne(B, V, Ins, Kind, Counter);
    }
  }

  // [LLM-generated] M7.1a. Resolve "mem.move"'s operand to one frame slot:
  // an alloca at a constant, non-negative, 16-byte-aligned offset. A variable
  // index, a heap/argument/global address, poison, or a misaligned offset is
  // not a slot this pass can null.
  bool frameSlot(Value *P, AllocaInst *&A, int64_t &Off) const {
    A = nullptr;
    Off = 0;
    if (!P || !P->getType()->isPointerTy())
      return false;
    Value *Base = GetPointerBaseWithConstantOffset(P, Off, DL);
    A = dyn_cast<AllocaInst>(Base);
    return A && Off >= 0 && Off % 16 == 0;
  }
  bool isThisSlot(Value *P, AllocaInst *A, int64_t Off) const {
    AllocaInst *B = nullptr;
    int64_t O = 0;
    return frameSlot(P, B, O) && B == A && O == Off;
  }
  // A Vec move passes the slot itself to the callee. That call is the move
  // even though it does not load the owner into a register.
  bool callTakesSlot(const Instruction *I, AllocaInst *A, int64_t Off) const {
    auto *CB = dyn_cast<CallBase>(I);
    if (!CB || memannot::isMemFact(CB) || CB->isLifetimeStartOrEnd())
      return false;
    for (Value *Arg : CB->args())
      if (isThisSlot(Arg, A, Off))
        return true;
    return false;
  }
  // Last write of the slot in this block before the fact, if that write is
  // not followed by a move-out of the slot itself. A move-out is a load of
  // the slot (Box: the fact follows the load) or a call that takes the slot
  // (Vec: the fact follows that call, including a memcpy that copies it out).
  // A later use of the value that was stored is not a move-out: that SSA
  // value can still be live while the slot is copied (from_elem fills the
  // buffer from the same cap it stored). Treating it as one justified a null
  // of a slot the memcpy had not read yet. A store with no slot move-out
  // still occupies the slot at the fact. No store in this block is not a
  // re-init (the owner store may be in a predecessor).
  bool reinitBefore(Instruction *Fact, AllocaInst *A, int64_t Off) const {
    Instruction *Last = nullptr;
    for (Instruction &I : *Fact->getParent()) {
      if (&I == Fact)
        break;
      Value *Ptr = nullptr;
      if (auto *SI = dyn_cast<StoreInst>(&I))
        Ptr = SI->getPointerOperand();
      else if (auto *RMW = dyn_cast<AtomicRMWInst>(&I))
        Ptr = RMW->getPointerOperand();
      else if (auto *CX = dyn_cast<AtomicCmpXchgInst>(&I))
        Ptr = CX->getPointerOperand();
      if (!Ptr || !isThisSlot(Ptr, A, Off))
        continue;
      Last = &I;
    }
    if (!Last)
      return false;
    for (Instruction *I = Last->getNextNode(); I && I != Fact;
         I = I->getNextNode()) {
      if (isa<DbgInfoIntrinsic>(I))
        continue;
      if (auto *LI = dyn_cast<LoadInst>(I))
        if (isThisSlot(LI->getPointerOperand(), A, Off))
          return false;
      if (callTakesSlot(I, A, Off))
        return false;
    }
    return true;
  }
  // Pointer into A, or the address of A itself. A loaded capability is not
  // this: getUnderlyingObject does not look through the load.
  bool derivedFrom(const Value *P, const AllocaInst *A) const {
    return P && P->getType()->isPointerTy() && getUnderlyingObject(P) == A;
  }
  // [Start, Start+Len) overlaps the 16 bytes this fact would null. An unknown
  // length or a non-constant offset into A may overlap.
  bool overlapsNull(const Value *P, const AllocaInst *A, int64_t Off,
                    std::optional<uint64_t> Len) const {
    if (!derivedFrom(P, A))
      return false;
    int64_t O = 0;
    if (GetPointerBaseWithConstantOffset(P, O, DL) != A)
      return true;
    if (O >= Off + 16)
      return false;
    if (!Len)
      return true;
    return O + (int64_t)*Len > Off;
  }
  bool coversNull(const Value *P, const AllocaInst *A, int64_t Off,
                  uint64_t Len) const {
    if (!derivedFrom(P, A))
      return false;
    int64_t O = 0;
    if (GetPointerBaseWithConstantOffset(P, O, DL) != A)
      return false;
    return O <= Off && O + (int64_t)Len >= Off + 16;
  }
  static std::optional<uint64_t> constLen(const Value *V) {
    if (auto *C = dyn_cast<ConstantInt>(V))
      if (C->getBitWidth() <= 64)
        return C->getZExtValue();
    return std::nullopt;
  }
  // The only misplacement we have seen is a consuming copy-out after the
  // fact: memcpy/memmove whose source still overlaps the bytes we would null.
  // A plain load, an atomic read, a call that takes the slot, or an escaping
  // use is the use-after-move the null exists to trap, not a reason to skip.
  bool copyOutOfSlot(const Instruction *I, AllocaInst *A, int64_t Off) const {
    auto *MT = dyn_cast<MemTransferInst>(I);
    if (!MT)
      return false;
    return overlapsNull(MT->getRawSource(), A, Off, constLen(MT->getLength()));
  }
  // A write that replaces every byte the null would clear. Later reads see
  // the new value. An unknown size is not a re-init.
  bool reinitsSlot(const Instruction *I, AllocaInst *A, int64_t Off) const {
    if (auto *SI = dyn_cast<StoreInst>(I)) {
      if (derivedFrom(SI->getValueOperand(), A))
        return false;
      TypeSize Sz = DL.getTypeStoreSize(SI->getValueOperand()->getType());
      if (Sz.isScalable())
        return false;
      return coversNull(SI->getPointerOperand(), A, Off, Sz.getFixedValue());
    }
    if (auto *MS = dyn_cast<MemSetInst>(I)) {
      auto N = constLen(MS->getLength());
      return N && coversNull(MS->getRawDest(), A, Off, *N);
    }
    if (auto *MT = dyn_cast<MemTransferInst>(I)) {
      if (overlapsNull(MT->getRawSource(), A, Off, constLen(MT->getLength())))
        return false;
      auto N = constLen(MT->getLength());
      return N && coversNull(MT->getRawDest(), A, Off, *N);
    }
    return false;
  }
  // True when a memcpy/memmove source that overlaps the nulled bytes is
  // reachable after Fact and before a store that covers them. The rest of
  // the block is scanned, then every successor. A backedge re-scans only the
  // prefix of this block (instructions before the fact) for that copy-out.
  bool copyOutAfter(Instruction *Fact, AllocaInst *A, int64_t Off) const {
    Instruction *Start = Fact->getNextNode();
    if (!Start)
      return false;
    BasicBlock *FactBB = Fact->getParent();
    // 1: copy-out, 0: covering re-init ends this path, -1: fell off the range.
    auto Scan = [&](Instruction *From, Instruction *Stop) -> int {
      for (Instruction *I = From; I && I != Stop; I = I->getNextNode()) {
        if (copyOutOfSlot(I, A, Off))
          return 1;
        if (reinitsSlot(I, A, Off))
          return 0;
      }
      return -1;
    };
    SmallPtrSet<BasicBlock *, 8> Queued;
    SmallVector<std::pair<BasicBlock *, Instruction *>, 8> WL;
    Queued.insert(FactBB);
    WL.push_back({FactBB, Start});
    while (!WL.empty()) {
      auto [BB, From] = WL.pop_back_val();
      int R = Scan(From, nullptr);
      if (R == 1)
        return true;
      if (R == 0)
        continue;
      for (BasicBlock *S : successors(BB)) {
        if (!Queued.insert(S).second) {
          if (S == FactBB && Scan(&*FactBB->begin(), Fact) == 1)
            return true;
          continue;
        }
        WL.push_back({S, &*S->begin()});
      }
    }
    return false;
  }
  // Capability still holding the moved-from value. Prefer the latest load of
  // the slot before the fact (the reload that was moved), else the value of
  // the latest store. The slot address itself is not that capability.
  Value *moveCap(Instruction *Fact, AllocaInst *A, int64_t Off,
                 DominatorTree &DT) const {
    Instruction *Best = nullptr;
    Value *Cap = nullptr;
    auto Consider = [&](Instruction *Where, Value *V) {
      if (!V || !DL.isFatPointer(V->getType()) || isa<Constant>(V))
        return;
      if (!isa<LoadInst>(V) && getUnderlyingObject(V) == A)
        return;
      if (!DT.dominates(Where, Fact))
        return;
      if (Best && !DT.dominates(Best, Where))
        return;
      Best = Where;
      Cap = V;
    };
    for (Instruction &I : *Fact->getParent()) {
      if (&I == Fact)
        break;
      if (auto *LI = dyn_cast<LoadInst>(&I)) {
        if (isThisSlot(LI->getPointerOperand(), A, Off))
          Consider(LI, LI);
      } else if (auto *SI = dyn_cast<StoreInst>(&I)) {
        if (isThisSlot(SI->getPointerOperand(), A, Off))
          Consider(SI, SI->getValueOperand());
      }
    }
    return Cap;
  }
  // Box: the fact is the instruction after the load, and the call that
  // receives the register is still ahead. Invalidating at the fact would be
  // before that use, and the post-RA pass drops a pseudo whose register is
  // still live (no spill null either). Put the pseudo after the last use of
  // the cap in this block. Vec: the fact is already after the call, so the
  // cap usually has no later use and the pseudo stays at the fact.
  Instruction *invalidateAt(Value *Cap, Instruction *Fact) const {
    Instruction *Last = nullptr;
    if (Cap) {
      for (User *U : Cap->users()) {
        auto *I = dyn_cast<Instruction>(U);
        if (!I || I == Fact || isa<DbgInfoIntrinsic>(I))
          continue;
        if (I->getParent() != Fact->getParent() || !Fact->comesBefore(I))
          continue;
        if (!Last || Last->comesBefore(I))
          Last = I;
      }
    }
    if (Last) {
      if (!Last->isTerminator())
        if (Instruction *N = Last->getNextNode())
          return N;
      return Last;
    }
    return Fact->getNextNode();
  }
  // [LLM-generated] M7.1a. At each "mem.move"(slot), null the slot and
  // invalidate one copy of the capability that was in it (kind 0, the
  // loan/free class: the post-RA pass spills the same way). The null is the
  // next instruction after the fact. Escaping does not skip the clear. The
  // free log is not consulted.
  //
  // rustc places the fact immediately after the move. For Box that is after
  // the load and before the call that takes the register, so the null is
  // before that call and the register clear is after it. For Vec the slot is
  // the call argument, so the fact (and the null) follow the call.
  //
  // Ignored when the operand is not a constant-offset frame slot, the slot's
  // lifetime has already ended, or the same block re-initialized it before
  // the fact (reinitBefore). A memcpy/memmove whose source overlaps the slot
  // and is reachable after the fact, before a covering store, skips the null:
  // that is the early-fact misplacement. A later plain load is the
  // use-after-move the null exists to trap. A re-init store after the fact
  // overwrites the null.
  void moveClears(Function &F, DominatorTree &DT) {
    struct Act {
      CallBase *Fact;
      Value *Ptr;
      Value *Cap;
      Instruction *CapAt;
    };
    SmallVector<Act, 4> Acts;
    for (Instruction &I : instructions(F)) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB || !memannot::isMemMoveFact(CB))
        continue;
      auto OB = CB->getOperandBundle(memannot::TagMove);
      if (!OB || OB->Inputs.empty())
        continue;
      Value *P = OB->Inputs[0];
      AllocaInst *A = nullptr;
      int64_t Off = 0;
      if (!frameSlot(P, A, Off) || !DL.isFatPointer(P->getType()))
        continue;
      if (!liveAt(A, CB, DT))
        continue;
      // A consuming copy-out after the fact means the slot is still live.
      // A later load does not: safe Rust does not read a moved-from place,
      // so that load is the use-after-move this null is for.
      if (copyOutAfter(CB, A, Off)) {
        ++MoveNullSkippedLive;
        continue;
      }
      if (reinitBefore(CB, A, Off))
        continue;
      Value *Cap = moveCap(CB, A, Off, DT);
      Acts.push_back({CB, P, Cap, invalidateAt(Cap, CB)});
    }
    IRBuilder<> B(M.getContext());
    for (Act &A : Acts) {
      Instruction *At = A.Fact->getNextNode();
      if (!At)
        continue;
      B.SetInsertPoint(At);
      auto *S = B.CreateAlignedStore(
          ConstantPointerNull::get(cast<PointerType>(A.Ptr->getType())), A.Ptr,
          Align(16), InvVolatile);
      markClear(S, "cheri_inv_move");
      ++MoveNulls;
      if (!InvCapReg || !A.Cap || !A.CapAt)
        continue;
      // The null was inserted before At. A clear that belongs at At must
      // follow that null, not precede it.
      Instruction *CapAt = A.CapAt == At ? At : A.CapAt;
      if (CapAt->getParent() != A.Fact->getParent())
        continue;
      B.SetInsertPoint(CapAt);
      B.CreateCall(decl(Intrinsic::cheri_cap_invalidate),
                   {A.Cap, B.getInt32(KindLoanFree)});
    }
  }

  // [LLM-generated] M7.1b. A mem.loan_into fact is live at a last use of its id
  // when the fact dominates that point, the owner slot's lifetime has not
  // ended, no mem.move of the slot sits between them, and the buffer currently
  // in the slot was not passed to mem.free without a later store. The scan
  // re-reads the slot (grow/realloc) and walks [base, base+length) by 16.
  // M7.1d A: an intervening mem.move is not a skip when the buffer is still
  // live, rustc did not re-establish the same id after the last move, and
  // the loan is a capability. The scan then uses the still-named carrier
  // (memcpy dest, or the slot if it was re-inited) or the buffer cap itself.
  bool dominatesBetween(Instruction *From, Instruction *Mid, Instruction *To,
                        DominatorTree &DT) const {
    return From != Mid && Mid != To && DT.dominates(From, Mid) &&
           DT.dominates(Mid, To);
  }
  bool loadFromSlot(Value *P, AllocaInst *A, int64_t Off) const {
    SmallPtrSet<Value *, 8> Seen;
    SmallVector<Value *, 4> Work{P};
    while (!Work.empty()) {
      Value *X = Work.pop_back_val()->stripPointerCasts();
      if (!Seen.insert(X).second)
        continue;
      if (auto *L = dyn_cast<LoadInst>(X))
        if (isThisSlot(L->getPointerOperand(), A, Off))
          return true;
      if (auto *G = dyn_cast<GetElementPtrInst>(X))
        Work.push_back(G->getPointerOperand());
    }
    return false;
  }
  bool storeToSlotBetween(Instruction *From, Instruction *To, AllocaInst *A,
                          int64_t Off, DominatorTree &DT) const {
    for (Instruction &I : instructions(*From->getFunction())) {
      auto *SI = dyn_cast<StoreInst>(&I);
      if (!SI || !isThisSlot(SI->getPointerOperand(), A, Off))
        continue;
      if (dominatesBetween(From, SI, To, DT))
        return true;
    }
    return false;
  }
  // The value in the slot at Free was passed to this mem.free, and nothing
  // stored a new buffer before the last use.
  bool freesThisBuffer(CallBase *Free, AllocaInst *A, int64_t Off,
                       Instruction *At, DominatorTree &DT) const {
    auto OB = Free->getOperandBundle(memannot::TagFree);
    if (!OB || OB->Inputs.empty())
      return false;
    Value *P = OB->Inputs[0];
    bool This = loadFromSlot(P, A, Off);
    if (!This)
      for (User *U : P->users()) {
        auto *SI = dyn_cast<StoreInst>(U);
        if (!SI || SI->getValueOperand() != P)
          continue;
        if (!isThisSlot(SI->getPointerOperand(), A, Off))
          continue;
        if (!DT.dominates(SI, Free))
          continue;
        if (!storeToSlotBetween(SI, Free, A, Off, DT))
          This = true;
      }
    return This && !storeToSlotBetween(Free, At, A, Off, DT);
  }
  bool loanValAvailable(Value *V, Instruction *At, DominatorTree &DT) const {
    if (!V || isa<UndefValue>(V) || !V->getType()->isPointerTy())
      return false;
    if (auto *I = dyn_cast<Instruction>(V))
      return DT.dominates(I, At);
    return true;
  }

  bool isMemcpyLike(const Instruction *I, Value *&Dst, Value *&Src) const {
    auto *CB = dyn_cast<CallBase>(I);
    if (!CB)
      return false;
    Intrinsic::ID Id = CB->getIntrinsicID();
    if (Id != Intrinsic::memcpy && Id != Intrinsic::memmove)
      return false;
    if (CB->arg_size() < 2)
      return false;
    Dst = CB->getArgOperand(0);
    Src = CB->getArgOperand(1);
    return true;
  }
  // The latest instruction that stores to or loads a fat pointer from this
  // slot and dominates At. Same-block later wins; otherwise dominance.
  Instruction *latestDominating(Instruction *Best, Instruction *I,
                                Instruction *At, DominatorTree &DT) const {
    if (!I || I == At || !DT.dominates(I, At))
      return Best;
    if (!Best)
      return I;
    if (DT.dominates(Best, I))
      return I;
    if (!DT.dominates(I, Best) && Best->getParent() == I->getParent() &&
        Best->comesBefore(I))
      return I;
    return Best;
  }
  StoreInst *lastStoreToSlot(AllocaInst *A, int64_t Off, Instruction *At,
                             DominatorTree &DT) const {
    StoreInst *Best = nullptr;
    for (Instruction &I : instructions(*At->getFunction())) {
      auto *SI = dyn_cast<StoreInst>(&I);
      if (!SI || !isThisSlot(SI->getPointerOperand(), A, Off))
        continue;
      Best = dyn_cast_or_null<StoreInst>(latestDominating(Best, SI, At, DT));
    }
    return Best;
  }
  Value *lastCapFromSlot(AllocaInst *A, int64_t Off, Instruction *At,
                         DominatorTree &DT) const {
    Value *BestV = nullptr;
    Instruction *BestI = nullptr;
    for (Instruction &I : instructions(*At->getFunction())) {
      if (auto *LI = dyn_cast<LoadInst>(&I)) {
        if (!isThisSlot(LI->getPointerOperand(), A, Off))
          continue;
        if (!DL.isFatPointer(LI->getType()))
          continue;
        Instruction *N = latestDominating(BestI, LI, At, DT);
        if (N == LI) {
          BestI = LI;
          BestV = LI;
        }
      } else if (auto *SI = dyn_cast<StoreInst>(&I)) {
        if (!isThisSlot(SI->getPointerOperand(), A, Off))
          continue;
        Value *V = SI->getValueOperand();
        if (!V->getType()->isPointerTy() || !DL.isFatPointer(V->getType()))
          continue;
        if (isa<ConstantPointerNull>(V))
          continue;
        Instruction *N = latestDominating(BestI, SI, At, DT);
        if (N == SI) {
          BestI = SI;
          BestV = V;
        }
      }
    }
    return BestV;
  }
  // memcpy/memmove immediately before Move whose source is this slot.
  bool memcpyDestBefore(Instruction *Move, AllocaInst *A, int64_t Off,
                        AllocaInst *&DstA, int64_t &DstOff,
                        Value *&DstVal) const {
    for (Instruction *P = Move->getPrevNode(); P; P = P->getPrevNode()) {
      if (P->isDebugOrPseudoInst())
        continue;
      if (auto *CB = dyn_cast<CallBase>(P))
        if (memannot::isMemFact(CB))
          continue;
      Value *Dst = nullptr, *Src = nullptr;
      if (!isMemcpyLike(P, Dst, Src))
        return false;
      if (isThisSlot(Src, A, Off) && frameSlot(Dst, DstA, DstOff)) {
        DstVal = Dst;
        return true;
      }
      return false;
    }
    return false;
  }
  bool slotHoldsLiveBuf(AllocaInst *A, int64_t Off, Instruction *At,
                        DominatorTree &DT) {
    if (!liveAt(A, At, DT))
      return false;
    StoreInst *S = lastStoreToSlot(A, Off, At, DT);
    if (!S)
      return true;
    return !isa<ConstantPointerNull>(S->getValueOperand());
  }
  // rustc already re-emitted this id on a still-live slot after the last move.
  bool loanIntoReestablished(uint64_t Id, Instruction *Fact, Instruction *At,
                             ArrayRef<CallBase *> Moves,
                             ArrayRef<CallBase *> Facts,
                             AllocaInst *A, int64_t Off,
                             DominatorTree &DT) {
    CallBase *LastMv = nullptr;
    for (CallBase *Mv : Moves) {
      auto MB = Mv->getOperandBundle(memannot::TagMove);
      if (!MB || MB->Inputs.empty() || !isThisSlot(MB->Inputs[0], A, Off))
        continue;
      if (dominatesBetween(Fact, Mv, At, DT))
        LastMv = Mv;
    }
    if (!LastMv)
      return false;
    for (CallBase *F2 : Facts) {
      if (F2 == Fact)
        continue;
      auto OB = F2->getOperandBundle(memannot::TagLoanInto);
      if (!OB || OB->Inputs.size() < 3)
        continue;
      auto *IdC = dyn_cast<ConstantInt>(OB->Inputs[2]);
      if (!IdC || IdC->getZExtValue() != Id)
        continue;
      if (!dominatesBetween(LastMv, F2, At, DT) && F2 != At)
        continue;
      if (!DT.dominates(F2, At) && F2 != At)
        continue;
      AllocaInst *A2 = nullptr;
      int64_t Off2 = 0;
      if (!frameSlot(OB->Inputs[0], A2, Off2))
        continue;
      if (slotHoldsLiveBuf(A2, Off2, At, DT))
        return true;
    }
    return false;
  }
  // A mem.free between Fact and At of this buffer cap (or something that
  // may be it). Used when the owner slot was moved, so freesThisBuffer on
  // the source slot may not see a free of the SSA buffer pointer.
  bool capFreedBetween(Value *Buf, Instruction *Fact, Instruction *At,
                       ArrayRef<CallBase *> Frees, DominatorTree &DT) const {
    if (!Buf)
      return false;
    for (CallBase *Fr : Frees) {
      auto FB = Fr->getOperandBundle(memannot::TagFree);
      if (!FB || FB->Inputs.empty())
        continue;
      if (mayRunBetween(Fact, Fr, At, DT) &&
          mayBeThisBuffer(FB->Inputs[0], Buf))
        return true;
    }
    return false;
  }
  // Buffer still live after moves of A+Off: not freed without a replacement,
  // and we can name the current carrier or a dominating buffer cap.
  // Only capability loans are scanned.
  bool loanIntoMovedLiveTarget(AllocaInst *A, int64_t Off, Value *Slot,
                               Value *Loan, uint64_t Id, Instruction *Fact,
                               Instruction *At, DominatorTree &DT,
                               ArrayRef<CallBase *> Moves,
                               ArrayRef<CallBase *> Frees,
                               Value *&OutSlot, bool &Direct) {
    if (!InvLoanIntoMovedLive)
      return false;
    if (!Loan || !DL.isFatPointer(Loan->getType()))
      return false;
    for (CallBase *Fr : Frees)
      if (dominatesBetween(Fact, Fr, At, DT) &&
          freesThisBuffer(Fr, A, Off, At, DT))
        return false;
    AllocaInst *CurA = A;
    int64_t CurOff = Off;
    Value *CurSlot = Slot;
    for (CallBase *Mv : Moves) {
      auto MB = Mv->getOperandBundle(memannot::TagMove);
      if (!MB || MB->Inputs.empty() ||
          !isThisSlot(MB->Inputs[0], CurA, CurOff))
        continue;
      if (!dominatesBetween(Fact, Mv, At, DT))
        continue;
      AllocaInst *DstA = nullptr;
      int64_t DstOff = 0;
      Value *DstVal = nullptr;
      if (memcpyDestBefore(Mv, CurA, CurOff, DstA, DstOff, DstVal)) {
        CurA = DstA;
        CurOff = DstOff;
        CurSlot = DstVal;
      }
    }
    Value *CurBuf = lastCapFromSlot(CurA, CurOff, At, DT);
    Value *SrcBuf = lastCapFromSlot(A, Off, At, DT);
    if (capFreedBetween(CurBuf, Fact, At, Frees, DT) ||
        capFreedBetween(SrcBuf, Fact, At, Frees, DT))
      return false;
    if (slotHoldsLiveBuf(CurA, CurOff, At, DT)) {
      OutSlot = CurSlot;
      Direct = false;
      return true;
    }
    Value *Buf = CurBuf ? CurBuf : SrcBuf;
    if (!Buf || !loanValAvailable(Buf, At, DT) ||
        !DL.isFatPointer(Buf->getType()) ||
        capFreedBetween(Buf, Fact, At, Frees, DT))
      return false;
    OutSlot = Buf;
    Direct = true;
    return true;
  }

  // Dealloc cap of a mem.free of this slot's buffer between Fact and At.
  CallBase *freeOfSlotBetween(AllocaInst *A, int64_t Off, Instruction *Fact,
                              Instruction *At, ArrayRef<CallBase *> Frees,
                              DominatorTree &DT) const {
    CallBase *Found = nullptr;
    for (CallBase *Fr : Frees)
      if (dominatesBetween(Fact, Fr, At, DT) &&
          freesThisBuffer(Fr, A, Off, At, DT))
        Found = Fr;
    return Found;
  }
  CallBase *freeOfCapBetween(Value *Buf, Instruction *Fact, Instruction *At,
                             ArrayRef<CallBase *> Frees,
                             DominatorTree &DT) const {
    if (!Buf)
      return nullptr;
    CallBase *Found = nullptr;
    for (CallBase *Fr : Frees) {
      auto FB = Fr->getOperandBundle(memannot::TagFree);
      if (!FB || FB->Inputs.empty())
        continue;
      if (mayRunBetween(Fact, Fr, At, DT) &&
          mayBeThisBuffer(FB->Inputs[0], Buf))
        Found = Fr;
    }
    return Found;
  }
  // Ready dealloc cap to scan before Fr. Only capability loans, and only
  // when both the loan and the dealloc cap dominate the free.
  bool loanIntoFreedWipeTarget(Value *Loan, CallBase *Fr, DominatorTree &DT,
                               Value *&OutBuf) const {
    if (!InvLoanIntoFreedWipe || !Fr)
      return false;
    if (!Loan || !DL.isFatPointer(Loan->getType()))
      return false;
    auto FB = Fr->getOperandBundle(memannot::TagFree);
    if (!FB || FB->Inputs.empty())
      return false;
    Value *Buf = FB->Inputs[0];
    if (!Buf || !Buf->getType()->isPointerTy() ||
        !DL.isFatPointer(Buf->getType()))
      return false;
    if (!loanValAvailable(Loan, Fr, DT) || !loanValAvailable(Buf, Fr, DT))
      return false;
    OutBuf = Buf;
    return true;
  }

  void loanIntoPlan(Function &F, DominatorTree &DT) {
    unsigned LUKind = M.getContext().getMDKindID(memannot::LastUseMD);
    SmallVector<Instruction *, 8> Carriers;
    for (Instruction &I : instructions(F)) {
      if (I.isTerminator())
        continue;
      bool Meta = I.getMetadata(LUKind);
      SmallVector<memannot::LoanRef, 2> Bundle;
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (memannot::isMemFact(CB))
          memannot::appendBundleLoanRefs(*CB, Bundle);
      if ((Meta || !Bundle.empty()) && I.getNextNode())
        Carriers.push_back(&I);
    }
    SmallVector<CallBase *, 4> Facts, Moves, Frees;
    for (Instruction &I : instructions(F)) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      if (memannot::isMemLoanIntoFact(CB))
        Facts.push_back(CB);
      else if (memannot::isMemMoveFact(CB))
        Moves.push_back(CB);
      if (CB->getOperandBundle(memannot::TagFree))
        Frees.push_back(CB);
    }
    for (CallBase *Fact : Facts) {
      auto OB = Fact->getOperandBundle(memannot::TagLoanInto);
      if (!OB || OB->Inputs.size() < 3)
        continue;
      Value *Slot = OB->Inputs[0];
      Value *Loan = OB->Inputs[1];
      auto *IdC = dyn_cast<ConstantInt>(OB->Inputs[2]);
      if (!IdC || !IdC->getType()->isIntegerTy(64))
        continue;
      uint64_t Id = IdC->getZExtValue();
      memannot::LoanRef Ref{Id & memannot::LoanKeyMask, Id, 0};
      AllocaInst *A = nullptr;
      int64_t Off = 0;
      if (!frameSlot(Slot, A, Off))
        continue;
      for (Instruction *C : Carriers) {
        SmallVector<memannot::LoanRef, 4> Ids;
        memannot::appendLoanRefs(C->getMetadata(LUKind), Ids);
        if (auto *CB = dyn_cast<CallBase>(C))
          if (memannot::isMemFact(CB))
            memannot::appendBundleLoanRefs(*CB, Ids);
        if (!refsOverlap(ArrayRef<memannot::LoanRef>(Ref), Ids))
          continue;
        Instruction *At = C->getNextNode();
        if (!DT.dominates(Fact, At))
          continue;
        if (!liveAt(A, At, DT))
          continue;
        bool Moved = false;
        for (CallBase *Mv : Moves) {
          auto MB = Mv->getOperandBundle(memannot::TagMove);
          if (!MB || MB->Inputs.empty() ||
              !isThisSlot(MB->Inputs[0], A, Off))
            continue;
          if (dominatesBetween(Fact, Mv, At, DT))
            Moved = true;
        }
        if (Moved) {
          // Off is the pre-1d-A skip, including the counter.
          if (!InvLoanIntoMovedLive) {
            ++LoanIntoSkippedMoved;
            continue;
          }
          if (loanIntoReestablished(Id, Fact, At, Moves, Facts, A, Off, DT)) {
            ++LoanIntoSkippedMoved;
            continue;
          }
          Value *Tgt = nullptr;
          bool Direct = false;
          if (loanIntoMovedLiveTarget(A, Off, Slot, Loan, Id, Fact, At, DT,
                                      Moves, Frees, Tgt, Direct)) {
            ++LoanIntoMovedLive;
            PendingLoanInto.push_back({At, Tgt, Loan, Direct});
            continue;
          }
          {
            Value *WBuf = nullptr;
            CallBase *Fr = freeOfCapBetween(lastCapFromSlot(A, Off, At, DT),
                                            Fact, At, Frees, DT);
            if (!Fr)
              Fr = freeOfSlotBetween(A, Off, Fact, At, Frees, DT);
            if (Fr && loanIntoFreedWipeTarget(Loan, Fr, DT, WBuf)) {
              ++LoanIntoFreedWipe;
              PendingLoanInto.push_back({Fr, WBuf, Loan, true});
            } else if (Fr)
              ++LoanIntoSkippedFreed;
            else
              ++LoanIntoSkippedMoved;
          }
          continue;
        }
        bool Freed = false;
        for (CallBase *Fr : Frees)
          if (dominatesBetween(Fact, Fr, At, DT) &&
              freesThisBuffer(Fr, A, Off, At, DT))
            Freed = true;
        if (Freed) {
          Value *WBuf = nullptr;
          CallBase *Fr = freeOfSlotBetween(A, Off, Fact, At, Frees, DT);
          if (Fr && loanIntoFreedWipeTarget(Loan, Fr, DT, WBuf)) {
            ++LoanIntoFreedWipe;
            PendingLoanInto.push_back({Fr, WBuf, Loan, true});
          } else
            ++LoanIntoSkippedFreed;
          continue;
        }
        if (!loanValAvailable(Loan, At, DT)) {
          ++LoanIntoSkippedNoval;
          continue;
        }
        PendingLoanInto.push_back({At, Slot, Loan, false});
      }
    }
  }
  // P, or a cast/GEP/phi/select that can yield P, may be Buf.
  bool mayBeThisBuffer(Value *P, Value *Buf) const {
    SmallPtrSet<Value *, 8> Seen;
    SmallVector<Value *, 8> Work{P};
    while (!Work.empty()) {
      Value *X = Work.pop_back_val()->stripPointerCasts();
      if (!Seen.insert(X).second)
        continue;
      if (X == Buf)
        return true;
      if (auto *G = dyn_cast<GetElementPtrInst>(X))
        Work.push_back(G->getPointerOperand());
      else if (auto *PN = dyn_cast<PHINode>(X))
        for (Value *In : PN->incoming_values())
          Work.push_back(In);
      else if (auto *Sel = dyn_cast<SelectInst>(X)) {
        Work.push_back(Sel->getTrueValue());
        Work.push_back(Sel->getFalseValue());
      }
    }
    return false;
  }
  // Mid can execute after From and before To, including on one side of a branch.
  bool mayRunBetween(Instruction *From, Instruction *Mid, Instruction *To,
                     DominatorTree &DT) const {
    if (dominatesBetween(From, Mid, To, DT))
      return true;
    auto ComesAfter = [](Instruction *A, Instruction *B) {
      return A->getParent() == B->getParent() && A->comesBefore(B);
    };
    if (From->getParent() == Mid->getParent()) {
      if (!ComesAfter(From, Mid))
        return false;
    } else if (!isPotentiallyReachable(From->getParent(), Mid->getParent(),
                                       nullptr, &DT))
      return false;
    if (Mid->getParent() == To->getParent()) {
      if (!ComesAfter(Mid, To))
        return false;
    } else if (!isPotentiallyReachable(Mid->getParent(), To->getParent(),
                                       nullptr, &DT))
      return false;
    return true;
  }
  // A grow/realloc replaces the promoted field with a new pointer. Scan that
  // pointer only when every replacement is still this allocation; a call
  // result or a phi with another object is not.
  bool valueReassigned(Value *Buf, Instruction *Fact, Instruction *At,
                       DominatorTree &DT) const {
    for (Instruction &I : instructions(*Fact->getFunction())) {
      if (&I == Fact || &I == At || !mayRunBetween(Fact, &I, At, DT))
        continue;
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        if (!CB->getType()->isPointerTy() || CB->isInlineAsm())
          continue;
        if (const Function *Callee = CB->getCalledFunction())
          if (Callee->isIntrinsic())
            continue;
        for (Value *Arg : CB->args())
          if (Arg->getType()->isPointerTy() && mayBeThisBuffer(Arg, Buf))
            return true;
      } else if (auto *PN = dyn_cast<PHINode>(&I)) {
        bool SawBuf = false, SawOther = false;
        for (Value *In : PN->incoming_values()) {
          if (!In->getType()->isPointerTy() || isa<UndefValue>(In))
            continue;
          if (mayBeThisBuffer(In, Buf))
            SawBuf = true;
          else
            SawOther = true;
        }
        if (SawBuf && SawOther)
          return true;
      }
    }
    return false;
  }
  void loanIntoValPlan(Function &F, DominatorTree &DT) {
    unsigned LUKind = M.getContext().getMDKindID(memannot::LastUseMD);
    SmallVector<Instruction *, 8> Carriers;
    for (Instruction &I : instructions(F)) {
      if (I.isTerminator())
        continue;
      bool Meta = I.getMetadata(LUKind);
      SmallVector<memannot::LoanRef, 2> Bundle;
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (memannot::isMemFact(CB))
          memannot::appendBundleLoanRefs(*CB, Bundle);
      if ((Meta || !Bundle.empty()) && I.getNextNode())
        Carriers.push_back(&I);
    }
    SmallVector<CallBase *, 4> Facts, Frees;
    for (Instruction &I : instructions(F)) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      if (memannot::isMemLoanIntoValFact(CB))
        Facts.push_back(CB);
      if (CB->getOperandBundle(memannot::TagFree))
        Frees.push_back(CB);
    }
    for (CallBase *Fact : Facts) {
      auto OB = Fact->getOperandBundle(memannot::TagLoanIntoVal);
      if (!OB || OB->Inputs.size() < 3)
        continue;
      Value *Buf = OB->Inputs[0];
      Value *Loan = OB->Inputs[1];
      auto *IdC = dyn_cast<ConstantInt>(OB->Inputs[2]);
      if (!IdC || !IdC->getType()->isIntegerTy(64) || !Buf->getType()->isPointerTy())
        continue;
      uint64_t Id = IdC->getZExtValue();
      memannot::LoanRef Ref{Id & memannot::LoanKeyMask, Id, 0};
      for (Instruction *C : Carriers) {
        SmallVector<memannot::LoanRef, 4> Ids;
        memannot::appendLoanRefs(C->getMetadata(LUKind), Ids);
        if (auto *CB = dyn_cast<CallBase>(C))
          if (memannot::isMemFact(CB))
            memannot::appendBundleLoanRefs(*CB, Ids);
        if (!refsOverlap(ArrayRef<memannot::LoanRef>(Ref), Ids))
          continue;
        Instruction *At = C->getNextNode();
        if (!DT.dominates(Fact, At))
          continue;
        if (isa<UndefValue>(Buf)) {
          ++LoanIntoSkippedPromoted;
          continue;
        }
        if (!loanValAvailable(Buf, At, DT) || !loanValAvailable(Loan, At, DT)) {
          ++LoanIntoSkippedNoval;
          continue;
        }
        if (valueReassigned(Buf, Fact, At, DT)) {
          ++LoanIntoSkippedValReassigned;
          continue;
        }
        bool Freed = false;
        for (CallBase *Fr : Frees) {
          auto FB = Fr->getOperandBundle(memannot::TagFree);
          if (!FB || FB->Inputs.empty())
            continue;
          if (mayRunBetween(Fact, Fr, At, DT) &&
              mayBeThisBuffer(FB->Inputs[0], Buf))
            Freed = true;
        }
        if (Freed) {
          Value *WBuf = nullptr;
          CallBase *Fr = freeOfCapBetween(Buf, Fact, At, Frees, DT);
          if (Fr && loanIntoFreedWipeTarget(Loan, Fr, DT, WBuf)) {
            ++LoanIntoFreedWipe;
            PendingLoanInto.push_back({Fr, WBuf, Loan, true});
          } else
            ++LoanIntoSkippedValFreed;
          continue;
        }
        PendingLoanInto.push_back({At, Buf, Loan, true});
      }
    }
  }
  // In-function loop, not an out-of-line helper. One static null store.
  void loanIntoEmit() {
    Type *CapTy = PointerType::get(M.getContext(), 200);
    for (const LoanIntoScan &S : PendingLoanInto) {
      Instruction *At = S.At;
      if (!At || !At->getParent())
        continue;
      BasicBlock *Cont =
          SplitBlock(At->getParent(), At->getIterator(),
                     static_cast<DominatorTree *>(nullptr), nullptr, nullptr,
                     "loaninto.cont");
      BasicBlock *Pre = Cont->getSinglePredecessor();
      Pre->getTerminator()->eraseFromParent();
      LLVMContext &Ctx = M.getContext();
      Function *Fn = Cont->getParent();
      auto *Hdr = BasicBlock::Create(Ctx, "loaninto.hdr", Fn, Cont);
      auto *Loop = BasicBlock::Create(Ctx, "loaninto.loop", Fn, Cont);
      auto *Body = BasicBlock::Create(Ctx, "loaninto.body", Fn, Cont);
      auto *NullBB = BasicBlock::Create(Ctx, "loaninto.null", Fn, Cont);
      auto *Next = BasicBlock::Create(Ctx, "loaninto.next", Fn, Cont);
      IRBuilder<> B(Pre);
      // Direct: the fact already names the buffer capability (promoted slot).
      Value *Buf = S.Direct ? S.Slot
                            : B.CreateAlignedLoad(CapTy, S.Slot, Align(16),
                                                  "loaninto.buf");
      Value *Tag = B.CreateCall(decl(Intrinsic::cheri_cap_tag_get), {Buf});
      Value *Live = B.CreateAnd(
          Tag, B.CreateICmpNE(Buf, ConstantPointerNull::get(cast<PointerType>(CapTy))));
      B.CreateCondBr(Live, Hdr, Cont);
      B.SetInsertPoint(Hdr);
      Value *Base = B.CreateCall(
          decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {Buf});
      Value *AtBase = B.CreateCall(
          decl(Intrinsic::cheri_cap_address_set, {B.getInt64Ty()}),
          {Buf, Base});
      Value *Len = B.CreateCall(
          decl(Intrinsic::cheri_cap_length_get, {B.getInt64Ty()}), {Buf});
      Value *N = B.CreateLShr(Len, B.getInt64(4), "loaninto.n");
      B.CreateBr(Loop);
      B.SetInsertPoint(Loop);
      PHINode *IV = B.CreatePHI(B.getInt64Ty(), 2, "loaninto.i");
      IV->addIncoming(B.getInt64(0), Hdr);
      B.CreateCondBr(B.CreateICmpULT(IV, N), Body, Cont);
      B.SetInsertPoint(Body);
      Value *Byte = B.CreateShl(IV, B.getInt64(4));
      Value *Elt = B.CreateInBoundsGEP(B.getInt8Ty(), AtBase, Byte, "loaninto.elt");
      Value *Got = B.CreateAlignedLoad(CapTy, Elt, Align(16), "loaninto.eltv");
      Value *Eq = B.CreateCall(decl(Intrinsic::cheri_cap_equal_exact),
                               {Got, S.Loan});
      B.CreateCondBr(Eq, NullBB, Next);
      B.SetInsertPoint(NullBB);
      auto *St = B.CreateAlignedStore(
          ConstantPointerNull::get(cast<PointerType>(CapTy)), Elt, Align(16),
          InvVolatile);
      markClear(St, "cheri_inv_loan_into");
      B.CreateBr(Next);
      ++LoanIntoNulls;
      B.SetInsertPoint(Next);
      Value *Inc = B.CreateAdd(IV, B.getInt64(1));
      B.CreateBr(Loop);
      IV->addIncoming(Inc, Next);
      ++LoanIntoScans;
    }
    PendingLoanInto.clear();
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
          if (Value *Cap = loanCapValue(L, C, At, DT)) {
            B.CreateCall(decl(Intrinsic::cheri_cap_invalidate),
                         {Cap, B.getInt32(KindLoanFree)});
            ++CapRegLoan;
          }
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
  // D115: those entries are checked by one loop, not FLogCheck unrolled copies.
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
  // Self-referential loop id. Unroll (and unroll-and-jam) would turn this
  // back into FLogCheck copies; vectorising a volatile cap check is not a
  // win and can spill the capability being tested. LICM / LSR stay enabled
  // so the hoisted log pointer can live in one register.
  static MDNode *flogLoopMetadata(LLVMContext &Ctx) {
    MDNode *NoUnroll = MDNode::get(
        Ctx, {MDString::get(Ctx, "llvm.loop.unroll.disable")});
    MDNode *NoJam = MDNode::get(
        Ctx, {MDString::get(Ctx, "llvm.loop.unroll_and_jam.disable")});
    Metadata *False =
        ConstantAsMetadata::get(ConstantInt::getFalse(Ctx));
    MDNode *NoVec = MDNode::get(
        Ctx, {MDString::get(Ctx, "llvm.loop.vectorize.enable"), False});
    MDNode *ID = MDNode::getDistinct(Ctx, {nullptr, NoUnroll, NoJam, NoVec});
    ID->replaceOperandWith(0, ID);
    return ID;
  }
  // [LLM-generated] D115. One checkAndClear template per slot, all of them
  // inside a single loop shared by this call:
  //   for K = 0 .. min(D, FLogCheck)-1:
  //     (Lo, Len) = log[N1 - 1 - K]   // flogEnt's ring mask, same as before
  //     checkAndClear(slot, Lo, Len)
  // A per-slot loop would repeat the index, the ring mask and both volatile
  // log loads once per slot. Sharing them is less IR and less code. Each
  // template loads, tests and stores its capability before the next slot, so
  // the cap under test dies at the store and a second slot does not extend a
  // cap live range. The loop-carried state is the integer index plus the log
  // pointer materialised once in the preheader.
  //
  // The loop is bottom-tested, so it is only sound inside the D != 0 split
  // the caller already emitted. D == 0 must not run K = 0: that would read
  // log[N1 - 1], an entry this call did not append, and could invent a clear.
  // Ring overflow still only misses a clear (the mask never addresses a
  // slot outside the ring, and K stops at FLogCheck).
  // range_checks increments once per template, in checkAndClear, not per K.
  void emitFlogLoop(Instruction *ThenTerm, Value *N1, Value *D,
                    ArrayRef<Slot> Ss) {
    assert(FLogCheck != 0 && "zero trip count would still run the body");
    BasicBlock *Enter = ThenTerm->getParent();
    BasicBlock *Exit = ThenTerm->getSuccessor(0);
    Function *Fn = Enter->getParent();
    LLVMContext &Ctx = Fn->getContext();
    BasicBlock *Header = BasicBlock::Create(Ctx, "cheri.flog.loop", Fn, Exit);
    Enter->setName("cheri.flog.enter");
    ThenTerm->eraseFromParent();
    // The empty then-block was the only D != 0 predecessor of Exit.
    Exit->replacePhiUsesWith(Enter, Header);

    IRBuilder<> PH(Enter);
    Value *Bound = PH.CreateBinaryIntrinsic(
        Intrinsic::umin, D, PH.getInt64(FLogCheck), {}, "cheri.flog.bound");
    // flogEnt's (0, 1, 0): the first i64 of the {count, entries[]} ring.
    // Insert, do not let the builder fold this into a constant expression,
    // so the log capability is one SSA value in the preheader (one register
    // across the loop) rather than rematerialised at each GEP.
    // The loop then applies the same ((idx & (FLogN-1)) << 1) + field.
    Value *Entries = PH.Insert(
        GetElementPtrInst::CreateInBounds(
            flog()->getValueType(), flog(),
            {PH.getInt32(0), PH.getInt32(1), PH.getInt64(0)}),
        "cheri.flog.ptr");
    PH.CreateBr(Header);

    IRBuilder<> HB(Header);
    PHINode *K = HB.CreatePHI(HB.getInt64Ty(), 2, "cheri.flog.k");
    K->addIncoming(HB.getInt64(0), Enter);
    // KNext = K + 1, so the entry is log[N1 - (K + 1)], today's Idx.
    Value *KNext =
        HB.CreateAdd(K, HB.getInt64(1), "cheri.flog.knext", true, false);
    Value *Idx = HB.CreateSub(N1, KNext, "cheri.flog.idx");
    Value *SlotIx =
        HB.CreateAnd(Idx, HB.getInt64(FLogN - 1), "cheri.flog.slot");
    Value *Pair = HB.CreateShl(SlotIx, 1, "cheri.flog.pair", true, false);
    Value *LoPtr =
        HB.CreateInBoundsGEP(HB.getInt64Ty(), Entries, Pair, "cheri.flog.lop");
    Value *LenOff =
        HB.CreateAdd(Pair, HB.getInt64(1), "cheri.flog.lenoff", true, false);
    Value *LenPtr = HB.CreateInBoundsGEP(HB.getInt64Ty(), Entries, LenOff,
                                         "cheri.flog.lenp");
    Value *Lo = HB.CreateAlignedLoad(HB.getInt64Ty(), LoPtr, Align(8), true,
                                     "cheri.flog.lo");
    Value *Len = HB.CreateAlignedLoad(HB.getInt64Ty(), LenPtr, Align(8), true,
                                      "cheri.flog.len");
    for (Slot S : Ss)
      checkAndClear(HB, S, Lo, Len, "cheri_inv_free");
    Value *More = HB.CreateICmpULT(KNext, Bound, "cheri.flog.more");
    Instruction *Back = HB.CreateCondBr(More, Header, Exit);
    K->addIncoming(KNext, Header);
    Back->setMetadata(LLVMContext::MD_loop, flogLoopMetadata(Ctx));
    ++FLogLoops;
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
      Value *D = B.CreateSub(N1, N0, "cheri.flog.d");
      // D == 0 skips the whole bundle. Required, not just a fast path: the
      // loop below is bottom-tested and would otherwise read an older entry.
      Instruction *Then = SplitBlockAndInsertIfThen(
          B.CreateICmpNE(D, B.getInt64(0), "cheri.flog.nz"),
          &*B.GetInsertPoint(), false);
      if (FLogCheck != 0)
        emitFlogLoop(Then, N1, D, Ss);
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
    // D91/D92: a free or scope end still clears registers when this function
    // has no frame capability slot for the existing range checks.
    // M7.1a: a move fact is cleared even when this function has no other
    // capability slot for the range checks.
    bool HasMove = false;
    bool HasLoanInto = false;
    if (Loan)
      for (Instruction &I : instructions(F)) {
        if (memannot::isMemMoveFact(&I))
          HasMove = true;
        if (memannot::isMemLoanIntoFact(&I)) {
          ++LoanIntoFacts;
          HasLoanInto = true;
        } else if (memannot::isMemLoanIntoValFact(&I)) {
          ++LoanIntoValFacts;
          HasLoanInto = true;
        } else if (auto *CB = dyn_cast<CallBase>(&I))
          if (memannot::isMemFact(CB) &&
              CB->getOperandBundle(memannot::TagLoanIntoPromoted))
            ++LoanIntoSkippedPromoted;
      }
    bool RegFree = InvCapReg && (Free || AFLog);
    bool RegScope = InvCapReg && Scope;
    // M7.1b: a loan_into fact is scanned even when this function has no other
    // frame capability slot. A promoted marker is only counted.
    if (CapSlots.empty() && WideByAlloca.empty() && !RegFree && !RegScope &&
        !HasMove && !HasLoanInto)
      return;
    DominatorTree DT(F);
    buildCallReach(F);
    if (!CapSlots.empty()) {
      collectLoanSlots(F);
      if (Loan)
        loanClears(F, DT);
    }
    // Before flogCalls: that splits blocks. The free-log loop is unchanged.
    if (HasMove)
      moveClears(F, DT);
    // Plan while the CFG (and DT) still match the incoming IR. Emit after
    // flogCalls, which splits blocks; the carrier's next instruction stays.
    if (Loan && HasLoanInto) {
      loanIntoPlan(F, DT);
      loanIntoValPlan(F, DT);
    }
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
        Value *Op = E->getArgOperand(E->arg_size() - 1)->stripPointerCasts();
        auto *A = dyn_cast<AllocaInst>(getUnderlyingObject(Op));
        B.SetInsertPoint(E);
        if (A && A->isStaticAlloca()) {
          std::optional<TypeSize> Sz = A->getAllocationSize(DL);
          if (Sz && !Sz->isScalable()) {
            ++ScopeEvents;
            if (InvOwnNullEff) {
              auto NullWord = [&](int64_t Off) {
                Value *P = Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), A, Off) : A;
                markClear(B.CreateAlignedStore(
                    ConstantPointerNull::get(PointerType::get(M.getContext(), 200)), P,
                    Align(16), InvVolatile), "cheri_inv_own");
                ++OwnNulled;
              };
              if (auto It = CapSlots.find(A); It != CapSlots.end())
                for (int64_t Off : It->second)
                  NullWord(Off);
              // Widened words are own-nulled here and nowhere else.
              if (auto W = WideByAlloca.find(A); W != WideByAlloca.end())
                for (int64_t Off : W->second) {
                  NullWord(Off);
                  ++OwnNulledWide;
                }
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
        }
        // D94: only when a real call follows. D99 tags a non-escaping alloca
        // so the late pass can drop it unless the register was spilled. The
        // pseudo is placed just after the last real use (D100), not at
        // lifetime.end, so the live range does not cross a later call.
        if (RegScope && callAfter(E))
          emitCapRegsKind(B, A ? static_cast<Value *>(A) : Op, E, DT,
                          CapRegScope, KindScopeLocal);
      }
    auto clearFreedReg = [&](CallBase *C, Instruction *At) {
      if (!At)
        return;
      Value *P = C->getOperandBundle(memannot::TagFree)->Inputs[0];
      if (!DL.isFatPointer(P->getType()))
        return;
      B.SetInsertPoint(At);
      // D91: the pointer passed to dealloc and dominating copies. Aflog
      // records base/length before the call; this clear is after it, and
      // after any frame-slot range check inserted at the same point.
      emitCapRegs(B, P, At, DT, CapRegFree);
    };
    if (Free)
      for (CallBase *C : Frees) {
        // A musttail must be the instruction before the return. Inserting
        // the free clear after it is invalid IR, and it is not a zero site.
        if (isa<InvokeInst>(C))
          continue;
        if (auto *CI = dyn_cast<CallInst>(C))
          if (CI->isMustTailCall())
            continue;
        Value *P = C->getOperandBundle(memannot::TagFree)->Inputs[0];
        if (!DL.isFatPointer(P->getType()))
          continue;
        Instruction *At = C->getNextNode();
        ++FreeEvents;
        B.SetInsertPoint(C);
        Value *Lo = B.CreateCall(decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}), {P});
        Value *Len = B.CreateCall(decl(Intrinsic::cheri_cap_length_get, {B.getInt64Ty()}), {P});
        B.SetInsertPoint(At);
        for (auto &[S, Offs] : CapSlots) {
          if (!liveAt(S, C, DT) || !readLater(S, C, DT))
            continue;
          for (int64_t Off : Offs)
            if (mayHoldHeap({S, Off}) && !loanCovered(S, Off, C))
              checkAndClear(B, {S, Off}, Lo, Len, "cheri_inv_free");
        }
        // Slots not read again. Non-escaping: plain null. Escaping fixed
        // slots are already range-checked above (escape counts as a later
        // read there). Escaping widened words are not in that set.
        if (FreeDeadOpt == FreeDeadToggle::On) {
          SmallPtrSet<AllocaInst *, 8> SeenA;
          auto ClearDead = [&](AllocaInst *A, ArrayRef<int64_t> Offs,
                               bool WideOnly) {
            if (!SeenA.insert(A).second && !WideOnly)
              return;
            if (!liveAt(A, C, DT) || readAfter(A, C, DT))
              return;
            bool Esc = escapes(A);
            for (int64_t Off : Offs) {
              if (loanCovered(A, Off, C))
                continue;
              if (Esc) {
                if (!WideOnly)
                  continue;
                checkAndClear(B, {A, Off}, Lo, Len, "cheri_inv_free");
                ++FreeDeadChecked;
              } else {
                Value *P = Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), A, Off)
                               : A;
                markClear(B.CreateAlignedStore(
                              ConstantPointerNull::get(
                                  PointerType::get(M.getContext(), 200)),
                              P, Align(16), InvVolatile),
                          "cheri_inv_free_dead");
                ++FreeDeadPlain;
              }
            }
          };
          for (auto &[A, Offs] : CapSlots)
            ClearDead(A, Offs, false);
          for (auto &[A, Offs] : WideByAlloca)
            ClearDead(A, Offs, true);
        }
        clearFreedReg(C, At);
      }
    else if (RegFree)
      for (CallBase *C : Frees) {
        if (isa<InvokeInst>(C))
          continue;
        if (auto *CI = dyn_cast<CallInst>(C))
          if (CI->isMustTailCall())
            continue;
        clearFreedReg(C, C->getNextNode());
      }
    // Out-of-line drop: the mem.free is in the callee. Slots that still hold
    // a capability derived from the dropped owner, and are not read again,
    // are cleared here. Same plain-null / range-check split as an inline free.
    if (FreeDeadOpt == FreeDeadToggle::On &&
        FreeDeadCallsOpt == FreeDeadToggle::On) {
      for (Instruction &I : instructions(F)) {
        auto *C = dyn_cast<CallBase>(&I);
        if (!C || C->getOperandBundle(memannot::TagFree) || C->isInlineAsm())
          continue;
        if (!isOwnerFreeCall(*C) && !takesMovedOwner(*C, DT))
          continue;
        if (auto *CI = dyn_cast<CallInst>(C))
          if (CI->isMustTailCall())
            continue;
        Instruction *At = C->getNextNode();
        if (!At)
          continue;
        struct DeadHit {
          AllocaInst *A;
          int64_t Off;
          const Value *Bounds;
        };
        SmallVector<DeadHit, 8> Plain, Checked;
        auto Consider = [&](AllocaInst *A, int64_t Off,
                            ArrayRef<const Value *> Aliases, const Value *Owner) {
          const Value *Heap = nullptr;
          if (!slotHoldsOwner(A, Off, Aliases, &Heap))
            return;
          if (!liveAt(A, C, DT) || readAfter(A, C, DT) || loanCovered(A, Off, C))
            return;
          const Value *Bounds = Heap ? Heap : Owner;
          if (escapes(A))
            Checked.push_back({A, Off, Bounds});
          else
            Plain.push_back({A, Off, nullptr});
        };
        for (Value *Owner : C->args()) {
          if (!DL.isFatPointer(Owner->getType()))
            continue;
          if (memannot::isDeallocCall(*C)) {
            const Function *CF = C->getCalledFunction();
            StringRef N = CF ? CF->getName() : "";
            bool NamedDrop = N.contains("drop_in_place") || N.contains("drop_glue");
            if (!NamedDrop) {
              unsigned Idx = 0;
              bool ND = false;
              for (; Idx < C->arg_size(); ++Idx)
                if (C->getArgOperand(Idx) == Owner &&
                    C->paramHasAttr(Idx, Attribute::NoUndef))
                  ND = true;
              if (!ND)
                continue;
            }
          }
          SmallVector<const Value *, 4> Aliases;
          ownerAliases(Owner, C, DT, Aliases);
          Plain.clear();
          Checked.clear();
          for (auto &[A, Offs] : CapSlots)
            for (int64_t Off : Offs)
              Consider(A, Off, Aliases, Owner);
          for (auto &[A, Offs] : WideByAlloca)
            for (int64_t Off : Offs)
              Consider(A, Off, Aliases, Owner);
          B.SetInsertPoint(At);
          for (const DeadHit &H : Plain) {
            Value *P = H.Off ? B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), H.A, H.Off)
                             : H.A;
            markClear(B.CreateAlignedStore(
                          ConstantPointerNull::get(
                              PointerType::get(M.getContext(), 200)),
                          P, Align(16), InvVolatile),
                      "cheri_inv_free_dead");
            ++FreeDeadCallPlain;
          }
          DenseMap<const Value *, std::pair<Value *, Value *>> Bounds;
          for (const DeadHit &H : Checked) {
            auto &BL = Bounds[H.Bounds];
            if (!BL.first) {
              B.SetInsertPoint(C);
              BL.first = B.CreateCall(
                  decl(Intrinsic::cheri_cap_base_get, {B.getInt64Ty()}),
                  {const_cast<Value *>(H.Bounds)});
              BL.second = B.CreateCall(
                  decl(Intrinsic::cheri_cap_length_get, {B.getInt64Ty()}),
                  {const_cast<Value *>(H.Bounds)});
              B.SetInsertPoint(At);
            }
            checkAndClear(B, {H.A, H.Off}, BL.first, BL.second, "cheri_inv_free");
            ++FreeDeadCallChecked;
          }
        }
      }
    }
    if (FLog && !CapSlots.empty())
      flogCalls(F, CapSlots, DT); // last DT user: it splits blocks
    if (Loan && !PendingLoanInto.empty())
      loanIntoEmit();
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
         << " flog_calls=" << FLogCalls << " flog_loops=" << FLogLoops
         << " flog_nofree=" << FLogNoFree
         << " aflog_skip_free=" << AFLogSkipFree << " aflog_skip_call=" << AFLogSkipCall
         << " capreg_loan=" << CapRegLoan << " capreg_free=" << CapRegFree
         << " capreg_scope=" << CapRegScope << " move_nulls=" << MoveNulls
         << " move_null_skipped_live=" << MoveNullSkippedLive
         << " loan_into_facts=" << LoanIntoFacts
         << " loan_into_scans=" << LoanIntoScans
         << " loan_into_nulls=" << LoanIntoNulls
         << " loan_into_skipped_freed=" << LoanIntoSkippedFreed
         << " loan_into_skipped_moved=" << LoanIntoSkippedMoved
         << " loan_into_moved_live=" << LoanIntoMovedLive
         << " loan_into_freed_wipe=" << LoanIntoFreedWipe
         << " loan_into_skipped_promoted=" << LoanIntoSkippedPromoted
         << " loan_into_skipped_noval=" << LoanIntoSkippedNoval
         << " loan_into_val_facts=" << LoanIntoValFacts
         << " loan_into_skipped_val_freed=" << LoanIntoSkippedValFreed
         << " loan_into_skipped_val_reassigned=" << LoanIntoSkippedValReassigned
         << " wide_allocas=" << WideAllocas
         << " wide_skipped_large=" << WideSkippedLarge
         << " own_nulled_wide=" << OwnNulledWide
         << " free_dead_plain=" << FreeDeadPlain
         << " free_dead_checked=" << FreeDeadChecked
         << " free_dead_call_plain=" << FreeDeadCallPlain
         << " free_dead_call_checked=" << FreeDeadCallChecked
         << "\n";
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

// [LLM-generated] M7.1c. One switch for the IR planting, the helper attribute,
// the tail-call demotion, and the backend cmoves. Off leaves those calls as
// they were before this pass.
enum class FreeZeroToggle { Off, On };
static cl::opt<FreeZeroToggle> FreeZeroRegsOpt(
    "cheri-free-zero-regs", cl::init(FreeZeroToggle::On), cl::Hidden,
    cl::desc("M7.1c: after a mem.free call, cmove dead caller-saved "
             "capability registers to cnull (purecap)"),
    cl::values(clEnumValN(FreeZeroToggle::Off, "off", "do not zero"),
               clEnumValN(FreeZeroToggle::On, "on",
                          "zero (default on purecap)")));

bool memannot::cheriFreeZeroRegsEnabled() {
  return FreeZeroRegsOpt == FreeZeroToggle::On;
}

// [LLM-generated] M7.1c-2c-narrow. Bench was paying for a cmove at every dead
// CSR, including fmt and base64, where the epilogue restore already drops the
// capability. Default mayfree plants a clear only across a free.
enum class DeadCapToggle { Off, MayFree, All };
static cl::opt<DeadCapToggle> DeadCapOpt(
    "cheri-invalidate-dead-csr", cl::init(DeadCapToggle::MayFree), cl::Hidden,
    cl::desc("M7.1c-2c: null a dead callee-saved capability and a dead "
             "capability spill slot"),
    cl::values(clEnumValN(DeadCapToggle::Off, "off", "do not clear"),
               clEnumValN(DeadCapToggle::MayFree, "mayfree",
                          "only across a mem.free or moved-owner call (default)"),
               clEnumValN(DeadCapToggle::All, "all",
                          "across any later call or return")));

memannot::CheriDeadCapMode memannot::cheriDeadCapMode() {
  switch (DeadCapOpt) {
  case DeadCapToggle::Off:
    return CheriDeadCapMode::Off;
  case DeadCapToggle::All:
    return CheriDeadCapMode::All;
  case DeadCapToggle::MayFree:
    return CheriDeadCapMode::MayFree;
  }
  return CheriDeadCapMode::MayFree;
}

// [LLM-generated] M7.1c-2c-narrow. Tag may-free calls before ISel, on a
// DominatorTree that lives only for this function. LowerCall reads the
// attribute; it does not rebuild a tree. A process-wide cache here races
// when rustc runs ISel on many codegen units at once.
static void tagMayFreeCalls(Module &M) {
  for (Function &F : M) {
    if (F.isDeclaration())
      continue;
    DominatorTree DT(F);
    const DataLayout &DL = M.getDataLayout();
    SmallVector<std::pair<const Instruction *, const Value *>, 4> Moves;
    SmallVector<std::tuple<const Instruction *, const Value *, const Value *>, 4>
        Xfers;
    for (const Instruction &J : instructions(F)) {
      if (memannot::isMemMoveFact(&J)) {
        if (const Value *Slot = memannot::slotClobber(&J))
          Moves.emplace_back(&J, getUnderlyingObject(Slot));
      }
      if (const auto *MT = dyn_cast<MemTransferInst>(&J))
        Xfers.emplace_back(MT, getUnderlyingObject(MT->getRawDest()),
                           getUnderlyingObject(MT->getRawSource()));
    }
    auto takesMoved = [&](const CallBase &CB) {
      for (const Value *Arg : CB.args()) {
        if (!DL.isFatPointer(Arg->getType()))
          continue;
        const Value *U = getUnderlyingObject(Arg);
        for (auto [Fact, Mv] : Moves)
          if (DT.dominates(Fact, &CB) && U == Mv)
            return true;
        for (auto [MT, Dest, Src] : Xfers) {
          if (!DT.dominates(MT, &CB) || Dest != U)
            continue;
          for (auto [Fact, Mv] : Moves)
            if (DT.dominates(Fact, &CB) && Src == Mv)
              return true;
        }
      }
      return false;
    };
    for (Instruction &I : instructions(F)) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      bool MayFree = false;
      if (CB->getOperandBundle(memannot::TagFree))
        MayFree = true;
      else if (!CB->isInlineAsm()) {
        if (const Function *CF = CB->getCalledFunction()) {
          StringRef N = CF->getName();
          if (N.contains("drop_in_place") || N.contains("drop_glue"))
            MayFree = true;
        }
        if (!MayFree && memannot::isDeallocCall(*CB))
          MayFree = true;
        if (!MayFree && takesMoved(*CB))
          MayFree = true;
      }
      if (MayFree)
        CB->addFnAttr(Attribute::get(CB->getContext(), "cheri-may-free"));
    }
  }
}

bool memannot::runCheriInvalidate(Module &M) {
  // [LLM-generated] M7.1c. An out-of-line "mem.free" call is the end of that
  // free: zero after it returns. A helper that only inherited the bundle
  // (a wipe inside an inlined allocator) carries "cheri-free-inner" and is
  // not that point; the inliner plants llvm.riscv.cheri.free.zero at the
  // inlined returns instead. The attribute survives strip and is visible to
  // LowerCall. !pcsections on the call is not: SelectionDAG asserts when the
  // call has no SDNode.
  //
  // A tail call never returns, so the zero after it would be dead. Clearing
  // the tail marker makes this call return into the existing zero. musttail
  // is left alone: lowering rejects a musttail that is not a tail call, and
  // nothing may be placed after it, so it gets no zero either. Off skips
  // this whole loop, so the call stays a tail call and gains no attribute.
  if (memannot::cheriFreeZeroRegsEnabled()) {
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      for (Instruction &I : instructions(F)) {
        auto *CB = dyn_cast<CallBase>(&I);
        if (!CB || CB->isInlineAsm() || !CB->getOperandBundle(memannot::TagFree))
          continue;
        if (CB->hasFnAttr("cheri-free-inner"))
          continue;
        if (const Function *Callee = CB->getCalledFunction())
          if (Callee->isIntrinsic())
            continue;
        if (auto *CI = dyn_cast<CallInst>(CB)) {
          if (CI->isMustTailCall())
            continue;
          if (CI->isTailCall())
            CI->setTailCallKind(CallInst::TCK_None);
        }
        CB->addFnAttr(Attribute::get(CB->getContext(), "cheri-free-regs"));
      }
    }
  }
  StringRef Mode = InvalidateOpt;
  bool All = Mode == "all";
  // [LLM-generated] R10 (D73 default): "slite" = scope without own nulls.
  bool SLite = Mode.contains("slite");
  bool Scope = All || Mode.contains("scope") || SLite;
  InvOwnNullEff = InvOwnNull && !(SLite && !Mode.contains("scope") && !All);
  bool Free = All || Mode.contains("free");
  bool Loan = All || Mode.contains("loan");
  bool FLogOn = Mode.contains("flog");
  if (Scope || Free || Loan || FLogOn || !InvStatsOut.empty()) {
    Inv I(M, Scope, Free, Loan);
    I.FLog = FLogOn;
    I.AFLog = Mode.contains("aflog");
    I.run();
  }
  // After invalidation, before stripAnnotations drops mem.free bundles and
  // mem.move facts. The attribute is copied when a bundled call is rebuilt.
  if (cheriDeadCapMode() == CheriDeadCapMode::MayFree)
    tagMayFreeCalls(M);
  return Scope || Free || Loan || FLogOn;
}
