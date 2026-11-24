; [LLM-generated] M7.3: a slot rustc marks !mem.owning (its type holds only owning
; heap pointers, pointers to statics or fn pointers) gets no scope-end range check
; against a dying frame object. Its own null and the checks of unmarked slots stay.
; A marked slot that the IR stores a frame address into keeps its check.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-owning-slots=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate-stats-out=%t.stats < %s
; RUN: FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare ptr addrspace(200) @get()

; %own holds a heap pointer from a call (unknown origin). %a escapes, so without the
; fact %own is range-checked at %a's end.
define void @owning(ptr addrspace(200) %v) {
  %own = alloca ptr addrspace(200), align 16, addrspace(200), !mem.owning !0
  %a = alloca [32 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %own)
  %h = call ptr addrspace(200) @get()
  store ptr addrspace(200) %h, ptr addrspace(200) %own, align 16
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  call void @use(ptr addrspace(200) %a)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  %r = load ptr addrspace(200), ptr addrspace(200) %own, align 16
  call void @use(ptr addrspace(200) %r)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %own)
  ret void
}
; CHECK-LABEL: define void @owning(
; CHECK-NOT: cheri.inv.cap
; CHECK: call addrspace(200) void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %own
; CHECK-NOT: !mem.owning
; OFF-LABEL: define void @owning(
; OFF: %cheri.inv.cap = load ptr addrspace(200), ptr addrspace(200) %own
; OFF: call addrspace(200) void @llvm.lifetime.end.p200(ptr addrspace(200) %a)

; The same shape without the fact keeps the check.
define void @plain(ptr addrspace(200) %v) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  %a = alloca [32 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  %h = call ptr addrspace(200) @get()
  store ptr addrspace(200) %h, ptr addrspace(200) %s, align 16
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  call void @use(ptr addrspace(200) %a)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  %r = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %r)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; CHECK-LABEL: define void @plain(
; CHECK: %cheri.inv.cap = load ptr addrspace(200), ptr addrspace(200) %s
; CHECK: call addrspace(200) void @llvm.lifetime.end.p200(ptr addrspace(200) %a)

; A marked slot with a visible store of a frame address: the fact is ignored.
define void @contradicted(ptr addrspace(200) %v, i1 %c) {
  %own = alloca ptr addrspace(200), align 16, addrspace(200), !mem.owning !0
  %a = alloca [32 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %own)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  %h = call ptr addrspace(200) @get()
  %p = select i1 %c, ptr addrspace(200) %h, ptr addrspace(200) %a
  store ptr addrspace(200) %p, ptr addrspace(200) %own, align 16
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  %r = load ptr addrspace(200), ptr addrspace(200) %own, align 16
  call void @use(ptr addrspace(200) %r)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %own)
  ret void
}
; CHECK-LABEL: define void @contradicted(
; CHECK: %cheri.inv.cap = load ptr addrspace(200), ptr addrspace(200) %own
; CHECK: call addrspace(200) void @llvm.lifetime.end.p200(ptr addrspace(200) %a)

; STATS: owning_skipped=1 owning_ignored=1

!0 = !{}
