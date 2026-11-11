//===- RISCVCheriFrameWipe.cpp - Null caps left in the frame and a/t regs -===//
// [LLM-generated] M7.1c-1.
//
// Two post-PEI passes, purecap only.
//
// Frame wipe (-cheri-frame-wipe, default on). At each epilogue
// (MFI restore point / wherever emitEpilogue ran, including a shrink-wrapped
// block that is not itself a return), before the frame is deallocated:
//   * cnull every 16-byte spill slot (a capability, or anything that size);
//   * cnull every callee-saved save slot except ra/cra, after that register
//     has been restored.
// Fixed objects (the caller's frame, incoming arguments, the outgoing
// argument area) and tail-call outgoing arguments are not stack slots of
// this kind and are left alone. Returned values stay in registers. Allocas
// are M7.1c-2.
//
// Free-reg zero (-cheri-free-zero-regs, default on). LowerCall emits
// PseudoCheriFreeZero after a call that had the "cheri-free-regs" attribute
// (a "mem.free" call). This pass replaces that marker with cmove of every
// dead caller-saved capability register to cnull. Return-value registers of
// that call (realloc's ca0) and anything live after the call are kept.
//===----------------------------------------------------------------------===//

#include "RISCV.h"
#include "RISCVInstrInfo.h"
#include "RISCVMachineFunctionInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/CodeGen/LiveRegUnits.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/IR/MemAnnot.h"
#include "llvm/Support/MathExtras.h"

using namespace llvm;

#define DEBUG_TYPE "riscv-cheri-frame-wipe"

enum class Toggle { Off, On };
static cl::opt<Toggle> FrameWipeOpt(
    "cheri-frame-wipe", cl::init(Toggle::On), cl::Hidden,
    cl::desc("M7.1c: at each epilogue, store cnull over capability spill slots "
             "and callee-saved save slots except ra (purecap)"),
    cl::values(clEnumValN(Toggle::Off, "off", "do not wipe"),
               clEnumValN(Toggle::On, "on", "wipe (default on purecap)")));

static cl::opt<Toggle> FreeZeroOpt(
    "cheri-free-zero-regs", cl::init(Toggle::On), cl::Hidden,
    cl::desc("M7.1c: after a mem.free call, cmove dead caller-saved "
             "capability registers to cnull (purecap)"),
    cl::values(clEnumValN(Toggle::Off, "off", "do not zero"),
               clEnumValN(Toggle::On, "on", "zero (default on purecap)")));

namespace {

class RISCVCheriFrameWipe : public MachineFunctionPass {
public:
  static char ID;
  RISCVCheriFrameWipe() : MachineFunctionPass(ID) {
    initializeRISCVCheriFrameWipePass(*PassRegistry::getPassRegistry());
  }
  bool runOnMachineFunction(MachineFunction &MF) override;
  StringRef getPassName() const override {
    return "RISC-V CHERI frame wipe";
  }
};

class RISCVCheriFreeZeroRegs : public MachineFunctionPass {
public:
  static char ID;
  RISCVCheriFreeZeroRegs() : MachineFunctionPass(ID) {
    initializeRISCVCheriFreeZeroRegsPass(*PassRegistry::getPassRegistry());
  }
  bool runOnMachineFunction(MachineFunction &MF) override;
  StringRef getPassName() const override {
    return "RISC-V CHERI free-call register zero";
  }
};

} // namespace

char RISCVCheriFrameWipe::ID = 0;
char RISCVCheriFreeZeroRegs::ID = 0;

INITIALIZE_PASS(RISCVCheriFrameWipe, "riscv-cheri-frame-wipe",
                "RISC-V CHERI frame wipe", false, false)
INITIALIZE_PASS(RISCVCheriFreeZeroRegs, "riscv-cheri-free-zero-regs",
                "RISC-V CHERI free-call register zero", false, false)

static bool purecap(const MachineFunction &MF) {
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  return ST.hasVendorXCheri() &&
         RISCVABI::isCheriPureCapABI(ST.getTargetABI());
}

static bool isRA(Register R) {
  return R == RISCV::X1 || R == RISCV::X1_Y;
}

static unsigned capStoreOpc(const RISCVSubtarget &ST) {
  return ST.getXLen() == 32 ? RISCV::CSC_64 : RISCV::CSC_128;
}

static unsigned capLoadOpc(const RISCVSubtarget &ST) {
  return ST.getXLen() == 32 ? RISCV::CLC_64 : RISCV::CLC_128;
}

