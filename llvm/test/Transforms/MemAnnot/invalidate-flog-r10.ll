; [LLM-generated] M5r R10 (D72): with "flog" in -cheri-invalidate a free event appends
; [base, len) to @__cheri_free_log, and a caller whose non-escaping heap-capable
; slot is read after a call checks it against the entries that call appended.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free+flog < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare void @llvm.mem.fact()
declare void @consume(ptr addrspace(200))

define void @callee(ptr addrspace(200) %b) {
  call void @llvm.mem.fact() [ "mem.free"(ptr addrspace(200) %b) ]
  ret void
}
; CHECK-LABEL: define void @callee(
; CHECK: store volatile i64 {{.*}}@__cheri_free_log

define i64 @caller(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @consume(ptr addrspace(200) %p)
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  %x = load i64, ptr addrspace(200) %q
  ret i64 %x
}
; CHECK-LABEL: define i64 @caller(
; CHECK: load volatile i64, ptr addrspace(200) @__cheri_free_log
; CHECK: void @consume(
; CHECK: load volatile i64, ptr addrspace(200) @__cheri_free_log
; CHECK: @llvm.cheri.cap.tag.clear
; OFF-NOT: __cheri_free_log
