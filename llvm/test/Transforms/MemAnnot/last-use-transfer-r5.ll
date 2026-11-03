; [LLM-generated] M5r R5 (D39): straight-line !mem.last_use transfers. An
; erased carrier's ids never move into a predecessor that branches elsewhere
; (the loan may be live on the other successor); all predecessors of a join
; take them when each branches only to the join and ends in a carrier;
; otherwise they move forward to the next carrier on the unique path.
; RUN: opt -S -passes=early-cse < %s | FileCheck %s
; RUN: opt -S -passes=gvn < %s | FileCheck %s --check-prefix=JOIN
; RUN: opt -S -passes=early-cse -mem-last-use-transfer-strict=false < %s | FileCheck %s --check-prefix=R4
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(i32) memory(none)

; %b (loan 7) is CSE'd into %a. R4 moved loan 7 onto @use in entry, which also
; runs on the path to %f, where the loan may still be live.
define void @branchy(i1 %c, ptr addrspace(200) %p, ptr addrspace(200) %q) {
entry:
  %a = load i32, ptr addrspace(200) %p, align 4
  call void @use(i32 %a)
  br i1 %c, label %t, label %f
t:
  %b = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !0
  store i32 %b, ptr addrspace(200) %q, align 4
  ret void
f:
  ret void
}
; CHECK-LABEL: define void @branchy(
; CHECK:       call addrspace(200) void @use(i32 %a){{$}}
; CHECK:       t:
; CHECK-NEXT:  store i32 %a, ptr addrspace(200) %q, align 4, !mem.last_use [[L7:![0-9]+]]
; R4-LABEL: define void @branchy(
; R4:          call addrspace(200) void @use(i32 %a), !mem.last_use

; A join (GVN): both predecessors end in a carrier and branch only to %j.
define void @join(i1 %c, ptr addrspace(200) %p, i32 %x) {
entry:
  %a = load i32, ptr addrspace(200) %p, align 4
  br i1 %c, label %t, label %f
t:
  call void @use(i32 %x)
  br label %j
f:
  call void @use(i32 %a)
  br label %j
j:
  %b = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !1
  call void @use(i32 %b)
  ret void
}
; JOIN-LABEL: define void @join(
; JOIN:        t:
; JOIN-NEXT:   call addrspace(200) void @use(i32 %x), !mem.last_use [[L8:![0-9]+]]
; JOIN:        f:
; JOIN-NEXT:   call addrspace(200) void @use(i32 %a), !mem.last_use [[L8]]
; JOIN:        j:
; JOIN-NEXT:   call addrspace(200) void @use(i32 %a){{$}}

; CHECK: [[L7]] = !{i64 7}
; JOIN: [[L8]] = !{i64 8}

!0 = !{i64 7}
!1 = !{i64 8}
