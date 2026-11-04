//===- MemAnnot.h - Memory-safety annotation vocabulary (M5r) ---*- C++ -*-===//
//
// [LLM-generated] CHERI M5r R0: front ends pass information only; late
// target passes (CheriBoundsLowering) make every architecture decision.
//
// Vocabulary (R1; R0 had claim/free/invalidate as facts)
//   call void @llvm.mem.fact() [ "<tag>"(...) ]   one bundle per fact call
//     "mem.alloc_inbounds"(ptr P)                  P stays inside its allocation
//     "mem.inbounds"(ptr P, ptr Base, i64 Bytes)   P in [Base, Base+Bytes)
//     "mem.dropped"(...)                           a droppable fact that a
//                                                  pass dropped (census only)
//   %q = call ptr @llvm.mem.claim(ptr P, i64 Bytes, i64 Flags)
//                                                  q == P, valid for Bytes (D11)
//   call @free(...) [ "mem.free"(ptr Base) ]       the deallocation of Base
//   call @panic...(...) [ "mem.check"(ptr Base, i64 Len, i64 ElemSize,
//                          i64 Site, i64 Kind [, ptr ParentBase, i64 ParentLen]) ]
//                                                  the bounds check whose
//                                                  failure edge this call is
//   !mem.guard !{i64 Site}   on the guarded GEP/load/store (droppable hint)
//   !mem.last_use !{i64 Loan, ...}  last use of the loans (droppable hint;
//                                   kept on merge only if identical)
//   Storage-dead of a slot is llvm.lifetime.end.
//
// Fail-safe directions: losing !mem.guard, !mem.last_use, "mem.alloc_inbounds"
// or "mem.inbounds" only loses optimization. A claim must not be folded into
// its operand and "mem.free" must not be dropped. A "mem.check" bundle
// disappears only with its call.
//===----------------------------------------------------------------------===//
#ifndef LLVM_IR_MEMANNOT_H
#define LLVM_IR_MEMANNOT_H

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Compiler.h"
#include <cstdint>

namespace llvm {
class BasicBlock;
class CallBase;
class Instruction;
class MDNode;
class Value;
class DataLayout;

namespace memannot {
/// "mem.claim"="N": parameter/return attribute (not a bundle) read by the
/// inliner and late passes.
inline constexpr StringRef TagClaim = "mem.claim";
inline constexpr StringRef TagAllocInbounds = "mem.alloc_inbounds";
inline constexpr StringRef TagInbounds = "mem.inbounds";
/// "mem.free"(ptr base): operand bundle on a deallocation call (R1).
inline constexpr StringRef TagFree = "mem.free";
inline constexpr StringRef TagDropped = "mem.dropped";
inline constexpr StringRef TagCheck = "mem.check";
inline constexpr StringRef GuardMD = "mem.guard";
/// !mem.last_use !{i64 loan, ...}: last use of each loan on this path (R1).
inline constexpr StringRef LastUseMD = "mem.last_use";
/// [LLM-generated] M5r R5 (D35): rustc slot fact on a store: the stored value
/// is the reference of borrowck loan(s) !{i64 L, ...} (Track B loan-end).
inline constexpr StringRef LoanMD = "mem.loan";
/// R5: the LLVM inliner re-keys a cloned body's loan ids in bits 42..62; the
/// low bits keep the original id (census key).
inline constexpr uint64_t LoanKeyMask = (uint64_t(1) << 42) - 1;
inline constexpr StringRef IdMD = "mem.annot.id";
/// Set on a claim just before InstCombine folds it as object-exact (R1), so
/// the census can classify the RAUW as explained.
inline constexpr StringRef ObjectExactMD = "mem.claim.object_exact";

// mem.claim flags (bit layout, informational for R0).
enum ClaimKind : uint64_t {
  CK_Ref = 0, CK_Slice, CK_Str, CK_Box, CK_CStr, CK_RawRef, CK_Transmute,
  CK_MemOp, CK_Ret, CK_Param
};
enum ClaimFlags : uint64_t {
  CF_KindMask = 0xff,
  CF_Untrusted = 1u << 8,
  CF_Nullable = 1u << 9,
  /// R1: the claimed pointer comes from a rustc-verified producer (inlined
  /// Vec/Box Global scope); the late pass may discharge the claim.
  CF_Verified = 1u << 10,
};
enum CheckKind : uint64_t {
  CHK_Index = 0, CHK_RangeStart, CHK_RangeEnd, CHK_RangeOrder, CHK_CopyLen,
  CHK_RawChecked
};
enum CheckFlags : uint64_t {
  CHKF_KindMask = 0xff,
  /// R1: the guarded operation is a borrow (&a[i]), not an access; the check
  /// cannot be replaced by the hardware fault at the access.
  CHKF_Borrow = 1u << 8,
};

/// Any "mem." bundle tag (fact tags and "mem.check").
/// The legacy M2 "mem.checked" bundle (on llvm.cheri.cap.bounds.set, read by
/// CheriSkipNarrow) is not part of the M5r vocabulary and keeps its local/m5
/// treatment as an ordinary bundle.
inline bool isMemTag(StringRef Tag) {
  return Tag.starts_with("mem.") && Tag != "mem.checked";
}
/// Fact tags that may be dropped (losing them is fail-safe).
inline bool isDroppableFactTag(StringRef Tag) {
  return Tag == TagAllocInbounds || Tag == TagInbounds || Tag == TagDropped;
}
LLVM_ABI bool isMemFact(const Instruction *I);
/// llvm.mem.claim call (value-returning claim, D11).
LLVM_ABI bool isMemClaim(const Value *V);
/// Deallocation call that may carry a "mem.free" bundle: allockind("free"),
/// or free / c_free / __rust_dealloc / __rdl_dealloc / __rg_dealloc.
LLVM_ABI bool isDeallocCall(const CallBase &CB);
/// R1: \p Claim (an llvm.mem.claim call) claims exactly a whole stack or
/// global object: its operand is the object's start (constant offset 0) and
/// the claimed size equals the object's known size. Such a claim carries no
/// information beyond the allocation itself, so it can be folded into its
/// operand without losing anything a late pass could use.
LLVM_ABI bool isClaimObjectExact(const CallBase &Claim, const DataLayout &DL);
/// R1: \p V is (a constant in-range offset into) a stack or global object, so
/// "mem.alloc_inbounds"(V) is implied by the allocation itself.
LLVM_ABI bool isTriviallyAllocInbounds(const Value *V, const DataLayout &DL);
/// True if this call carries a "mem.check" bundle.
LLVM_ABI bool hasMemCheck(const CallBase &CB);
/// True if every operand bundle on \p CB is a "mem." bundle.
LLVM_ABI bool onlyMemBundles(const CallBase &CB);
/// R4 (D28): instructions that may carry !mem.last_use (memory accesses and
/// calls other than annotation intrinsics).
LLVM_ABI bool isLastUseCarrier(const Instruction &I);
/// R4 (D28): add the loan ids of LU to To's !mem.last_use.
LLVM_ABI void mergeLastUse(Instruction &To, MDNode *LU);
/// [LLM-generated] M5r R6 (D44): put loan ids that ended at the start of BB on
/// the next carrier on BB's unique forward path (fail-safe: lost if none).
LLVM_ABI void forwardLastUse(BasicBlock &BB, MDNode *LU);
} // namespace memannot
} // namespace llvm
#endif
