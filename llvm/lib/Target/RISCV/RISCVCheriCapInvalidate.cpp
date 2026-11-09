//===- RISCVCheriCapInvalidate.cpp - Clear a loan capability register -----===//
// [LLM-generated] M6.0 D87.
//
// llvm.cheri.cap.invalidate becomes PseudoCheriCapInvalidate (a use of the
// capability). This pass, after RA and before PEI, replaces it with
// PseudoCheriCapClear, which defines that same register. A loan that RA put
// in a callee-saved register is therefore null before any later call, so the
// callee cannot save the loan into its own frame. PEI creates the prologue
// save of that incoming register later, and a slot already recorded in
// CalleeSavedInfo is never written: that save is the caller's value.
//
// Spill slots that still hold the value are stored as null. The search walks
// backward from the clear across blocks (D93): at most 16 blocks, 128
// instructions, and 8 predecessors at a join, and it does not re-enter a
// block already on the walk. A slot is nulled at the clear only when every
// path still holds the value there. When paths hold different slots, each
// slot is nulled at the end of its predecessor if the clear block does not
// use that slot first. A search that hits a bound nulls no slot. Callee-saved
// save slots are never written.
//
// D89: loan ids are not attached to MachineMemOperands. The carriers are
// !pcsections on the IR slot clear and this pseudo on the register.
//
// D97: the clear is a new def. Emit it only when the register is not read
// again before a later def, on any path. A live register (stack-colored
// address, pointer compared after free, hoisted cap used on the next
// iteration) keeps its pseudo dropped. A spill slot is nulled only when no
// later reload of that slot happens before a store.
// D98: a csetbounds of that frame address is the capability the program
// dereferences. Clear that register where it dies in the same block.
// D99 drops a non-escaping scope clear unless the register was spilled.
// D100 does not split an edge, and does not clear a callee-saved scope
// register that no call can save before it is overwritten.
// D101 drops a scope clear overwritten within 8 straight-line instructions.
// D102 drops a repeated clear of the same register on one path.
// D103: a loop backedge is not a spill-search abort.
//===----------------------------------------------------------------------===//

#include "RISCV.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/IR/MemAnnot.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include <optional>

using namespace llvm;

#define DEBUG_TYPE "riscv-cheri-cap-invalidate"

namespace {

class RISCVCheriCapInvalidate : public MachineFunctionPass {
public:
  static char ID;
  RISCVCheriCapInvalidate() : MachineFunctionPass(ID) {
    initializeRISCVCheriCapInvalidatePass(*PassRegistry::getPassRegistry());
  }
  bool runOnMachineFunction(MachineFunction &MF) override;
  bool doFinalization(Module &) override;
  StringRef getPassName() const override {
    return "RISC-V CHERI capability invalidate";
  }
};

class RISCVCheriCapInvalidateExpand : public MachineFunctionPass {
public:
  static char ID;
  RISCVCheriCapInvalidateExpand() : MachineFunctionPass(ID) {
    initializeRISCVCheriCapInvalidateExpandPass(
        *PassRegistry::getPassRegistry());
  }
  bool runOnMachineFunction(MachineFunction &MF) override;
  StringRef getPassName() const override {
    return "RISC-V CHERI capability invalidate expand";
  }
};

} // namespace

char RISCVCheriCapInvalidate::ID = 0;
char RISCVCheriCapInvalidateExpand::ID = 0;

INITIALIZE_PASS(RISCVCheriCapInvalidate, "riscv-cheri-cap-invalidate",
                "RISC-V CHERI capability invalidate", false, false)
INITIALIZE_PASS(RISCVCheriCapInvalidateExpand, "riscv-cheri-cap-invalidate-expand",
                "RISC-V CHERI capability invalidate expand", false, false)

static bool regsExact(ArrayRef<Register> Regs, Register R) {
  return is_contained(Regs, R);
}

static bool regsHold(ArrayRef<Register> Regs, Register R,
                     const TargetRegisterInfo &TRI) {
  return any_of(Regs, [&](Register X) {
    return X.isValid() && R.isValid() && TRI.regsOverlap(X, R);
  });
}

static void regsRemove(SmallVectorImpl<Register> &Regs, Register R,
                       const TargetRegisterInfo &TRI) {
  erase_if(Regs, [&](Register X) {
    return X.isValid() && R.isValid() && TRI.regsOverlap(X, R);
  });
}

static void regsAdd(SmallVectorImpl<Register> &Regs, Register R,
                    const TargetRegisterInfo &TRI) {
  if (R.isValid() && !regsHold(Regs, R, TRI))
    Regs.push_back(R);
}

static std::optional<int> frameIndexOf(const MachineInstr &MI) {
  for (const MachineOperand &MO : MI.operands())
    if (MO.isFI())
      return MO.getIndex();
  return std::nullopt;
}

