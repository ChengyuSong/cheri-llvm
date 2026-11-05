; [LLM-generated] M5r R11 (D76): a narrowing used only through an llvm.mem.claim
; fact (which returns its pointer) and accesses gets no explicit tag test (D70).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64)
define i64 @k(ptr addrspace(200) %p, i64 %n) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %q, i64 %n, i64 256)
  %v = load i64, ptr addrspace(200) %c
  ret i64 %v
}
; CHECK-LABEL: define i64 @k(
; CHECK-NOT: cap.tag.get
; CHECK: ret i64
