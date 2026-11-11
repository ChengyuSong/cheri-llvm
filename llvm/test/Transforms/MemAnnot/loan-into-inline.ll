; [LLM-generated] M7.1b: inlining rekeys the loan_into id with the same map as
; the callee's !mem.last_use, so the late scan still sees one loan.
;
; RUN: opt -S -passes=always-inline < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @g()
declare void @llvm.mem.fact()

define internal void @callee(ptr addrspace(200) %s, ptr addrspace(200) %loan) alwaysinline {
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 3) ]
  call void @g(), !mem.last_use !0
  ret void
}

define void @caller(ptr addrspace(200) %s, ptr addrspace(200) %loan) {
  call void @callee(ptr addrspace(200) %s, ptr addrspace(200) %loan)
  ret void
}
; CHECK-LABEL: define void @caller(
; CHECK: call {{.*}}@llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 [[ID:[0-9]+]]) ]
; CHECK: call {{.*}}@g(), !mem.last_use ![[M:[0-9]+]]
; CHECK: ![[M]] = !{i64 [[ID]]}
; CHECK-NOT: i64 3

!0 = !{i64 3}
