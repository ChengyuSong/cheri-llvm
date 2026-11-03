; [LLM-generated] M5r R5 (D35): SROA keeps the !mem.loan slot fact on the
; rewritten store of a reference into the new slot (here the slot survives
; because a volatile load reads it).
; RUN: opt -S -passes=sroa < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

define i64 @slot(ptr addrspace(200) %b) {
  %r = alloca [32 x i8], align 16, addrspace(200)
  %p = getelementptr inbounds nuw i8, ptr addrspace(200) %b, i64 8
  store ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  %t = getelementptr inbounds nuw i8, ptr addrspace(200) %r, i64 16
  store i64 0, ptr addrspace(200) %t, align 8
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16
  %v = load i64, ptr addrspace(200) %q, align 8
  ret i64 %v
}
; CHECK-LABEL: define i64 @slot(
; CHECK:       %r.sroa.0 = alloca ptr addrspace(200)
; CHECK:       store ptr addrspace(200) %p, ptr addrspace(200) %r.sroa.0, align 16, !mem.loan [[L:![0-9]+]]
; CHECK: [[L]] = !{i64 5}

!0 = !{i64 5}
