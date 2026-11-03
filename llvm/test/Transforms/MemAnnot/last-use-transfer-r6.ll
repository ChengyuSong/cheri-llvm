; [LLM-generated] M5r R6 (D44): CSE keeps the surviving carrier's own loan ends
; (R5 dropped them unless both copies carried the identical node); the erased
; copy's ids move as in D39. SimplifyCFG hoisting moves a copy into the
; branching block: ids not common to all copies go to the next carrier of
; their own successor (a later end on the same path), never into the branch.
; RUN: opt -S -passes=early-cse < %s | FileCheck %s --check-prefix=CSE
; RUN: opt -S -passes=early-cse -mem-last-use-keep-k=false < %s | FileCheck %s --check-prefix=R5
; RUN: opt -S -passes='simplifycfg<hoist-common-insts>' < %s | FileCheck %s --check-prefix=HOIST
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(i32) memory(none)

define i32 @keep(ptr addrspace(200) %p) {
  %a = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !0
  %b = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !1
  %s = add i32 %a, %b
  ret i32 %s
}
; CSE-LABEL: define i32 @keep(
; CSE: %a = load i32, ptr addrspace(200) %p, align 4, !mem.last_use [[L57:![0-9]+]]
; CSE-NEXT: %s = add i32 %a, %a
; R5-LABEL: define i32 @keep(
; R5: %a = load i32, ptr addrspace(200) %p, align 4, !mem.last_use [[R7:![0-9]+]]
; CSE: [[L57]] = !{i64 5, i64 7}
; R5: [[R7]] = !{i64 7}

define void @hoist(i1 %c, ptr addrspace(200) %p, ptr addrspace(200) %q) {
entry:
  br i1 %c, label %t, label %f
t:
  %a = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !0
  store i32 %a, ptr addrspace(200) %q, align 4
  ret void
f:
  %b = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !1
  store i32 0, ptr addrspace(200) %q, align 4
  call void @use(i32 %b)
  ret void
}
; HOIST-LABEL: define void @hoist(
; HOIST: entry:
; HOIST-NEXT: %a = load i32, ptr addrspace(200) %p, align 4{{$}}
; HOIST: {{^}}t:
; HOIST-NEXT: store i32 %a, ptr addrspace(200) %q, align 4, !mem.last_use [[H5:![0-9]+]]
; HOIST: {{^}}f:
; HOIST-NEXT: store i32 0, ptr addrspace(200) %q, align 4, !mem.last_use [[H7:![0-9]+]]
; HOIST: [[H5]] = !{i64 5}
; HOIST: [[H7]] = !{i64 7}

!0 = !{i64 5}
!1 = !{i64 7}