static void emitCNull(MachineBasicBlock &MBB, MachineBasicBlock::iterator At,
                      const RISCVInstrInfo &TII, unsigned Opc, Register Base,
                      int64_t Off, const DebugLoc &DL) {
  BuildMI(MBB, At, DL, TII.get(Opc))
      .addReg(RISCV::X0_Y)
      .addReg(Base)
      .addImm(Off)
      .setMIFlag(MachineInstr::FrameDestroy);
}

// SP-relative (or FP, while it still holds this frame) store of cnull.
static void emitSlotNull(MachineFunction &MF, MachineBasicBlock &MBB,
                         MachineBasicBlock::iterator At, int FI, int64_t Extra,
                         const DebugLoc &DL) {
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  const RISCVRegisterInfo *RI = ST.getRegisterInfo();
  const RISCVFrameLowering *TFI = ST.getFrameLowering();
  const RISCVInstrInfo &TII = *ST.getInstrInfo();
  Register FrameReg;
  StackOffset Off = TFI->getFrameIndexReference(MF, FI, FrameReg);
  if (Off.getScalable())
    return;
  int64_t Val = Off.getFixed() + Extra;
  unsigned Opc = capStoreOpc(ST);
  if (isInt<12>(Val)) {
    emitCNull(MBB, At, TII, Opc, FrameReg, Val, DL);
    return;
  }
  // The epilogue has already restored ra. ct0 is caller-saved and dead here.
  RI->adjustReg(MBB, At, DL, RISCV::X5_Y, FrameReg, StackOffset::getFixed(Val),
                MachineInstr::FrameDestroy, std::nullopt);
  emitCNull(MBB, At, TII, Opc, RISCV::X5_Y, 0, DL);
}

bool RISCVCheriFrameWipe::runOnMachineFunction(MachineFunction &MF) {
  if (FrameWipeOpt == Toggle::Off || !purecap(MF))
    return false;
  if (MF.getFunction().getCallingConv() == CallingConv::GHC)
    return false;

  MachineFrameInfo &MFI = MF.getFrameInfo();
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  unsigned LoadOpc = capLoadOpc(ST);
  SmallSet<int, 8> CSR, RA;
  for (const CalleeSavedInfo &CS : MFI.getCalleeSavedInfo()) {
    CSR.insert(CS.getFrameIdx());
    if (isRA(CS.getReg()))
      RA.insert(CS.getFrameIdx());
  }

  SmallVector<int, 8> Spills;
  for (int FI = MFI.getObjectIndexBegin(); FI < MFI.getObjectIndexEnd(); ++FI) {
    if (MFI.isDeadObjectIndex(FI) || MFI.isFixedObjectIndex(FI) ||
        MFI.isVariableSizedObjectIndex(FI))
      continue;
    if (MFI.getStackID(FI) != TargetStackID::Default)
      continue;
    if (CSR.count(FI))
      continue; // wiped after the restore, except ra
    if (!MFI.isSpillSlotObjectIndex(FI))
      continue;
    uint64_t Sz = MFI.getObjectSize(FI);
    if (Sz < 16)
      continue;
    Spills.push_back(FI);
  }

  bool Changed = false;
  unsigned Stores = 0;
  // PEI clears restore points after emitting the epilogue. The blocks it
  // touched still carry FrameDestroy: the shrink-wrap restore block, or each
  // return when shrink-wrap did not run.
  for (MachineBasicBlock &MBB : MF) {
    if (MBB.empty())
      continue;
    bool Epilogue = false;
    for (const MachineInstr &MI : MBB)
      if (MI.getFlag(MachineInstr::FrameDestroy)) {
        Epilogue = true;
        break;
      }
    if (!Epilogue)
      continue;
    MachineBasicBlock::iterator Term = MBB.getFirstTerminator();
    DebugLoc DL;
    if (Term != MBB.end())
      DL = Term->getDebugLoc();

    // Epilogue start: first FrameDestroy. Spill nulls go here, while SP/FP
    // still address the body frame and before the frame is popped.
    MachineBasicBlock::iterator Epi = Term;
    while (Epi != MBB.begin() &&
           std::prev(Epi)->getFlag(MachineInstr::FrameDestroy))
      --Epi;

    auto chunks = [&](int FI) {
      uint64_t Sz = MFI.getObjectSize(FI);
      unsigned N = Sz / 16;
      return N == 0 ? 1u : N;
    };
    if (Epi != Term) {
      for (int FI : Spills) {
        for (unsigned K = 0, N = chunks(FI); K < N; ++K) {
          emitSlotNull(MF, MBB, Epi, FI, K * 16, DL);
          ++Stores;
          Changed = true;
        }
      }
    }

    // After each callee-saved reload except ra, null that save slot. The
    // reload already has the SP offset PEI chose, so this stays correct
    // after the register itself has been restored.
    SmallVector<MachineInstr *, 8> Restores;
    for (MachineInstr &MI : MBB) {
      if (MI.getOpcode() == LoadOpc &&
          MI.getFlag(MachineInstr::FrameDestroy) && MI.getOperand(0).isReg() &&
          !isRA(MI.getOperand(0).getReg()) && MI.getOperand(1).isReg() &&
          MI.getOperand(2).isImm())
        Restores.push_back(&MI);
    }
    for (MachineInstr *MI : Restores) {
      emitCNull(MBB, std::next(MI->getIterator()), *ST.getInstrInfo(),
                capStoreOpc(ST), MI->getOperand(1).getReg(),
                MI->getOperand(2).getImm(), MI->getDebugLoc());
      ++Stores;
      Changed = true;
    }
  }

  unsigned Slots = Spills.size();
  for (int FI : CSR)
    if (!RA.count(FI) && MFI.getObjectSize(FI) >= 16)
      ++Slots;
  if (Stores) {
    std::string Line;
    raw_string_ostream OS(Line);
    OS << "cheri-frame-wipe: fn=" << MF.getName() << " slots=" << Slots
       << " stores=" << Stores;
    memannot::appendInvalidateStatsLine(OS.str());
  }
  return Changed;
}

