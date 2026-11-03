; [LLM-generated] M5r R4: an inlined allocator shim whose body calls a user
; GlobalAlloc::dealloc (not a known deallocation function) moves "mem.free"
; onto the inlined call that takes the freed pointer.
; RUN: opt -S -passes=inline < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @user_dealloc(ptr addrspace(200), i64)
declare void @other(i64)

define void @__rust_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) alwaysinline {
  call void @other(i64 %a)
  call void @user_dealloc(ptr addrspace(200) %p, i64 %n)
  ret void
}

define void @caller(ptr addrspace(200) %p) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 32, i64 8) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @caller(
; CHECK:         call addrspace(200) void @other(i64 8){{$}}
; CHECK-NEXT:    call addrspace(200) void @user_dealloc(ptr addrspace(200) %p, i64 32) [ "mem.free"(ptr addrspace(200) %p) ]