static unsigned storeOpcForReload(unsigned Opc) {
  switch (Opc) {
  case RISCV::CLC_64:
    return RISCV::CSC_64;
  case RISCV::LC_64:
    return RISCV::SC_64;
  case RISCV::LC_128:
    return RISCV::SC_128;
  default:
    return RISCV::CSC_128;
  }
}

static bool isSpillReload(unsigned Opc) {
  return Opc == RISCV::CLC_128 || Opc == RISCV::CLC_64 || Opc == RISCV::LC_128 ||
         Opc == RISCV::LC_64;
}

static bool isSpillStore(unsigned Opc) {
  return Opc == RISCV::CSC_128 || Opc == RISCV::CSC_64 || Opc == RISCV::SC_128 ||
         Opc == RISCV::SC_64;
}

// D93. Backward search from the clear. `Holds` ends as the slots that still
// contain the value on every path. `OnPath` records a slot that holds it on
// only some predecessors.
struct SpillSearch {
  static constexpr unsigned MaxInst = 128;
  static constexpr unsigned MaxBlocks = 16;
  static constexpr unsigned MaxPreds = 8;
  explicit SpillSearch(const TargetRegisterInfo &TRI) : TRI(TRI) {}
  const TargetRegisterInfo &TRI;
  unsigned InstLeft = MaxInst;
  unsigned BlocksLeft = MaxBlocks;
  SmallPtrSet<MachineBasicBlock *, 16> Active;
  MapVector<MachineBasicBlock *, SmallVector<std::pair<int, unsigned>, 2>> OnPath;

  void note(SmallSet<int, 4> &Holds, SmallSet<int, 4> &Killed,
            DenseMap<int, unsigned> &Opc, int FI, unsigned StoreOpc) {
    if (Killed.count(FI))
      return;
    auto It = Opc.find(FI);
    if (It != Opc.end() && It->second != StoreOpc) {
      Killed.insert(FI);
      Holds.erase(FI);
      return;
    }
    Holds.insert(FI);
    Opc[FI] = StoreOpc;
  }

  // Ok: Holds is valid. Stop: a budget was hit, null nothing. Cycle: this
  // block is already on the walk; its instructions are scanned by that
  // visit, so the backedge adds nothing and must not abort the search (D103).
  enum class Result { Ok, Stop, Cycle };

  Result walk(MachineBasicBlock *MBB, MachineBasicBlock::iterator Stop,
              SmallVector<Register, 4> Regs, SmallSet<int, 4> &Holds,
              SmallSet<int, 4> &Killed, DenseMap<int, unsigned> &Opc) {
    if (!Active.insert(MBB).second)
      return Result::Cycle;
    if (BlocksLeft-- == 0) {
      memannot::noteSpillSearchAbort();
      return Result::Stop;
    }
    auto Leave = make_scope_exit([&] { Active.erase(MBB); });
    for (auto It = Stop; It != MBB->begin();) {
      if (InstLeft-- == 0) {
        memannot::noteSpillSearchAbort();
        return Result::Stop;
      }
      --It;
      MachineInstr &I = *It;
      std::optional<int> FI = frameIndexOf(I);
      if (FI && isSpillStore(I.getOpcode()) && I.getOperand(0).isReg()) {
        if (!Holds.count(*FI) && !Killed.count(*FI)) {
          Register Src = I.getOperand(0).getReg();
          // Exact register only. An overlapping integer view (x10 vs x10_y)
          // is a different value; nulling that slot zeros a live integer.
          if (regsExact(Regs, Src))
            note(Holds, Killed, Opc, *FI, I.getOpcode());
          else
            Killed.insert(*FI);
        }
      }
      SmallVector<Register, 4> Defs;
      for (const MachineOperand &MO : I.operands())
        if (MO.isReg() && MO.isDef() && MO.getReg().isValid() &&
            regsHold(Regs, MO.getReg(), TRI))
          Defs.push_back(MO.getReg());
      if (Defs.empty())
        continue;
      if (Defs.size() == 1 && regsExact(Regs, Defs[0]) && I.isCopy() &&
          I.getOperand(1).isReg()) {
        regsRemove(Regs, Defs[0], TRI);
        regsAdd(Regs, I.getOperand(1).getReg(), TRI);
      } else if (Defs.size() == 1 && regsExact(Regs, Defs[0]) && FI &&
                 isSpillReload(I.getOpcode())) {
        regsRemove(Regs, Defs[0], TRI);
        note(Holds, Killed, Opc, *FI, storeOpcForReload(I.getOpcode()));
      } else {
        for (Register D : Defs)
          regsRemove(Regs, D, TRI);
      }
      if (Regs.empty())
        return Result::Ok;
    }
    if (Regs.empty() || MBB->pred_empty())
      return Result::Ok;
    if (MBB->pred_size() > MaxPreds) {
      memannot::noteSpillSearchAbort();
      return Result::Stop;
    }
    if (MBB->pred_size() == 1) {
      MachineBasicBlock *P = *MBB->pred_begin();
      Result R = walk(P, P->end(), Regs, Holds, Killed, Opc);
      // A backedge has no instructions this visit did not already scan.
      return R == Result::Cycle ? Result::Ok : R;
    }
    SmallVector<SmallSet<int, 4>, 4> PerH;
    SmallVector<DenseMap<int, unsigned>, 4> PerO;
    SmallVector<MachineBasicBlock *, 4> Preds;
    for (MachineBasicBlock *P : MBB->predecessors()) {
      SmallSet<int, 4> H = Holds;
      SmallSet<int, 4> K = Killed;
      DenseMap<int, unsigned> O = Opc;
      Result R = walk(P, P->end(), Regs, H, K, O);
      if (R == Result::Stop)
        return Result::Stop;
      if (R == Result::Cycle)
        continue;
      PerH.push_back(std::move(H));
      PerO.push_back(std::move(O));
      Preds.push_back(P);
    }
    if (PerH.empty())
      return Result::Ok;
    SmallSet<int, 4> Inter;
    DenseMap<int, unsigned> InterOpc;
    for (int FI : PerH[0]) {
      unsigned Op = PerO[0].lookup(FI);
      if (!Op)
        continue;
      bool All = true;
      for (size_t i = 1; i < PerH.size(); ++i) {
        if (!PerH[i].count(FI) || PerO[i].lookup(FI) != Op) {
          All = false;
          break;
        }
      }
      if (!All)
        continue;
      Inter.insert(FI);
      InterOpc[FI] = Op;
    }
    for (size_t i = 0; i < Preds.size(); ++i)
      for (int FI : PerH[i])
        if (!Inter.count(FI) && PerO[i].lookup(FI))
          OnPath[Preds[i]].push_back({FI, PerO[i].lookup(FI)});
    Holds = std::move(Inter);
    Opc = std::move(InterOpc);
    return Result::Ok;
  }
};

