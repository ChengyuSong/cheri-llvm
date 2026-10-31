; [LLM-generated] M5r R4 (D28): an erased !mem.last_use carrier hands its ids
; to the previous carrier on its path; SimplifyCFG sinking merges them onto
; the sunk copy.
; RUN: opt -S -passes=early-cse < %s | FileCheck %s --check-prefix=CSE
; RUN: opt -S -passes=dse < %s | FileCheck %s --check-prefix=DSE
; RUN: opt -S -passes='simplifycfg<sink-common-insts>' < %s | FileCheck %s --check-prefix=SINK
; RUN: opt -S -passes=early-cse -mem-last-use-transfer=false < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(i32) memory(none)

; The second load is CSE'd into the first; loan 7 now ends after @use (the
; previous carrier), not on the deleted load.
define i32 @cse(ptr addrspace(200) %p) {
  %a = load i32, ptr addrspace(200) %p, align 4
  call void @use(i32 %a)
  %b = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !0
  ret i32 %b
}
; CSE-LABEL: define i32 @cse(
; CSE:         call addrspace(200) void @use(i32 %a){{.*}}, !mem.last_use [[L7:![0-9]+]]
; CSE-NEXT:    ret i32 %a
; OFF-LABEL: define i32 @cse(
; OFF-NOT:     !mem.last_use
; OFF:         ret i32 %a

; A store overwritten before any read is dead; loan 8 moves to the load before it.
define void @dse(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %v = load i32, ptr addrspace(200) %q, align 4
  store i32 1, ptr addrspace(200) %p, align 4, !mem.last_use !1
  store i32 %v, ptr addrspace(200) %p, align 4
  ret void
}
; DSE-LABEL: define void @dse(
; DSE:         load i32, ptr addrspace(200) %q, align 4, !mem.last_use [[L8:![0-9]+]]
; DSE-NEXT:    store i32 %v

; Two identical stores sunk into the join: the sunk store ends both loans.
define void @sink(i1 %c, ptr addrspace(200) %p, i32 %x, i32 %y) {
entry:
  br i1 %c, label %t, label %f
t:
  call void @use(i32 %x)
  store i32 %x, ptr addrspace(200) %p, align 4, !mem.last_use !2
  br label %j
f:
  call void @use(i32 %y)
  store i32 %y, ptr addrspace(200) %p, align 4, !mem.last_use !3
  br label %j
j:
  ret void
}
; SINK-LABEL: define void @sink(
; SINK-NOT:     !mem.last_use !
; SINK:         store i32 {{.*}}, !mem.last_use [[L910:![0-9]+]]

; CSE: [[L7]] = !{i64 7}
; DSE: [[L8]] = !{i64 8}
; SINK: [[L910]] = !{i64 {{9|10}}, i64 {{9|10}}}

!0 = !{i64 7}
!1 = !{i64 8}
!2 = !{i64 9}
!3 = !{i64 10}
