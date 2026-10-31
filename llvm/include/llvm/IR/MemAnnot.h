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
class CallBase;
class Instruction;
class Value;

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
inline constexpr StringRef IdMD = "mem.annot.id";

// mem.claim flags (bit layout, informational for R0).
enum ClaimKind : uint64_t {
  CK_Ref = 0, CK_Slice, CK_Str, CK_Box, CK_CStr, CK_RawRef, CK_Transmute,
  CK_MemOp, CK_Ret, CK_Param
};
enum ClaimFlags : uint64_t {
  CF_KindMask = 0xff,
  CF_Untrusted = 1u << 8,
  CF_Nullable = 1u << 9,
};
enum CheckKind : uint64_t {
  CHK_Index = 0, CHK_RangeStart, CHK_RangeEnd, CHK_RangeOrder, CHK_CopyLen,
  CHK_RawChecked
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
/// True if this call carries a "mem.check" bundle.
LLVM_ABI bool hasMemCheck(const CallBase &CB);
/// True if every operand bundle on \p CB is a "mem." bundle.
LLVM_ABI bool onlyMemBundles(const CallBase &CB);
} // namespace memannot
} // namespace llvm
#endif
