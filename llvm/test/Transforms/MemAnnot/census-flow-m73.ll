; [LLM-generated] M7.3: the census counts an inlined free (the standalone
; llvm.mem.fact ["mem.free"] the inliner leaves, with the call's census id)
; as the same free, not a loss, and tracks the flow kinds (move, store_into,
; loan_into, wipe, escape, lifetime_end) with the reason and the erasing pass.
; RUN: opt -mem-annot-census -mem-annot-census-strict -disable-output \
; RUN:   -passes='mem-annot-census-start,inline,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=INL
; RUN: opt -mem-annot-census -mem-annot-census-per-pass -disable-output \
; RUN:   -passes='mem-annot-census-start,sroa,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=SROA
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@FREE = global i64 0
declare void @llvm.mem.fact()
declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @use(ptr addrspace(200))

define void @__rust_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) alwaysinline {
  store i64 %n, ptr addrspace(200) %p
  store i64 %a, ptr @FREE
  ret void
}

define void @caller(ptr addrspace(200) %p) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 32, i64 8) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}

; A moved-from slot and a store_into fact on a slot SROA promotes.
define void @slots(ptr addrspace(200) %v) {
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %b)
  store ptr addrspace(200) %v, ptr addrspace(200) %a, align 16
  %x = load ptr addrspace(200), ptr addrspace(200) %a, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %a) ]
  store ptr addrspace(200) %v, ptr addrspace(200) %b, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %b, ptr addrspace(200) %v) ]
  %y = load ptr addrspace(200), ptr addrspace(200) %b, align 16
  call void @use(ptr addrspace(200) %x)
  call void @use(ptr addrspace(200) %y)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %b)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  ret void
}

; INL: start: {{.*}} free=1 {{.*}} move=1 store_into=1 loan_into=0 wipe=0 escape=0 lifetime_end=2
; INL: late: {{.*}} free=1 {{.*}} move=1 store_into=1
; INL: lost: none
; INL: flow: move=1->1 store_into=1->1 loan_into=0->0 wipe=0->0 escape=0->0 lifetime_end=2->2

; SROA keeps %a in memory (mem.move pins it) and promotes %b: its store_into
; becomes a mem.dropped placeholder, its lifetime.end goes away.
; SROA: mem-annot-census-pass: {{.*}} SROAPass: dropped=-0/+1 store_into=-1/+0 lifetime_end=-1/+0
; SROA: lost: none
; SROA: flow: move=1->1 store_into=1->0(promoted=1) loan_into=0->0 wipe=0->0 escape=0->0 lifetime_end=2->1
