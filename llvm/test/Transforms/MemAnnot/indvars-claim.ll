; [LLM-generated] M5r R1: IndVarSimplify must not replace a claim of the IV
; pointer by the IV (it has the same SCEV); the loop is otherwise simplified.
; RUN: opt -passes=indvars -S %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64 immarg)

; CHECK-LABEL: @f(
; CHECK: %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %p, i64 4, i64 256)
; CHECK: store i32 0, ptr addrspace(200) %c
define void @f(ptr addrspace(200) %a, i64 %n) addrspace(200) {
entry:
  br label %loop
loop:
  %p = phi ptr addrspace(200) [ %a, %entry ], [ %p.next, %loop ]
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %p, i64 4, i64 256)
  store i32 0, ptr addrspace(200) %c
  %p.next = getelementptr inbounds i8, ptr addrspace(200) %p, i64 4
  %i.next = add nuw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
