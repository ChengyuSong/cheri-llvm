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
// If the reaching def is a reload from an RA spill slot, that slot is also
// stored as null, before any later use of the frame index. Callee-saved
// save slots are never nulled.
//
// D89: loan ids are not attached to MachineMemOperands. The carriers are
// !pcsections on the IR slot clear and this pseudo on the register.
//===----------------------------------------------------------------------===//

#include "RISCV.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
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

static bool definesReg(const MachineInstr &MI, Register R,
                       const TargetRegisterInfo &TRI) {
  return any_of(MI.operands(), [&](const MachineOperand &MO) {
    return MO.isReg() && MO.isDef() && MO.getReg().isValid() &&
           TRI.regsOverlap(MO.getReg(), R);
  });
}

static MachineInstr *reachingDef(MachineInstr &Use, Register R,
                                 const TargetRegisterInfo &TRI) {
  MachineBasicBlock *MBB = Use.getParent();
  if (R.isVirtual())
    return MBB->getParent()->getRegInfo().getVRegDef(R);
  MachineInstr *Def = nullptr;
  for (auto It = MBB->begin(); It != Use.getIterator(); ++It)
    if (definesReg(*It, R, TRI))
      Def = &*It;
  return Def;
}

static MachineInstr *followCopies(MachineInstr *Def, const TargetRegisterInfo &TRI) {
  for (unsigned N = 0; Def && Def->isCopy() && N < 4; ++N) {
    Register Src = Def->getOperand(1).getReg();
    if (!Src.isValid())
      break;
    MachineInstr *Next = reachingDef(*Def, Src, TRI);
    if (!Next || Next == Def)
      break;
    Def = Next;
  }
  return Def;
}

static std::optional<int> reloadSpillFI(MachineInstr &MI) {
  unsigned Opc = MI.getOpcode();
  if (Opc != RISCV::CLC_128 && Opc != RISCV::CLC_64 && Opc != RISCV::LC_128 &&
      Opc != RISCV::LC_64)
    return std::nullopt;
  for (const MachineOperand &MO : MI.operands())
    if (MO.isFI())
      return MO.getIndex();
  return std::nullopt;
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
  for (MachineInstr *MI : Work) {
    Register Rs = MI->getOperand(0).getReg();
    if (MachineInstr *Def = followCopies(reachingDef(*MI, Rs, TRI), TRI)) {
      if (std::optional<int> FI = reloadSpillFI(*Def)) {
        // RA spill only. A callee-saved save slot holds the incoming
        // register, not this loan, and is left alone.
        if (MFI.isSpillSlotObjectIndex(*FI) && !isCalleeSavedSlot(MFI, *FI)) {
          unsigned StoreOpc = RISCV::CSC_128;
          switch (Def->getOpcode()) {
          case RISCV::CLC_64:
            StoreOpc = RISCV::CSC_64;
            break;
          case RISCV::LC_64:
            StoreOpc = RISCV::SC_64;
            break;
          case RISCV::LC_128:
            StoreOpc = RISCV::SC_128;
            break;
          default:
            break;
          }
          Align Alignment = MFI.getObjectAlign(*FI);
          MachineMemOperand *MMO = MF.getMachineMemOperand(
              MachinePointerInfo::getFixedStack(MF, *FI),
              MachineMemOperand::MOStore | MachineMemOperand::MOVolatile,
              MFI.getObjectSize(*FI), Alignment);
          // D89: volatile store, no loan id on the MMO.
          BuildMI(*MI->getParent(), MI, MI->getDebugLoc(), TII.get(StoreOpc))
              .addReg(RISCV::X0_Y)
              .addFrameIndex(*FI)
              .addImm(0)
              .addMemOperand(MMO);
        }
      }
    }
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
