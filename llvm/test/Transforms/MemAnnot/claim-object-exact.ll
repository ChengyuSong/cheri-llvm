; [LLM-generated] M5r R1: InstCombine folds a claim of exactly a whole stack or
; global object (it says nothing beyond the allocation), so it cannot block
; SROA / memcpy-from-constant folding; the census classifies it as
; object-exact (explained, not fatal in strict mode). Partial or offset claims
; stay.
; RUN: opt -S -passes=instcombine < %s | FileCheck %s
; RUN: opt -mem-annot-census -mem-annot-census-strict -mem-annot-census-per-pass -disable-output \
; RUN:   -passes='mem-annot-census-start,instcombine,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=CENSUS
; RUN: opt -S -passes='instcombine,sroa' < %s | FileCheck %s --check-prefix=SROA

@g = private unnamed_addr constant [40 x i8] zeroinitializer, align 8
@ext = external global [40 x i8]

declare ptr @llvm.mem.claim.p0(ptr, i64, i64 immarg)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @use(ptr)

; CHECK-LABEL: @exact_alloca(
; CHECK-NOT: llvm.mem.claim
; CHECK: ret
; SROA-LABEL: @exact_alloca(
; SROA-NOT: alloca
; SROA: ret i64 0
define i64 @exact_alloca() {
  %a = alloca [40 x i8], align 8
  %d = call ptr @llvm.mem.claim.p0(ptr %a, i64 40, i64 263)
  %s = call ptr @llvm.mem.claim.p0(ptr @g, i64 40, i64 263)
  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 40, i1 false)
  %v = load i64, ptr %a
  ret i64 %v
}

; CHECK-LABEL: @partial(
; CHECK: call ptr @llvm.mem.claim.p0(ptr nonnull %a, i64 20, i64 261)
; CHECK: call ptr @llvm.mem.claim.p0(ptr nonnull %o, i64 32, i64 261)
; CHECK: call ptr @llvm.mem.claim.p0(ptr nonnull @ext, i64 40, i64 261)
define void @partial() {
  %a = alloca [40 x i8], align 8
  %p = call ptr @llvm.mem.claim.p0(ptr %a, i64 20, i64 261)
  call void @use(ptr %p)
  %o = getelementptr inbounds i8, ptr %a, i64 8
  %q = call ptr @llvm.mem.claim.p0(ptr %o, i64 32, i64 261)
  call void @use(ptr %q)
  %e = call ptr @llvm.mem.claim.p0(ptr @ext, i64 40, i64 261)
  call void @use(ptr %e)
  ret void
}

; CENSUS: start: check=0 guard=0 claim=5
; CENSUS: late: check=0 guard=0 claim=3
; CENSUS: mem-annot-census-pass: {{.*}} InstCombinePass: claim=-2/+0
; CENSUS: lost: claim=2(object-exact=2)
