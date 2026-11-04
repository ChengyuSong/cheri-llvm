; [LLM-generated] M5r R9 (D67): an inlined deallocator with no call left in its
; body (a free-list GlobalAlloc) keeps the free as llvm.mem.fact ["mem.free"]
; at each return of the inlined body (prefix OFF = R8, the fact is dropped). R9 (D67 gating): only when -cheri-invalidate includes free (the D69 default loan+free does).
; RUN: opt -S -passes=inline < %s | FileCheck %s
; RUN: opt -S -passes=inline -mem-inline-free-fact=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=inline -cheri-invalidate=loan < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@FREE = global i64 0

define void @__rust_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) alwaysinline {
  %c = icmp ugt i64 %n, 2048
  br i1 %c, label %big, label %small
big:
  ret void
small:
  store i64 %n, ptr addrspace(200) %p
  store i64 %a, ptr @FREE
  ret void
}

define void @caller(ptr addrspace(200) %p) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 32, i64 8) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @caller(
; CHECK:       store i64 8, ptr @FREE
; CHECK-NEXT:  call {{.*}}void @llvm.mem.fact() [ "mem.free"(ptr addrspace(200) %p) ]
; OFF-LABEL: define void @caller(
; OFF-NOT: llvm.mem.fact
; OFF: ret void
