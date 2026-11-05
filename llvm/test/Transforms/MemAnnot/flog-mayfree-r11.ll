; [LLM-generated] M5r R11 (D77): with the free log, a call to a module function
; that cannot reach a free gets no log check; a call to an unknown declaration does.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free+flog < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare void @consume(ptr addrspace(200))
define void @pure(ptr addrspace(200) %p) {
  ret void
}
define i64 @caller(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @pure(ptr addrspace(200) %p)
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @consume(ptr addrspace(200) %p)
  %r = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  %x = load i64, ptr addrspace(200) %r
  ret i64 %x
}
; CHECK-LABEL: define i64 @caller(
; CHECK: void @pure(
; CHECK-NEXT: %q = load volatile
; CHECK: load volatile i64, ptr addrspace(200) @__cheri_free_log4
; CHECK-NEXT: call addrspace(200) void @consume(
; CHECK-NEXT: load volatile i64, ptr addrspace(200) @__cheri_free_log4
