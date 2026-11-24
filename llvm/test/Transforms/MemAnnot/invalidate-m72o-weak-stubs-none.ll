; [LLM-generated] M7.2o: no weak stub when the pass lowered no note, even with
; every switch on. Here the only store fact is in this function's own frame
; (no call), and the module calls cheri_note_escape itself: that declaration
; stays a declaration (the pass did not lower it), and no other hook appears.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots -cheri-invalidate-store-into-int=false < %s | FileCheck %s

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()
declare void @cheri_note_escape(ptr addrspace(200))
declare void @use(ptr addrspace(200))

; CHECK: declare void @cheri_note_escape(ptr addrspace(200))
; CHECK-NOT: weak
; CHECK-LABEL: define void @frame(
; CHECK-NOT: cheri_note_escape_slot
; CHECK: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %buf)
; CHECK: ret void
define void @frame(ptr addrspace(200) %buf) {
  %a = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %a, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %a, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %a)
  call void @cheri_note_escape(ptr addrspace(200) %buf)
  ret void
}

; CHECK-NOT: weak
; CHECK-NOT: cheri_note_escape_slot
