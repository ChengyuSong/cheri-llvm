; [LLM-generated] M5r R14 (D83): aflog is in the default -cheri-invalidate mode; same checks as aflog-r12.ll without the flag.
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare void @dealloc(ptr addrspace(200))
declare ptr addrspace(200) @mk()
declare void @consume(ptr addrspace(200))
define void @freer(ptr addrspace(200) %o) {
  %b = load ptr addrspace(200), ptr addrspace(200) %o, align 16
  call void @dealloc(ptr addrspace(200) %b) [ "mem.free"(ptr addrspace(200) %b) ]
  ret void
}
define void @own() {
  %b = call ptr addrspace(200) @mk()
  call void @dealloc(ptr addrspace(200) %b) [ "mem.free"(ptr addrspace(200) %b) ]
  ret void
}
define i64 @caller(ptr addrspace(200) %p, ptr addrspace(200) %o) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @consume(ptr addrspace(200) %p)
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @freer(ptr addrspace(200) %o)
  %r = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  %x = load i64, ptr addrspace(200) %r
  ret i64 %x
}
; CHECK-LABEL: define void @freer(
; CHECK: store volatile i64 {{.*}}@__cheri_free_log4
; CHECK-LABEL: define void @own(
; CHECK-NOT: __cheri_free_log4
; CHECK: ret void
; CHECK-LABEL: define i64 @caller(
; CHECK: call addrspace(200) void @consume(
; CHECK-NEXT: %q = load volatile
; CHECK: load volatile i64, ptr addrspace(200) @__cheri_free_log4
; CHECK-NEXT: call addrspace(200) void @freer(
; CHECK-NEXT: load volatile i64, ptr addrspace(200) @__cheri_free_log4
