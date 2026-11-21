; [LLM-generated] M7.2f: a call to a function marked "mem.spec_frees" (rustc:
; its library spec frees or relocates a heap block) is may-free, so the late
; machine pass can untag or null address-only register copies before it.
; An unmarked call stays as it was. Off switch and -cheri-invalidate=none
; leave every call unmarked.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-spec-frees-mayfree=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=OFF

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @grow_one(ptr addrspace(200)) "mem.spec_frees"="frees"
declare void @plain(ptr addrspace(200))

define void @grow(ptr addrspace(200) %v) {
  call void @grow_one(ptr addrspace(200) %v)
  call void @plain(ptr addrspace(200) %v)
  ret void
}

; CHECK-LABEL: define void @grow(
; CHECK: call {{.*}}@grow_one(ptr addrspace(200) %v) #[[MF:[0-9]+]]
; CHECK: call {{.*}}@plain(ptr addrspace(200) %v){{$}}
; CHECK: attributes #[[MF]] = { "cheri-may-free" }
; OFF-LABEL: define void @grow(
; OFF: call {{.*}}@grow_one(ptr addrspace(200) %v){{$}}
; OFF-NOT: "cheri-may-free"