static bool definesOverlap(const MachineInstr &MI, Register R,
                           const TargetRegisterInfo &TRI);

// A real read of R. The invalidate pseudo is the marker we are placing, not a
// later use of the value. Debug uses do not keep the capability alive.
static bool readsReg(const MachineInstr &MI, Register R,
                     const TargetRegisterInfo &TRI) {
  if (MI.isDebugInstr() || MI.getOpcode() == RISCV::PseudoCheriCapInvalidate)
    return false;
  for (const MachineOperand &MO : MI.operands())
    if (MO.isReg() && MO.isUse() && MO.getReg() &&
        TRI.regsOverlap(MO.getReg(), R))
      return true;
  return false;
}

static bool readFromBegin(MachineBasicBlock &MBB, Register R,
                          const TargetRegisterInfo &TRI,
                          SmallPtrSetImpl<MachineBasicBlock *> &Seen,
                          unsigned &Budget);

// True if any path from It reads R before a def. A search that runs out of
// budget reports a read, so the register is left alone.
static bool readRange(MachineBasicBlock &MBB, MachineBasicBlock::iterator It,
                      Register R, const TargetRegisterInfo &TRI,
                      SmallPtrSetImpl<MachineBasicBlock *> &Seen,
                      unsigned &Budget) {
  for (; It != MBB.end(); ++It) {
    if (Budget-- == 0)
      return true;
    if (It->isDebugInstr())
      continue;
    if (readsReg(*It, R, TRI))
      return true;
    if (definesOverlap(*It, R, TRI))
      return false;
  }
  for (MachineBasicBlock *S : MBB.successors())
    if (readFromBegin(*S, R, TRI, Seen, Budget))
      return true;
  return false;
}

static bool readFromBegin(MachineBasicBlock &MBB, Register R,
                          const TargetRegisterInfo &TRI,
                          SmallPtrSetImpl<MachineBasicBlock *> &Seen,
                          unsigned &Budget) {
  if (!Seen.insert(&MBB).second)
    return false;
  return readRange(MBB, MBB.begin(), R, TRI, Seen, Budget);
}

// D97. True when no path reads R after MI before a later def. This follows
// real uses, so a stale live-in that exists only because of the pseudo itself
// does not keep the register alive. Callee-saved restores are inserted by PEI
// after this pass and are not reads of this value.
static bool deadAfter(MachineInstr &MI, Register R,
                      const TargetRegisterInfo &TRI) {
  SmallPtrSet<MachineBasicBlock *, 16> Seen;
  unsigned Budget = 256;
  return !readRange(*MI.getParent(), std::next(MI.getIterator()), R, TRI, Seen,
                    Budget);
}

// True when some successor reads R before redefining it.
static bool liveAtEnd(MachineBasicBlock &MBB, Register R,
                      const TargetRegisterInfo &TRI) {
  SmallPtrSet<MachineBasicBlock *, 16> Seen;
  unsigned Budget = 256;
  for (MachineBasicBlock *S : MBB.successors())
    if (readFromBegin(*S, R, TRI, Seen, Budget))
      return true;
  return false;
}

