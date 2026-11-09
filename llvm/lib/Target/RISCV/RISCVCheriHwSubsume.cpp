//===- RISCVCheriHwSubsume.cpp - Drop checks an exact cap already does ----===//
// [LLM-generated] M6.2 D105–D110.
//
// CheriBoundsLowering keeps the software compare when it will not remove it
// (borrows, raw checks under elide, unlinked markers, failed coverage,
// E_Never, the two-version slow path). This pass does not redo that. It only
// deletes a compare that a later exact, representable narrow already covers.
//
// On RV64 a constant length of at most 4095 is always representable
// (rv64Mask). CHERIoT's always-exact limit is 511 and is not used here.
// CSetBounds / CSetBoundsExact / CSetBoundsRoundDown are not this pattern.
//
// The slice is one block: CSetBoundsImm of that length, an unsigned compare
// of an index against it, and a branch to a panic block whose only
// predecessor is this branch. Every other use of the index must be a
// CIncOffset of that setbounds result (or of a GEP of it). The GEP result
// may only be loaded or stored, or copied / offset again under the same
// rule. A GEP that is stored, returned, or passed keeps the compare. The
// load or store is the dereference; CIncOffset itself does not fault.
// Requiring the pointer to derive from this setbounds result refuses a
// check whose access was sunk onto a different capability.
//
// At -O1 and above, MachineSink has already moved CSetBoundsImm into the
// success block before addPreRegAlloc. The setbounds is then not in the
// compare's block, the pattern does not match, and the compare stays.
// This pass does not look in another block for the setbounds.
//
// No !mem.guard, "mem.check", llvm.mem.fact, or llvm.mem.claim is read.
// The immediate and the loads and stores are the fact.
//===----------------------------------------------------------------------===//

#include "RISCV.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/MathExtras.h"

using namespace llvm;

#define DEBUG_TYPE "riscv-cheri-hw-subsume"

STATISTIC(NumSubsumed,
          "Bounds checks removed; an exact capability covers them");

