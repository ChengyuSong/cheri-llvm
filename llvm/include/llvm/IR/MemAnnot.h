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
//   call void @llvm.mem.fact() [ "mem.move"(ptr Slot) ]
//                                                  M7.1a: unique owner moved out
//                                                  of frame slot Slot. Not a loan
//                                                  id. The late pass may null Slot.
//   call @panic...(...) [ "mem.check"(ptr Base, i64 Len, i64 ElemSize,
//                          i64 Site, i64 Kind [, ptr ParentBase, i64 ParentLen]) ]
//                                                  the bounds check whose
//                                                  failure edge this call is
//   !mem.guard !{i64 Site}   on the guarded GEP/load/store (droppable hint)
//   !mem.last_use !{i64 Loan, ...}  last use of the loans (program point) on a
//                                   carrier, or the same tag as a bundle on
//                                   llvm.mem.fact when no carrier can hold it.
//                                   The fact is an architecture-neutral anchor:
//                                   it is not a CHERI clear. Dropping a sound
//                                   anchor loses the invalidation. Moving it
//                                   earlier than a remaining slot reload is not
//                                   fail-safe. Inliner copy keys that do not fit
//                                   in bits 42..62 become !{i64 orig, i64 disambiguator}.
//   !mem.loan !{i64 Loan, ...}      on the store of a borrowed reference.
//                                   A list of i64s is that many packed loans.
//                                   An extended copy is one operand
//                                   !{!"mem.loan.ext", i64 orig, i64 disambiguator},
//                                   never a bare !{i64, i64}.
//   Storage-dead of a slot is llvm.lifetime.end.
//
// Fail-safe directions: losing !mem.guard, "mem.alloc_inbounds" or
// "mem.inbounds" only loses optimization. A claim must not be folded into
// its operand and "mem.free" must not be dropped. A "mem.check" bundle
// disappears only with its call. A loan id must not be reused for a different
// loan in the same function. Nested inlining mixes the per-copy salt into the
// previous high bits and, if that field is full, keeps the copy as an extended
// id. A sound last-use is not dropped to pass an optimization.
//===----------------------------------------------------------------------===//
#ifndef LLVM_IR_MEMANNOT_H
#define LLVM_IR_MEMANNOT_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Compiler.h"
#include <cstdint>