static bool blockReads(MachineBasicBlock &MBB, Register R,
                       const TargetRegisterInfo &TRI) {
  SmallPtrSet<MachineBasicBlock *, 16> Seen;
  unsigned Budget = 256;
  return readFromBegin(MBB, R, TRI, Seen, Budget);
}

static bool isBoundsOpc(unsigned Opc) {
  return Opc == RISCV::CSetBounds || Opc == RISCV::CSetBoundsExact ||
         Opc == RISCV::CSetBoundsImm || Opc == RISCV::CSetBoundsRoundDown;
}

static bool definesOverlap(const MachineInstr &MI, Register R,
                           const TargetRegisterInfo &TRI) {
  for (const MachineOperand &MO : MI.operands())
    if (MO.isReg() && MO.isDef() && MO.getReg() &&
        TRI.regsOverlap(MO.getReg(), R))
      return true;
  return false;
}

// Found: every reaching def is this frame index. Cycle: this path only
// carries a value already being resolved. Unknown: not a frame address.
enum class FrameReach { Unknown, Cycle, Found };
struct FrameRes {
  FrameReach Kind = FrameReach::Unknown;
  int FI = -1;
  static FrameRes unknown() { return {}; }
  static FrameRes cycle() { return {FrameReach::Cycle, -1}; }
  static FrameRes found(int FI) { return {FrameReach::Found, FI}; }
};

static FrameRes
frameAddrAt(Register Want, MachineBasicBlock &MBB,
            MachineBasicBlock::iterator End, bool Inclusive,
            const TargetRegisterInfo &TRI,
            SmallPtrSetImpl<MachineBasicBlock *> &Walking, unsigned Depth);

// Follow a copy, a bounds op, or a register cincoffset to the frame index.
static FrameRes frameAddrFromDef(MachineInstr &Def, Register Want,
                                 const TargetRegisterInfo &TRI,
                                 unsigned Depth) {
  auto Chase = [&](Register Next) -> FrameRes {
    SmallPtrSet<MachineBasicBlock *, 8> Walking;
    return frameAddrAt(Next, *Def.getParent(), Def.getIterator(), false, TRI,
                       Walking, Depth + 1);
  };
  unsigned Opc = Def.getOpcode();
  if (Opc == RISCV::CIncOffsetImm || Opc == RISCV::CIncOffset) {
    if (std::optional<int> FI = frameIndexOf(Def))
      return FrameRes::found(*FI);
    if (Def.getNumOperands() > 1 && Def.getOperand(1).isReg())
      return Chase(Def.getOperand(1).getReg());
    return FrameRes::unknown();
  }
  if (Def.isCopy() && Def.getOperand(0).isReg() && Def.getOperand(1).isReg() &&
      TRI.regsOverlap(Def.getOperand(0).getReg(), Want))
    return Chase(Def.getOperand(1).getReg());
  if (isBoundsOpc(Opc) && Def.getOperand(1).isReg())
    return Chase(Def.getOperand(1).getReg());
  return FrameRes::unknown();
}

static bool blockDefines(MachineBasicBlock &MBB, Register Want,
                         const TargetRegisterInfo &TRI) {
  for (MachineInstr &I : MBB)
    if (definesOverlap(I, Want, TRI))
      return true;
  return false;
}

// Frame index of the address in Want at End. End is exclusive unless
// Inclusive. A predecessor that only carries Want (a loop backedge, or a
// side path into that backedge) is the same value as the definition outside
// the loop; it does not veto the frame index.
static FrameRes
frameAddrAt(Register Want, MachineBasicBlock &MBB,
            MachineBasicBlock::iterator End, bool Inclusive,
            const TargetRegisterInfo &TRI,
            SmallPtrSetImpl<MachineBasicBlock *> &Walking, unsigned Depth) {
  if (Depth > 12 || !Want)
    return FrameRes::unknown();
  MachineInstr *Def = nullptr;
  for (auto It = MBB.begin(); It != End; ++It)
    if (definesOverlap(*It, Want, TRI))
      Def = &*It;
  if (Inclusive && End != MBB.end() && definesOverlap(*End, Want, TRI))
    Def = &*End;
  if (Def)
    return frameAddrFromDef(*Def, Want, TRI, Depth);
  if (!Walking.insert(&MBB).second)
    return FrameRes::cycle();
  FrameRes Common = FrameRes::cycle();
  for (MachineBasicBlock *P : MBB.predecessors()) {
    if (P->empty())
      return FrameRes::unknown();
    if (Walking.count(P) && !blockDefines(*P, Want, TRI))
      continue;
    FrameRes FI =
        frameAddrAt(Want, *P, std::prev(P->end()), true, TRI, Walking, Depth + 1);
    if (FI.Kind == FrameReach::Unknown)
      return FI;
    if (FI.Kind == FrameReach::Cycle)
      continue;
    if (Common.Kind == FrameReach::Cycle)
      Common = FI;
    else if (Common.FI != FI.FI)
      return FrameRes::unknown();
  }
  return Common;
}