static const MCPhysReg CallerSavedCaps[] = {
    RISCV::X5_Y,  RISCV::X6_Y,  RISCV::X7_Y,  RISCV::X28_Y,
    RISCV::X29_Y, RISCV::X30_Y, RISCV::X31_Y, RISCV::X10_Y,
    RISCV::X11_Y, RISCV::X12_Y, RISCV::X13_Y, RISCV::X14_Y,
    RISCV::X15_Y, RISCV::X16_Y, RISCV::X17_Y,
};

bool RISCVCheriFreeZeroRegs::runOnMachineFunction(MachineFunction &MF) {
  // Always drop the marker. Off (or a non-purecap target) leaves no cmoves.
  bool Emit = FreeZeroOpt == Toggle::On && purecap(MF);
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  const TargetRegisterInfo &TRI = *ST.getRegisterInfo();
  const TargetInstrInfo &TII = *ST.getInstrInfo();
  bool Changed = false;
  unsigned Sites = 0, Regs = 0;

  for (MachineBasicBlock &MBB : MF) {
    SmallVector<MachineInstr *, 4> Marks;
    for (MachineInstr &MI : MBB)
      if (MI.getOpcode() == RISCV::PseudoCheriFreeZero)
        Marks.push_back(&MI);
    for (MachineInstr *Mark : Marks) {
      // Find the call this marker follows, for its result defs.
      MachineInstr *Call = nullptr;
      for (auto It = Mark->getIterator(); It != MBB.begin();) {
        --It;
        if (It->isCall()) {
          Call = &*It;
          break;
        }
      }
      LiveRegUnits Live(TRI);
      Live.addLiveOuts(MBB);
      for (auto It = MBB.rbegin(); It != MBB.rend(); ++It) {
        if (&*It == Mark)
          break;
        Live.stepBackward(*It);
      }
      SmallVector<Register, 4> Ret;
      if (Call && !Call->isReturn()) {
        for (const MachineOperand &MO : Call->operands()) {
          if (!MO.isReg() || !MO.isDef() || MO.isDead() ||
              !MO.getReg().isPhysical())
            continue;
          Ret.push_back(MO.getReg());
        }
      }
      unsigned N = 0;
      MachineBasicBlock::iterator At = Mark->getIterator();
      if (!Emit) {
        Mark->eraseFromParent();
        Changed = true;
        continue;
      }
      for (MCPhysReg R : CallerSavedCaps) {
        if (!Live.available(R))
          continue;
        bool Returns = false;
        for (Register D : Ret)
          if (TRI.regsOverlap(R, D))
            Returns = true;
        if (Returns)
          continue;
        BuildMI(MBB, At, Mark->getDebugLoc(), TII.get(RISCV::CMove), R)
            .addReg(RISCV::X0_Y);
        ++N;
      }
      Mark->eraseFromParent();
      Changed = true;
      if (N) {
        ++Sites;
        Regs += N;
      }
    }
  }
  if (Sites) {
    std::string Line;
    raw_string_ostream OS(Line);
    OS << "cheri-free-zero: fn=" << MF.getName() << " sites=" << Sites
       << " regs=" << Regs;
    memannot::appendInvalidateStatsLine(OS.str());
  }
  return Changed;
}

FunctionPass *llvm::createRISCVCheriFrameWipePass() {
  return new RISCVCheriFrameWipe();
}
FunctionPass *llvm::createRISCVCheriFreeZeroRegsPass() {
  return new RISCVCheriFreeZeroRegs();
}
