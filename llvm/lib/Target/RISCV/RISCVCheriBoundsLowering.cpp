//===- RISCVCheriBoundsLowering.cpp - M5r late CHERI pass (R0 stub) -------===//
// [LLM-generated] CHERI M5r R0/R1. Placed just before CheriBoundAllocas (and
// so before LoopStrengthReduce) in the RISC-V IR pipeline (at every opt
// level). In R0/R1 it makes no CHERI decisions:
// it runs the late annotation census and strips the annotations so ISel sees
// the same IR as without them. See llvm/Transforms/Utils/MemAnnotCensus.h.
#include "RISCV.h"
#include "llvm/IR/Module.h"
#include "llvm/Pass.h"
#include "llvm/Transforms/Utils/MemAnnotCensus.h"

using namespace llvm;

#define DEBUG_TYPE "riscv-cheri-bounds-lowering"

namespace {
struct RISCVCheriBoundsLowering : public ModulePass {
  static char ID;
  RISCVCheriBoundsLowering() : ModulePass(ID) {}
  StringRef getPassName() const override {
    return "RISC-V CHERI bounds lowering (M5r stub)";
  }
  bool runOnModule(Module &M) override {
    return memannot::runCheriBoundsLoweringStub(M);
  }
};
} // namespace

char RISCVCheriBoundsLowering::ID = 0;
INITIALIZE_PASS(RISCVCheriBoundsLowering, DEBUG_TYPE,
                "RISC-V CHERI bounds lowering (M5r stub)", false, false)

ModulePass *llvm::createRISCVCheriBoundsLoweringPass() {
  return new RISCVCheriBoundsLowering();
}