static std::optional<int> frameAddrFI(Register R, MachineInstr &At,
                                      const TargetRegisterInfo &TRI) {
  SmallPtrSet<MachineBasicBlock *, 8> Walking;
  FrameRes Rch = frameAddrAt(R, *At.getParent(), At.getIterator(), false, TRI,
                            Walking, 0);
  if (Rch.Kind != FrameReach::Found)
    return std::nullopt;
  return Rch.FI;
}

// D97 spill rule. True if any path reloads FI after Start before storing it.
// An aborted search is treated as a reload so the slot is left alone.
static bool reloadBeforeStoreRec(MachineBasicBlock &MBB,
                                 MachineBasicBlock::iterator It, int FI,
                                 SmallPtrSetImpl<MachineBasicBlock *> &Stack,
                                 unsigned &Budget, unsigned &Blocks) {
  if (!Stack.insert(&MBB).second || ++Blocks > 16) {
    memannot::noteSpillSearchAbort();
    return true;
  }
  auto Leave = make_scope_exit([&] { Stack.erase(&MBB); });
  for (; It != MBB.end(); ++It) {
    if (Budget-- == 0) {
      memannot::noteSpillSearchAbort();
      return true;
    }
    std::optional<int> Got = frameIndexOf(*It);
    if (!Got || *Got != FI)
      continue;
    if (It->mayLoad())
      return true;
    if (It->mayStore())
      return false;
  }
  for (MachineBasicBlock *S : MBB.successors())
    if (reloadBeforeStoreRec(*S, S->begin(), FI, Stack, Budget, Blocks))
      return true;
  return false;
}
static bool reloadBeforeStore(MachineBasicBlock &MBB,
                              MachineBasicBlock::iterator Start, int FI) {
  SmallPtrSet<MachineBasicBlock *, 16> Stack;
  unsigned Budget = 128, Blocks = 0;
  return reloadBeforeStoreRec(MBB, Start, FI, Stack, Budget, Blocks);
}

// Loan/free, escaping scope, local scope. Matches the intrinsic immediate.
static constexpr int KindLoanFree = 0;
static constexpr int KindScopeEscape = 1;
static constexpr int KindScopeLocal = 2;
// D101. A dead register overwritten this soon, with no call and no branch
// in between, is not saved by a callee and has no path that skips the
// overwrite. Eight instructions covers the move/offset/bounds setup that
// reuses the register after a scope without treating the epilogue as soon.
static constexpr unsigned SoonRedefWindow = 8;

static int pseudoKind(const MachineInstr &MI) {
  if (MI.getNumOperands() > 1 && MI.getOperand(1).isImm())
    return MI.getOperand(1).getImm();
  return KindLoanFree;
}

static bool isCalleeSavedReg(Register R, const MachineFunction &MF,
                             const TargetRegisterInfo &TRI) {
  for (const MCPhysReg *CS = TRI.getCalleeSavedRegs(&MF); CS && *CS; ++CS)
    if (TRI.regsOverlap(*CS, R))
      return true;
  return false;
}

// A call clobbers every caller-saved register. A callee-saved register
// survives, which is why a clear before that call matters.
static bool callClobbers(const MachineInstr &MI, Register R,
                         const MachineFunction &MF,
                         const TargetRegisterInfo &TRI) {
  if (!MI.isCall() || MI.getOpcode() == RISCV::PseudoCheriCapInvalidate)
    return false;
  if (MI.isMetaInstruction())
    return false;
  return !isCalleeSavedReg(R, MF, TRI);
}

// D101. Scope only. A def that does not read R, or a call that clobbers a
// caller-saved R, within SoonRedefWindow instructions in this block.
static bool soonRedef(MachineInstr &MI, Register R, const MachineFunction &MF,
                      const TargetRegisterInfo &TRI) {
  unsigned N = 0;
  for (auto It = std::next(MI.getIterator()); It != MI.getParent()->end();
       ++It) {
    if (It->isDebugInstr())
      continue;
    if (callClobbers(*It, R, MF, TRI))
      return true;
    if (It->isCall() || It->isBranch() || It->isTerminator())
      return false;
    if (definesOverlap(*It, R, TRI) && !readsReg(*It, R, TRI))
      return true;
    if (++N >= SoonRedefWindow)
      return false;
  }
  return false;
}

// D100. True when some path reaches a call before R is redefined.
static bool callBeforeRedef(MachineInstr &MI, Register R,
                            const TargetRegisterInfo &TRI) {
  SmallPtrSet<MachineBasicBlock *, 16> Seen;
  unsigned Budget = 64;
  auto Walk = [&](auto &Self, MachineBasicBlock &BB,
                  MachineBasicBlock::iterator It) -> bool {
    for (; It != BB.end(); ++It) {
      if (Budget-- == 0)
        return true;
      if (It->isDebugInstr())
        continue;
      if (It->isCall() && It->getOpcode() != RISCV::PseudoCheriCapInvalidate &&
          !It->isMetaInstruction())
        return true;
      if (definesOverlap(*It, R, TRI))
        return false;
    }
    for (MachineBasicBlock *S : BB.successors()) {
      if (!Seen.insert(S).second)
        continue;
      if (Self(Self, *S, S->begin()))
        return true;
    }
    return false;
  };
  return Walk(Walk, *MI.getParent(), std::next(MI.getIterator()));
}

