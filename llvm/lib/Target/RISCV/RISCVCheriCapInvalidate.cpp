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
//===----------------------------------------------------------------------===//

#include "RISCV.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallSet.h"
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

  bool walk(MachineBasicBlock *MBB, MachineBasicBlock::iterator Stop,
            SmallVector<Register, 4> Regs, SmallSet<int, 4> &Holds,
            SmallSet<int, 4> &Killed, DenseMap<int, unsigned> &Opc) {
    if (!Active.insert(MBB).second || BlocksLeft-- == 0)
      return false;
    auto Leave = make_scope_exit([&] { Active.erase(MBB); });
    for (auto It = Stop; It != MBB->begin();) {
      if (InstLeft-- == 0)
        return false;
      --It;
      MachineInstr &I = *It;
      std::optional<int> FI = frameIndexOf(I);
      if (FI && isSpillStore(I.getOpcode()) && I.getOperand(0).isReg()) {
        if (!Holds.count(*FI) && !Killed.count(*FI)) {
          Register Src = I.getOperand(0).getReg();
          if (regsHold(Regs, Src, TRI))
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
      if (Defs.size() == 1 && I.isCopy() && I.getOperand(1).isReg()) {
        regsRemove(Regs, Defs[0], TRI);
        regsAdd(Regs, I.getOperand(1).getReg(), TRI);
      } else if (Defs.size() == 1 && FI && isSpillReload(I.getOpcode())) {
        regsRemove(Regs, Defs[0], TRI);
        note(Holds, Killed, Opc, *FI, storeOpcForReload(I.getOpcode()));
      } else {
        for (Register D : Defs)
          regsRemove(Regs, D, TRI);
      }
      if (Regs.empty())
        return true;
    }
    if (Regs.empty() || MBB->pred_empty())
      return true;
    if (MBB->pred_size() > MaxPreds)
      return false;
    if (MBB->pred_size() == 1) {
      MachineBasicBlock *P = *MBB->pred_begin();
      return walk(P, P->end(), Regs, Holds, Killed, Opc);
    }
    SmallVector<SmallSet<int, 4>, 4> PerH;
    SmallVector<DenseMap<int, unsigned>, 4> PerO;
    SmallVector<MachineBasicBlock *, 4> Preds;
    for (MachineBasicBlock *P : MBB->predecessors()) {
      SmallSet<int, 4> H = Holds;
      SmallSet<int, 4> K = Killed;
      DenseMap<int, unsigned> O = Opc;
      if (!walk(P, P->end(), Regs, H, K, O))
        return false;
      PerH.push_back(std::move(H));
      PerO.push_back(std::move(O));
      Preds.push_back(P);
    }
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
    return true;
  }
};

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
  for (MachineInstr *MI : Work) {
    Register Rs = MI->getOperand(0).getReg();
    if (Rs.isVirtual()) {
      // Post-RA this pass sees physical registers. A virtual def is not a
      // spill slot we can name.
    } else {
      SpillSearch Search(TRI);
      SmallSet<int, 4> Holds;
      SmallSet<int, 4> Killed;
      DenseMap<int, unsigned> Opc;
      SmallVector<Register, 4> Regs{Rs};
      if (Search.walk(MI->getParent(), MI->getIterator(), Regs, Holds, Killed,
                      Opc)) {
        for (int FI : Holds)
          if (unsigned StoreOpc = Opc.lookup(FI); usable(FI) && StoreOpc)
            Nulls.push_back({MI->getParent(), MI, FI, StoreOpc});
        for (auto &Path : Search.OnPath) {
          for (auto [FI, StoreOpc] : Path.second) {
            if (!StoreOpc || !usable(FI) || blockUses(MI->getParent(), MI, FI))
              continue;
            Nulls.push_back({Path.first, nullptr, FI, StoreOpc});
          }
        }
      }
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
    Changed = true;
  }
  for (MachineInstr *MI : Work) {
    Register Rs = MI->getOperand(0).getReg();
    BuildMI(*MI->getParent(), MI, MI->getDebugLoc(),
            TII.get(RISCV::PseudoCheriCapClear), Rs)
        .addReg(Rs);
    MI->eraseFromParent();
    Changed = true;
  }
  return Changed;
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
