; [LLM-generated] M7.1b: SROA splits a Vec header and promotes the buffer-pointer
; field. The loan_into on the header becomes mem.loan_into.val of that field's
; SSA value, which is the pointer stored before the fact. The len and cap
; fields are not the scan base.
;
; RUN: opt -S -passes=sroa < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()

define void @header(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %dst = alloca [48 x i8], align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dst, align 16
  %len = getelementptr inbounds i8, ptr addrspace(200) %dst, i64 16
  store i64 1, ptr addrspace(200) %len, align 8
  %cap = getelementptr inbounds i8, ptr addrspace(200) %dst, i64 32
  store i64 4, ptr addrspace(200) %cap, align 8
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %dst, ptr addrspace(200) %loan, i64 9) ]
  ret void
}
; CHECK-LABEL: define void @header(
; CHECK-NOT: alloca
; CHECK: call {{.*}}@llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i64 9) ]
; CHECK-NOT: "mem.loan_into"(
; CHECK-NOT: mem.dropped
; CHECK-NOT: mem.loan_into.promoted

; A later store of a different buffer is the value at the fact only if it
; dominates the fact. The fact sees %new, not the earlier %old.
define void @latest(ptr addrspace(200) %old, ptr addrspace(200) %new, ptr addrspace(200) %loan) {
  %dst = alloca [48 x i8], align 16, addrspace(200)
  store ptr addrspace(200) %old, ptr addrspace(200) %dst, align 16
  %len = getelementptr inbounds i8, ptr addrspace(200) %dst, i64 16
  store i64 1, ptr addrspace(200) %len, align 8
  store ptr addrspace(200) %new, ptr addrspace(200) %dst, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %dst, ptr addrspace(200) %loan, i64 3) ]
  ret void
}
; CHECK-LABEL: define void @latest(
; CHECK: call {{.*}}@llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %new, ptr addrspace(200) %loan, i64 3) ]
; CHECK-NOT: mem.dropped