static bool isCalleeSavedSlot(const MachineFrameInfo &MFI, int FI) {
  for (const CalleeSavedInfo &CS : MFI.getCalleeSavedInfo())
    if (CS.getFrameIdx() == FI)
      return true;
  return false;
}

bool RISCVCheriCapInvalidate::runOnMachineFunction(MachineFunction &MF) {
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  if (!ST.hasVendorXCheri() && !ST.hasVendorXCheriot())
    return false;
  const TargetRegisterInfo &TRI = *ST.getRegisterInfo();
  const TargetInstrInfo &TII = *ST.getInstrInfo();
  MachineFrameInfo &MFI = MF.getFrameInfo();
  bool Changed = false;
  SmallVector<MachineInstr *, 8> Work;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB)
      if (MI.getOpcode() == RISCV::PseudoCheriCapInvalidate)
        Work.push_back(&MI);
  struct NullAt {
    MachineBasicBlock *MBB;
    MachineInstr *Before; // null if at end of MBB
    int FI;
    unsigned Opc;
  };
  SmallVector<NullAt, 8> Nulls;
  auto usable = [&](int FI) {
    return MFI.isSpillSlotObjectIndex(FI) && !isCalleeSavedSlot(MFI, FI);
  };
  auto blockUses = [](MachineBasicBlock *MBB, MachineInstr *Until, int FI) {
    for (auto It = MBB->begin(); It != Until->getIterator(); ++It)
      for (const MachineOperand &MO : It->operands())
        if (MO.isFI() && MO.getIndex() == FI)
          return true;
    return false;
  };
  SmallSet<Register, 16> SpillRegs;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB) {
      if (!isSpillStore(MI.getOpcode()) && !isSpillReload(MI.getOpcode()))
        continue;
      if (MI.getOperand(0).isReg())
        SpillRegs.insert(MI.getOperand(0).getReg());
    }
  SmallVector<MachineInstr *, 8> Drop;
  SmallSet<int, 8> ScopeFIs;
  auto keepNull = [&](MachineBasicBlock *MBB, MachineInstr *Before, int FI,
                      unsigned StoreOpc) {
    if (!usable(FI) || !StoreOpc)
      return;
    MachineBasicBlock::iterator Start =
        Before ? std::next(Before->getIterator()) : MBB->begin();
    if (Before && reloadBeforeStore(*MBB, Start, FI))
      return;
    if (!Before && reloadBeforeStore(*MBB, MBB->getFirstTerminator(), FI))
      return;
    Nulls.push_back({MBB, Before, FI, StoreOpc});
  };
  for (MachineInstr *MI : Work) {
    Register Rs = MI->getOperand(0).getReg();
    int Kind = pseudoKind(*MI);
    bool Scope = Kind == KindScopeEscape || Kind == KindScopeLocal;
    auto noteFrame = [&]() {
      // D98 follows an escaping scope (and loan/free) to the bounded cap.
      // A local scope is cleared only when its own register was spilled.
      if (Kind == KindScopeLocal || Rs.isVirtual())
        return;
      if (std::optional<int> FI = frameAddrFI(Rs, *MI, TRI))
        ScopeFIs.insert(*FI);
    };
    if (Rs.isVirtual() || !deadAfter(*MI, Rs, TRI)) {
      // D97: a live register still holds a cap for a later read (colored
      // frame address, pointer compared after free). Drop the pseudo.
      Drop.push_back(MI);
      memannot::noteCapRegSkippedLive();
      noteFrame();
      continue;
    }
    bool HasSpill = SpillRegs.count(Rs);
    if (Kind == KindScopeLocal && !HasSpill) {
      // D99. Nothing stored this register to a spill slot, and the address
      // does not escape. The dead register is overwritten by later code.
      Drop.push_back(MI);
      memannot::noteCapRegSkippedNoEscape();
      continue;
    }
    // Null a spill even when the register clear itself is redundant. The
    // slot outlives the register.
    noteFrame();
    if (HasSpill) {
      SpillSearch Search(TRI);
      SmallSet<int, 4> Holds;
      SmallSet<int, 4> Killed;
      DenseMap<int, unsigned> Opc;
      SmallVector<Register, 4> Regs{Rs};
      if (Search.walk(MI->getParent(), MI->getIterator(), Regs, Holds, Killed,
                      Opc) == SpillSearch::Result::Ok) {
      for (int FI : Holds)
        if (unsigned StoreOpc = Opc.lookup(FI))
          keepNull(MI->getParent(), MI, FI, StoreOpc);
      for (auto &Path : Search.OnPath)
        for (auto [FI, StoreOpc] : Path.second) {
          if (blockUses(MI->getParent(), MI, FI))
            continue;
          keepNull(Path.first, nullptr, FI, StoreOpc);
        }
      }
    }
    if (Scope && soonRedef(*MI, Rs, MF, TRI)) {
      Drop.push_back(MI);
      memannot::noteCapRegSkippedSoonRedef();
      continue;
    }
    if (Scope && isCalleeSavedReg(Rs, MF, TRI) &&
        !callBeforeRedef(*MI, Rs, TRI)) {
      Drop.push_back(MI);
      memannot::noteCapRegSkippedCSR();
      continue;
    }
  }
  for (const NullAt &N : Nulls) {
    MachineBasicBlock::iterator At =
        N.Before ? N.Before->getIterator() : N.MBB->end();
    if (!N.Before) {
      if (auto Term = N.MBB->getFirstTerminator(); Term != N.MBB->end())
        At = Term;
    }
    DebugLoc DL;
    if (At != N.MBB->end())
      DL = At->getDebugLoc();
    Align Alignment = MFI.getObjectAlign(N.FI);
    // D89: volatile store, no loan id on the MMO.
    MachineMemOperand *MMO = MF.getMachineMemOperand(
        MachinePointerInfo::getFixedStack(MF, N.FI),
        MachineMemOperand::MOStore | MachineMemOperand::MOVolatile,
        MFI.getObjectSize(N.FI), Alignment);
    BuildMI(*N.MBB, At, DL, TII.get(N.Opc))
        .addReg(RISCV::X0_Y)
        .addFrameIndex(N.FI)
        .addImm(0)
        .addMemOperand(MMO);
    memannot::noteSpillNull();
    Changed = true;
  }
  // D98. A csetbounds of a frame address we tried to invalidate is the
  // capability later code dereferences. Clear that register only where it
  // is dead: after its last use, or on an edge into a block that does not
  // want it (the loop exit of a hoisted bounded cap).
  SmallSet<Register, 8> Bounded;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB) {
      if (!isBoundsOpc(MI.getOpcode()) || !MI.getOperand(0).isReg() ||
          !MI.getOperand(1).isReg())
        continue;
      std::optional<int> FI = frameAddrFI(MI.getOperand(1).getReg(), MI, TRI);
      if (!FI || !ScopeFIs.count(*FI))
        continue;
      bool FeedsClear = false;
      for (MachineInstr *P : Work) {
        std::optional<int> PFI = frameAddrFI(P->getOperand(0).getReg(), *P, TRI);
        if (!PFI || *PFI != *FI)
          continue;
        if (MI.getParent() == P->getParent()) {
          for (auto It = MI.getParent()->begin(); It != P->getIterator(); ++It)
            if (&*It == &MI)
              FeedsClear = true;
        } else {
          SmallPtrSet<MachineBasicBlock *, 8> Seen;
          SmallVector<MachineBasicBlock *, 4> Q(MI.getParent()->succ_begin(),
                                                MI.getParent()->succ_end());
          while (!Q.empty()) {
            MachineBasicBlock *BB = Q.pop_back_val();
            if (BB == P->getParent()) {
              FeedsClear = true;
              break;
            }
            if (!Seen.insert(BB).second)
              continue;
            Q.append(BB->succ_begin(), BB->succ_end());
          }
        }
        if (FeedsClear)
          break;
      }
      if (!FeedsClear)
        continue;
      Bounded.insert(MI.getOperand(0).getReg());
    }
  struct ClearAt {
    MachineBasicBlock *MBB;
    MachineInstr *Before; // null: at block end
    Register Reg;
  };
  struct EdgeClear {
    MachineBasicBlock *From;
    MachineBasicBlock *To;
    Register Reg;
  };
  SmallVector<ClearAt, 8> Extra;
  SmallVector<EdgeClear, 8> Edges;
  for (Register B : Bounded) {
    for (MachineBasicBlock &MBB : MF) {
      for (MachineInstr &MI : MBB) {
        if (!readsReg(MI, B, TRI) || !deadAfter(MI, B, TRI))
          continue;
        // A terminator reads the old value. Clearing after it in this block
        // is not valid MIR; the value is already dead on every outgoing edge.
        // A return has no successors, so a returned capability is kept.
        // D100/D101 also apply to the bounded register. It is a scope clear.
        if (soonRedef(MI, B, MF, TRI)) {
          memannot::noteCapRegSkippedSoonRedef();
          continue;
        }
        if (isCalleeSavedReg(B, MF, TRI) && !callBeforeRedef(MI, B, TRI)) {
          memannot::noteCapRegSkippedCSR();
          continue;
        }
        if (MI.isTerminator()) {
          for (MachineBasicBlock *S : MBB.successors())
            Edges.push_back({&MBB, S, B});
        } else
          Extra.push_back({&MBB, MI.getNextNode(), B});
      }
      if (!liveAtEnd(MBB, B, TRI))
        continue;
      for (MachineBasicBlock *S : MBB.successors()) {
        if (S == &MBB || blockReads(*S, B, TRI))
          continue;
        // D100. Clearing only on this edge needs a new block and a branch.
        Edges.push_back({&MBB, S, B});
      }
    }
  }
  SmallSet<std::pair<MachineBasicBlock *, Register>, 8> SeenClear;
  for (const ClearAt &C : Extra) {
    if (!SeenClear.insert({C.MBB, C.Reg}).second)
      continue;
    MachineBasicBlock::iterator At =
        C.Before ? C.Before->getIterator() : C.MBB->end();
    DebugLoc DL;
    if (At != C.MBB->end())
      DL = At->getDebugLoc();
    else if (!C.MBB->empty())
      DL = C.MBB->back().getDebugLoc();
    BuildMI(*C.MBB, At, DL, TII.get(RISCV::PseudoCheriCapClear), C.Reg)
        .addReg(C.Reg);
    Changed = true;
  }
  SmallSet<std::pair<std::pair<MachineBasicBlock *, MachineBasicBlock *>,
                     Register>,
           8>
      SeenEdge;
  for (const EdgeClear &E : Edges) {
    if (!SeenEdge.insert({{E.From, E.To}, E.Reg}).second)
      continue;
    memannot::noteCapRegSkippedEdge();
  }
  for (MachineInstr *MI : Work) {
    if (is_contained(Drop, MI))
      continue;
    Register Rs = MI->getOperand(0).getReg();
    BuildMI(*MI->getParent(), MI, MI->getDebugLoc(),
            TII.get(RISCV::PseudoCheriCapClear), Rs)
        .addReg(Rs);
    MI->eraseFromParent();
    Changed = true;
  }
  for (MachineInstr *MI : Drop) {
    MI->eraseFromParent();
    Changed = true;
  }
  // D102. A clear that dominates another clear of the same register, with no
  // def of that register in between, already killed it.
  SmallVector<MachineInstr *, 8> Clears;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB)
      if (MI.getOpcode() == RISCV::PseudoCheriCapClear)
        Clears.push_back(&MI);
  if (Clears.size() > 1) {
    MachineDominatorTree MDT(MF);
    SmallPtrSet<MachineInstr *, 8> Dup;
    auto redefined = [&](MachineInstr *From, MachineInstr *To, Register R) {
      SmallPtrSet<MachineBasicBlock *, 8> Seen;
      unsigned Budget = 32;
      auto Walk = [&](auto &Self, MachineBasicBlock &BB,
                      MachineBasicBlock::iterator It) -> bool {
        for (; It != BB.end(); ++It) {
          if (&*It == To)
            return false;
          if (Budget-- == 0)
            return true;
          if (It->getOpcode() == RISCV::PseudoCheriCapClear)
            continue;
          if (definesOverlap(*It, R, TRI))
            return true;
        }
        for (MachineBasicBlock *S : BB.successors()) {
          if (!Seen.insert(S).second)
            continue;
          if (Self(Self, *S, S->begin()))
            return true;
        }
        return false;
      };
      return Walk(Walk, *From->getParent(), std::next(From->getIterator()));
    };
    for (MachineInstr *A : Clears) {
      if (Dup.count(A))
        continue;
      Register RA = A->getOperand(0).getReg();
      for (MachineInstr *B : Clears) {
        if (A == B || Dup.count(B))
          continue;
        if (B->getOperand(0).getReg() != RA)
          continue;
        if (!MDT.dominates(A, B))
          continue;
        if (redefined(A, B, RA))
          continue;
        Dup.insert(B);
      }
    }
    for (MachineInstr *MI : Dup) {
      MI->eraseFromParent();
      memannot::noteCapRegSkippedDup();
      Changed = true;
    }
  }
  return Changed;
}

