; [LLM-generated] M7.2o: the module that defines the runtime's
; cheri_note_escape_slot gets no notes, even with -cheri-invalidate-noreuse
; and -cheri-invalidate-noreuse-slots: its escape facts are dropped and its
; store facts get no call.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots < %s | FileCheck %s

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()

define void @cheri_note_escape_slot(ptr addrspace(200) %p, ptr addrspace(200) %s) {
  ret void
}

; CHECK-LABEL: define void @epoch(
; CHECK-NOT: call {{.*}}@cheri_note_escape
; CHECK-NOT: mem.escape_unknown
; CHECK: ret void
define void @epoch(ptr addrspace(200) %arena, ptr addrspace(200) %heap) {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %arena, ptr addrspace(200) %heap) ]
  store ptr addrspace(200) %arena, ptr addrspace(200) %heap, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %heap, ptr addrspace(200) %arena) ]
  ret void
}