namespace {

class RISCVCheriHwSubsume : public MachineFunctionPass {
public:
  static char ID;
  RISCVCheriHwSubsume() : MachineFunctionPass(ID) {
    initializeRISCVCheriHwSubsumePass(*PassRegistry::getPassRegistry());
  }
  bool runOnMachineFunction(MachineFunction &MF) override;
  StringRef getPassName() const override {
    return "RISC-V CHERI hardware-subsumed bounds check";
  }
};

// RV64 CSetBoundsImm lengths that are exactly representable. A length of 0
// is representable but has no in-bounds index, so it is not part of the
// pattern. 4096 does not fit uimm12 and must not be treated as exact.
constexpr uint64_t RV64ExactImmMax = 4095;

std::optional<int64_t> materializedImm(Register R,
                                      const MachineRegisterInfo &MRI,
                                      unsigned Depth = 0) {
  if (R == RISCV::X0)
    return 0;
  if (!R.isVirtual() || Depth > 4)
    return std::nullopt;
  const MachineInstr *Def = MRI.getVRegDef(R);
  if (!Def)
    return std::nullopt;
  if (Def->isCopy() && Def->getOperand(1).isReg())
    return materializedImm(Def->getOperand(1).getReg(), MRI, Depth + 1);
  // ADDI x0, simm12, or LUI+ADDI. ISel uses the latter once the constant
  // does not fit in simm12 (len-1 for a setbounds length above 2048).
  if (Def->getOpcode() == RISCV::ADDI && Def->getOperand(1).isReg() &&
      Def->getOperand(2).isImm()) {
    std::optional<int64_t> Base =
        materializedImm(Def->getOperand(1).getReg(), MRI, Depth + 1);
    if (!Base)
      return std::nullopt;
    return *Base + Def->getOperand(2).getImm();
  }
  if (Def->getOpcode() == RISCV::LUI && Def->getOperand(1).isImm())
    return SignExtend64(Def->getOperand(1).getImm() << 12, 32);
  return std::nullopt;
}

bool derivesFromCap(Register Ptr, Register Cap, const MachineRegisterInfo &MRI,
                    unsigned Depth = 0) {
  if (Ptr == Cap)
    return true;
  if (!Ptr.isVirtual() || Depth > 8)
    return false;
  const MachineInstr *Def = MRI.getVRegDef(Ptr);
  if (!Def)
    return false;
  unsigned Opc = Def->getOpcode();
  if (!Def->isCopy() && Opc != RISCV::CIncOffset && Opc != RISCV::CIncOffsetImm)
    return false;
  if (!Def->getOperand(1).isReg())
    return false;
  return derivesFromCap(Def->getOperand(1).getReg(), Cap, MRI, Depth + 1);
}

bool isCheriAddress(const MachineInstr &MI, Register P) {
  bool Store = false;
  switch (MI.getOpcode()) {
  case RISCV::CSB:
  case RISCV::CSH:
  case RISCV::CSW:
  case RISCV::CSD:
  case RISCV::CSC_64:
  case RISCV::CSC_128:
  case RISCV::CFSW:
  case RISCV::CFSD:
    Store = true;
    break;
  case RISCV::CLB:
  case RISCV::CLH:
  case RISCV::CLW:
  case RISCV::CLBU:
  case RISCV::CLHU:
  case RISCV::CLWU:
  case RISCV::CLD:
  case RISCV::CLC_64:
  case RISCV::CLC_128:
  case RISCV::CFLW:
  case RISCV::CFLD:
    break;
  default:
    return false;
  }
  // Storing or returning the capability is not a dereference of it.
  if (Store && MI.getOperand(0).isReg() && MI.getOperand(0).getReg() == P)
    return false;
  return MI.getNumOperands() > 1 && MI.getOperand(1).isReg() &&
         MI.getOperand(1).getReg() == P;
}

// The GEP (or the setbounds result, via a copy) is only loaded or stored.
bool pointerOnlyDereferenced(Register P, const MachineRegisterInfo &MRI,
                             unsigned Depth = 0) {
  if (!P.isVirtual() || Depth > 8)
    return false;
  bool Any = false;
  for (const MachineInstr &UI : MRI.use_nodbg_instructions(P)) {
    if (isCheriAddress(UI, P)) {
      Any = true;
      continue;
    }
    if (UI.isCopy() && UI.getOperand(1).isReg() &&
        UI.getOperand(1).getReg() == P && UI.getOperand(0).isReg() &&
        UI.getOperand(0).getReg().isVirtual()) {
      if (!pointerOnlyDereferenced(UI.getOperand(0).getReg(), MRI, Depth + 1))
        return false;
      Any = true;
      continue;
    }
    unsigned Opc = UI.getOpcode();
    if ((Opc == RISCV::CIncOffset || Opc == RISCV::CIncOffsetImm) &&
        UI.getOperand(1).isReg() && UI.getOperand(1).getReg() == P &&
        UI.getOperand(0).isReg()) {
      if (!pointerOnlyDereferenced(UI.getOperand(0).getReg(), MRI, Depth + 1))
        return false;
      Any = true;
      continue;
    }
    return false;
  }
  return Any;
}

// Every use of the index, other than the compare and uses in the panic
// block, is a non-escaping CIncOffset of Cap. At least one such use exists.
bool indexOnlyDereferenced(Register Idx, Register Cap, const MachineInstr *Br,
                           const MachineBasicBlock *Panic,
                           const MachineRegisterInfo &MRI, bool &Saw,
                           unsigned Depth = 0) {
  if (!Idx.isVirtual() || Depth > 8)
    return false;
  for (const MachineInstr &UI : MRI.use_nodbg_instructions(Idx)) {
    if (&UI == Br)
      continue;
    if (UI.getParent() == Panic)
      continue;
    if (UI.isCopy() && UI.getOperand(1).isReg() &&
        UI.getOperand(1).getReg() == Idx && UI.getOperand(0).isReg() &&
        UI.getOperand(0).getReg().isVirtual()) {
      if (!indexOnlyDereferenced(UI.getOperand(0).getReg(), Cap, nullptr, Panic,
                                 MRI, Saw, Depth + 1))
        return false;
      continue;
    }
    if (UI.getOpcode() == RISCV::CIncOffset && UI.getOperand(2).isReg() &&
        UI.getOperand(2).getReg() == Idx && UI.getOperand(1).isReg() &&
        derivesFromCap(UI.getOperand(1).getReg(), Cap, MRI) &&
        UI.getOperand(0).isReg() &&
        pointerOnlyDereferenced(UI.getOperand(0).getReg(), MRI)) {
      Saw = true;
      continue;
    }
    return false;
  }
  return true;
}

struct CmpMatch {
  Register Idx;
  Register ImmReg;
  MachineBasicBlock *Ok = nullptr;
  MachineBasicBlock *Panic = nullptr;
};

MachineBasicBlock *otherSuccessor(MachineBasicBlock &MBB,
                                 MachineBasicBlock *Taken) {
  MachineBasicBlock *Other = nullptr;
  for (MachineBasicBlock *S : MBB.successors()) {
    if (S == Taken)
      continue;
    if (Other)
      return nullptr;
    Other = S;
  }
  return Other;
}

// ISel lowers `icmp ult idx, Len` to either
//   BGEU idx, Len, panic / BLTU idx, Len, ok
// or, for a constant, ADDI x0, Len-1 and BLTU (Len-1), idx, panic
// (equivalently BGEU Len-1, idx, ok). Both are that compare.
std::optional<CmpMatch> matchUnsignedUlt(const MachineInstr &Br, uint64_t Len,
                                         const MachineRegisterInfo &MRI,
                                         MachineBasicBlock &MBB) {
  unsigned Opc = Br.getOpcode();
  if ((Opc != RISCV::BLTU && Opc != RISCV::BGEU) || Br.getNumOperands() < 3 ||
      !Br.getOperand(0).isReg() || !Br.getOperand(1).isReg() ||
      !Br.getOperand(2).isMBB())
    return std::nullopt;
  Register A = Br.getOperand(0).getReg();
  Register B = Br.getOperand(1).getReg();
  MachineBasicBlock *Taken = Br.getOperand(2).getMBB();
  MachineBasicBlock *Other = otherSuccessor(MBB, Taken);
  if (!Taken || !Other || Taken == Other)
    return std::nullopt;

  std::optional<int64_t> ImmA = materializedImm(A, MRI);
  std::optional<int64_t> ImmB = materializedImm(B, MRI);
  auto IsIndex = [](Register R, std::optional<int64_t> Imm) {
    return R.isVirtual() && !Imm;
  };
  const bool LenMinus1 = Len >= 1;

  CmpMatch M;
  if (Opc == RISCV::BLTU) {
    // A < B.
    if (ImmB && *ImmB == static_cast<int64_t>(Len) && IsIndex(A, ImmA)) {
      M = {A, B.isVirtual() ? B : Register(), Taken, Other};
    } else if (LenMinus1 && ImmA && *ImmA == static_cast<int64_t>(Len) - 1 &&
               IsIndex(B, ImmB)) {
      M = {B, A.isVirtual() ? A : Register(), Other, Taken};
    } else {
      return std::nullopt;
    }
  } else {
    // A >= B.
    if (ImmB && *ImmB == static_cast<int64_t>(Len) && IsIndex(A, ImmA)) {
      M = {A, B.isVirtual() ? B : Register(), Other, Taken};
    } else if (LenMinus1 && ImmA && *ImmA == static_cast<int64_t>(Len) - 1 &&
               IsIndex(B, ImmB)) {
      M = {B, A.isVirtual() ? A : Register(), Taken, Other};
    } else {
      return std::nullopt;
    }
  }
  if (!MBB.isSuccessor(M.Ok) || !MBB.isSuccessor(M.Panic))
    return std::nullopt;
  return M;
}

void eraseDeadImm(Register R, MachineRegisterInfo &MRI) {
  if (!R.isVirtual() || !MRI.use_nodbg_empty(R))
    return;
  MachineInstr *Def = MRI.getVRegDef(R);
  if (!Def)
    return;
  SmallVector<Register, 2> Next;
  unsigned Opc = Def->getOpcode();
  if (Def->isCopy() || Opc == RISCV::ADDI) {
    if (!Def->getOperand(1).isReg())
      return;
    if (Def->getOperand(1).getReg().isVirtual())
      Next.push_back(Def->getOperand(1).getReg());
  } else if (Opc != RISCV::LUI) {
    return;
  }
  Def->eraseFromParent();
  for (Register N : Next)
    eraseDeadImm(N, MRI);
}

bool subsumeBlock(MachineBasicBlock &MBB, const RISCVInstrInfo &TII,
                  MachineRegisterInfo &MRI) {
  MachineInstr *Br = nullptr;
  unsigned Terms = 0;
  for (MachineInstr &MI : MBB.terminators()) {
    ++Terms;
    if (MI.isConditionalBranch()) {
      if (Br)
        return false;
      Br = &MI;
    } else if (!MI.isUnconditionalBranch()) {
      return false;
    }
  }
  if (!Br || Terms > 2)
    return false;

  CmpMatch Found;
  int64_t Len = 0;
  bool Matched = false;
  for (MachineInstr &MI : MBB) {
    if (MI.getOpcode() != RISCV::CSetBoundsImm || MI.getNumOperands() < 3 ||
        !MI.getOperand(0).isReg() || !MI.getOperand(0).getReg().isVirtual() ||
        !MI.getOperand(2).isImm())
      continue;
    int64_t Imm = MI.getOperand(2).getImm();
    // Length 0 has no in-bounds index. The compare's success path is the
    // path the check rejects; deleting it would take that path. 4096 is not
    // an exact RV64 immediate (and does not fit uimm12).
    if (Imm < 1 || static_cast<uint64_t>(Imm) > RV64ExactImmMax)
      continue;
    Register Cap = MI.getOperand(0).getReg();
    std::optional<CmpMatch> Cmp =
        matchUnsignedUlt(*Br, static_cast<uint64_t>(Imm), MRI, MBB);
    if (!Cmp)
      continue;
    // Another predecessor means the panic block is still reached without
    // this capability. A PHI means it is not the trivial trap block.
    if (Cmp->Panic->pred_size() != 1 || *Cmp->Panic->pred_begin() != &MBB ||
        (!Cmp->Panic->empty() && Cmp->Panic->front().isPHI()))
      continue;
    bool Saw = false;
    if (!indexOnlyDereferenced(Cmp->Idx, Cap, Br, Cmp->Panic, MRI, Saw) || !Saw)
      continue;
    Found = *Cmp;
    Len = Imm;
    Matched = true;
    break;
  }
  if (!Matched)
    return false;

  DebugLoc DL = Br->getDebugLoc();
  TII.removeBranch(MBB);
  while (MBB.isSuccessor(Found.Panic))
    MBB.removeSuccessor(Found.Panic, /*NormalizeSuccProbs=*/true);
  if (!MBB.isSuccessor(Found.Ok))
    MBB.addSuccessor(Found.Ok);
  // Layout successor: the block falls through. Otherwise an unconditional
  // branch, the same edge CheriBoundsLowering::removeCheck keeps.
  if (!MBB.isLayoutSuccessor(Found.Ok))
    TII.insertBranch(MBB, Found.Ok, nullptr, {}, DL);
  eraseDeadImm(Found.ImmReg, MRI);
  ++NumSubsumed;
  LLVM_DEBUG(dbgs() << "hw-subsume: dropped check in " << printMBBReference(MBB)
                    << " len " << Len << "\n");
  (void)Len;
  return true;
}

} // namespace

char RISCVCheriHwSubsume::ID = 0;

INITIALIZE_PASS(RISCVCheriHwSubsume, "riscv-cheri-hw-subsume",
                "RISC-V CHERI hardware-subsumed bounds check", false, false)

bool RISCVCheriHwSubsume::runOnMachineFunction(MachineFunction &MF) {
  const RISCVSubtarget &ST = MF.getSubtarget<RISCVSubtarget>();
  // RV64 only. Do not apply the 4095 rule on CHERIoT (511) or RV32.
  if (!ST.is64Bit() || (!ST.hasVendorXCheri() && !ST.hasVendorXCheriot()))
    return false;
  MachineRegisterInfo &MRI = MF.getRegInfo();
  if (!MRI.isSSA())
    return false;
  const RISCVInstrInfo &TII = *ST.getInstrInfo();
  bool Changed = false;
  for (MachineBasicBlock &MBB : MF)
    Changed |= subsumeBlock(MBB, TII, MRI);
  return Changed;
}

FunctionPass *llvm::createRISCVCheriHwSubsumePass() {
  return new RISCVCheriHwSubsume();
}
