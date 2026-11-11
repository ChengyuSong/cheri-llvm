; [LLM-generated] M7.1c: the default -cheri-invalidate mode is
; loan+free+scope+aflog, so a dying alloca's own capability slot is nulled.
; slite is still selectable and keeps the range check without that null.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=DEF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free+slite+aflog < %s | FileCheck %s --check-prefix=SLITE
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @use(ptr addrspace(200))

define void @own(ptr addrspace(200) %v) {
  %x = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %x)
  store ptr addrspace(200) %v, ptr addrspace(200) %x, align 16
  call void @use(ptr addrspace(200) %x)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %x)
  ret void
}
; DEF-LABEL: define void @own(
; DEF: store volatile ptr addrspace(200) null, ptr addrspace(200) %x, align 16
; DEF: call addrspace(200) void @llvm.lifetime.end.p200
; SLITE-LABEL: define void @own(
; SLITE-NOT: store volatile ptr addrspace(200) null
; SLITE: call addrspace(200) void @llvm.lifetime.end.p200
