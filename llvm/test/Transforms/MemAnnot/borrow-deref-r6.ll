; [LLM-generated] M5r R6 (D49, fixes D32): after inlining an index operator
; (SmallVec Index::index), the borrow guard also feeds a mem.alloc_inbounds
; fact. The fact is an annotation (stripped by the late pass), so the borrow is
; still only dereferenced: lowered like an access check under ub.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-borrow-fact-users=false < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()
declare void @llvm.trap()

; CHECK-LABEL: @deref_fact(
; CHECK: llvm.cheri.cap.bounds.set.exact
; CHECK-NOT: llvm.trap
; CHECK: ret i64
; OFF-LABEL: @deref_fact(
; OFF: br i1 %c, label %ok, label %panic
; OFF: llvm.trap
define i64 @deref_fact(ptr addrspace(200) %v, i64 %i) addrspace(200) {
start:
  %p = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %lp = getelementptr inbounds nuw i8, ptr addrspace(200) %v, i64 32
  %len = load i64, ptr addrspace(200) %lp, align 16
  %c = icmp ult i64 %i, %len
  br i1 %c, label %ok, label %panic
ok:
  %g = getelementptr inbounds nuw [8 x i8], ptr addrspace(200) %p, i64 %i, !mem.guard !0
  call addrspace(200) void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr addrspace(200) %g) ]
  %x = load i64, ptr addrspace(200) %g, align 8
  ret i64 %x
panic:
  call addrspace(200) void @llvm.trap() [ "mem.check"(ptr addrspace(200) %p, i64 %len, i64 8, i64 7, i64 256) ]
  unreachable
}

!0 = !{i64 7}