bool RISCVCheriCapInvalidate::doFinalization(Module &) {
  memannot::flushSpillInvalidateStats();
  return false;
}

bool RISCVCheriCapInvalidateExpand::runOnMachineFunction(MachineFunction &MF) {
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  if (!ST.hasVendorXCheri() && !ST.hasVendorXCheriot())
    return false;
  const TargetInstrInfo &TII = *ST.getInstrInfo();
  bool Changed = false;
  SmallVector<MachineInstr *, 8> Work;
  for (MachineBasicBlock &MBB : MF)
    for (MachineInstr &MI : MBB)
      if (MI.getOpcode() == RISCV::PseudoCheriCapClear)
        Work.push_back(&MI);
  for (MachineInstr *MI : Work) {
    Register Rd = MI->getOperand(0).getReg();
    BuildMI(*MI->getParent(), MI, MI->getDebugLoc(), TII.get(RISCV::CMove), Rd)
        .addReg(RISCV::X0_Y);
    MI->eraseFromParent();
    Changed = true;
  }
  return Changed;
}

FunctionPass *llvm::createRISCVCheriCapInvalidatePass() {
  return new RISCVCheriCapInvalidate();
}
FunctionPass *llvm::createRISCVCheriCapInvalidateExpandPass() {
  return new RISCVCheriCapInvalidateExpand();
}