namespace llvm {
class BasicBlock;
class CallBase;
class Instruction;
class LLVMContext;
class MDNode;
class Metadata;
class Value;
class DataLayout;
template <typename T> class SmallVectorImpl;

namespace memannot {
/// "mem.claim"="N": parameter/return attribute (not a bundle) read by the
/// inliner and late passes.
inline constexpr StringRef TagClaim = "mem.claim";
inline constexpr StringRef TagAllocInbounds = "mem.alloc_inbounds";
inline constexpr StringRef TagInbounds = "mem.inbounds";
/// "mem.free"(ptr base): operand bundle on a deallocation call (R1).
inline constexpr StringRef TagFree = "mem.free";
/// [LLM-generated] M7.1a: "mem.move"(ptr slot) on llvm.mem.fact. The unique
/// owner that lived in this frame slot was moved out at this program point.
/// The operand is the slot address (alloca, or a constant-offset GEP of one),
/// not a loan id. Not droppable: losing it loses the clear. Generic passes
/// must not sink it past a re-init or promote the slot out from under it.
inline constexpr StringRef TagMove = "mem.move";
/// [LLM-generated] M7.1b: "mem.loan_into"(ptr owner_ptr_field, ptr loan_val,
/// i64 id) on llvm.mem.fact. The loan was stored into a heap container whose
/// buffer pointer lives in this frame slot. The id matches !mem.last_use.
/// Generic passes keep it. Promotion of the owner alloca rewrites it to
/// "mem.loan_into.val"(ptr buf_cap, ptr loan_val, i64 id), the buffer
/// capability in SSA at the fact. If that value cannot be recovered the tag
/// becomes "mem.loan_into.promoted" and the late pass counts a skip.
inline constexpr StringRef TagLoanInto = "mem.loan_into";
inline constexpr StringRef TagLoanIntoVal = "mem.loan_into.val";
inline constexpr StringRef TagLoanIntoPromoted = "mem.loan_into.promoted";
/// [LLM-generated] M7.1d B2a: "mem.store_into"(ptr dest, ptr cap) on
/// llvm.mem.fact. rustc named a local destination that received a copy of
/// cap. The late CHERI pass may null dest at the source mem.free if dest
/// still holds cap. Not droppable: losing it loses the clear. Generic
/// passes must preserve dest and cap SSA. No remapping in this slice.
inline constexpr StringRef TagStoreInto = "mem.store_into";
/// [LLM-generated] M7.1d B2c: "mem.store_into_slot"(ptr base, i64 off, ptr cap)
/// on llvm.mem.fact. rustc named an indexed / GEP destination as a ready base
/// plus a byte offset (constant or SSA). The late pass rematerialises
/// GEP(i8, base, off) at the source mem.free if both are ready. The dest GEP
/// is not a fact operand, so mid-end need not keep it alive.
inline constexpr StringRef TagStoreIntoSlot = "mem.store_into_slot";
inline constexpr StringRef TagDropped = "mem.dropped";
inline constexpr StringRef TagCheck = "mem.check";
inline constexpr StringRef GuardMD = "mem.guard";
/// !mem.last_use !{i64 loan, ...} on a carrier, and the "mem.last_use"(i64, ...)
/// bundle on llvm.mem.fact when the program point has no carrier (R15 anchor).
inline constexpr StringRef LastUseMD = "mem.last_use";
/// "mem.last_use.ext"(i64 orig, i64 disambiguator, ...): anchor form of an
/// extended loan copy. Pairs are one loan, not two packed ids (R16).
inline constexpr StringRef LastUseExt = "mem.last_use.ext";
/// [LLM-generated] M5r R5 (D35): rustc slot fact on a store: the stored value
/// is the reference of borrowck loan(s) !{i64 L, ...} (Track B loan-end).
inline constexpr StringRef LoanMD = "mem.loan";
/// R5: the LLVM inliner re-keys a cloned body's loan ids in bits 42..62; the
/// low bits keep the original id (census key). R16: if every non-zero high
/// value is already used for that census key, the copy is an extended operand
/// !{!"mem.loan.ext", i64 orig, i64 disambiguator}. A bare !{i64, i64} stays
/// two packed loans. If no packed key and no disambiguator is free, the
/// inliner stops compilation instead of reusing an id.
inline constexpr uint64_t LoanKeyMask = (uint64_t(1) << 42) - 1;
inline constexpr unsigned LoanHighBits = 21;
/// First operand of an extended loan-copy metadata node.
inline constexpr StringRef LoanExtTag = "mem.loan.ext";

/// One loan copy. Packed ids use \c Packed (high bits non-zero once rekeyed).
/// Extended ids use \c Orig and a non-zero \c Disambig; \c Packed is then 0.
struct LoanRef {
  uint64_t Orig = 0;
  uint64_t Packed = 0;
  uint64_t Disambig = 0;
  bool extended() const { return Disambig != 0; }
  bool sameCopy(const LoanRef &O) const {
    if (extended() || O.extended())
      return extended() && O.extended() && Orig == O.Orig && Disambig == O.Disambig;
    return Packed != 0 && Packed == O.Packed;
  }
};

/// Next copy of a loan. \p Orig is the census key, \p OldHigh the previous
/// copy field (0 for a rustc id). \p HighBits is 1..21 (21 in production).
/// \p PackedTaken / \p DisambigTaken are ids already live in the caller or
/// assigned earlier in this remap. \p DisambigLimit is the largest
/// disambiguator that may be used; 0 means the full 64-bit space. Does not
/// return. Stops compilation if every allowed id is taken.
LLVM_ABI LoanRef allocateLoanCopy(uint64_t Orig, uint64_t OldHigh, uint64_t Salt,
                                  function_ref<bool(uint64_t)> PackedTaken,
                                  function_ref<bool(uint64_t)> DisambigTaken,
                                  unsigned HighBits = LoanHighBits,
                                  uint64_t DisambigLimit = 0);
/// Operands of !mem.loan / !mem.last_use: a packed i64, or
/// !{!"mem.loan.ext", i64 orig, i64 disambiguator}. A !{i64, i64} node is not
/// an operand of this form.
LLVM_ABI void appendLoanRefs(const MDNode *N, SmallVectorImpl<LoanRef> &Out);
/// One operand. False if \p M is not a loan id (the caller keeps it).
LLVM_ABI bool decodeLoanRef(const Metadata *M, LoanRef &R);
/// "mem.last_use" and "mem.last_use.ext" bundles on \p CB.
LLVM_ABI void appendBundleLoanRefs(const CallBase &CB, SmallVectorImpl<LoanRef> &Out);
/// One metadata operand for \p R.
LLVM_ABI Metadata *encodeLoanRef(LLVMContext &Ctx, const LoanRef &R);
/// Insert fact calls before \p InsertBefore for every id in \p LU.
LLVM_ABI void insertLastUseAnchors(Instruction &InsertBefore, const MDNode *LU);
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
/// [LLM-generated] M7.1a: llvm.mem.fact ["mem.move"(ptr slot)].
LLVM_ABI bool isMemMoveFact(const Instruction *I);
/// [LLM-generated] M7.1b: llvm.mem.fact ["mem.loan_into"(ptr slot, ptr val, i64 id)].
LLVM_ABI bool isMemLoanIntoFact(const Instruction *I);
/// [LLM-generated] M7.1b: "mem.loan_into.val"(ptr buf_cap, ptr val, i64 id).
/// The owner slot was promoted; \c buf_cap is the buffer pointer itself.
LLVM_ABI bool isMemLoanIntoValFact(const Instruction *I);
/// [LLM-generated] M7.1d B2a: llvm.mem.fact ["mem.store_into"(ptr dest, ptr cap)].
LLVM_ABI bool isMemStoreIntoFact(const Instruction *I);
/// [LLM-generated] M7.1d B2c: llvm.mem.fact ["mem.store_into_slot"(ptr base, i64 off, ptr cap)].
LLVM_ABI bool isMemStoreIntoSlotFact(const Instruction *I);
/// Frame slot clobbered by a mem.move or mem.loan_into fact, otherwise null.
/// Header copies must not be reordered across that program point.
LLVM_ABI const Value *slotClobber(const Instruction *I);
/// The i64 loan id of a mem.loan_into fact, as a packed LoanRef.
LLVM_ABI void appendLoanIntoRefs(const CallBase &CB, SmallVectorImpl<LoanRef> &Out);
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
/// [LLM-generated] M5r R15: same walk, starting at \p Start (inclusive).
LLVM_ABI void forwardLastUseFrom(Instruction &Start, MDNode *LU);
/// [LLM-generated] M5r R15: \p I is about to move to an earlier program point.
/// Take !mem.last_use off it and forward those ids from the next instruction,
/// so the clear does not pass a slot reload that used to be before I.
/// If no later carrier exists, leave an llvm.mem.fact ["mem.last_use"] anchor
/// at the old point.
LLVM_ABI void detachLastUseBeforeEarlierMove(Instruction &I);
/// [LLM-generated] M5r R15: a widened load/store replaces \p Scalars. Put each
/// lane's last-use on \p Vec only when \p Vec is after that lane. A lane that
/// \p Vec does not follow keeps an anchor at the lane, so the widened op does
/// not clear earlier than that lane.
LLVM_ABI void preserveWidenedLastUse(Instruction &Vec, ArrayRef<Value *> Scalars);
/// [LLM-generated] M6.1 D96. The post-RA spill walk reports bound failures and
/// nulls it actually inserted. llc appends one line to
/// -cheri-invalidate-stats-out from the machine pass.
LLVM_ABI void noteSpillSearchAbort();
LLVM_ABI void noteSpillNull();
LLVM_ABI void noteCapRegSkippedLive();
/// [LLM-generated] M6.1 D99–D102. Scope clears the late pass dropped, by reason.
LLVM_ABI void noteCapRegSkippedNoEscape();
LLVM_ABI void noteCapRegSkippedCSR();
LLVM_ABI void noteCapRegSkippedSoonRedef();
LLVM_ABI void noteCapRegSkippedEdge();
LLVM_ABI void noteCapRegSkippedDup();
LLVM_ABI void flushSpillInvalidateStats();
/// [LLM-generated] M7.1c. Append one line to -cheri-invalidate-stats-out.
LLVM_ABI void appendInvalidateStatsLine(StringRef Line);
/// [LLM-generated] M7.1c. -cheri-free-zero-regs (default on). The inliner, the
/// free-site tail demotion, and the backend marker all read this one switch.
LLVM_ABI bool cheriFreeZeroRegsEnabled();
/// [LLM-generated] M7.1c-2c-narrow. -cheri-invalidate-dead-csr.
/// Off: no C1 clears. MayFree (default): a dead CSR or spill slot is cleared
/// only when it would still hold the capability across a mem.free or a call
/// that takes a moved owner. All: the previous C1 rule, any call or return.
enum class CheriDeadCapMode { Off, MayFree, All };
LLVM_ABI CheriDeadCapMode cheriDeadCapMode();
} // namespace memannot
} // namespace llvm
#endif
