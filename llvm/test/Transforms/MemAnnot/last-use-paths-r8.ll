; [LLM-generated] M5r R8 (D59, D60): loan ends across branches.
; D59: the erased last use of a promoted slot sits at the top of a block that
; branches; each successor with no other predecessor takes the ids on the first
; carrier of its path (%l). A join successor (%j, also entered from %y) gets
; nothing. OLD (-mem-last-use-fanout=false) loses the end.
; RUN: opt -S -passes='function(sroa),cheri-bounds-lowering' < %s | FileCheck %s
; RUN: opt -S -passes='function(sroa),cheri-bounds-lowering' -mem-last-use-fanout=false < %s | FileCheck %s --check-prefix=OLD
; D60: an inlined callee whose return is reached through a join, one arm
; without any memory access: the ids go on the last carrier of the other arm
; and on the first carrier after the call.
; RUN: opt -S -passes='cgscc(inline),cheri-bounds-lowering' < %s | FileCheck %s --check-prefix=INL
; RUN: opt -S -passes='cgscc(inline),cheri-bounds-lowering' -mem-inline-last-use-paths=false < %s | FileCheck %s --check-prefix=INL-OLD
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@g = addrspace(200) global i8 0
declare void @esc(ptr addrspace(200))
declare void @f()

define void @fan(ptr addrspace(200) %p, i1 %c, i1 %d) {
entry:
  %t = alloca i8, align 1, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %b, align 16, !mem.loan !0
  call void @esc(ptr addrspace(200) %b)
  store i8 0, ptr addrspace(200) %t, align 1
  br i1 %c, label %x, label %y
x:
  %v = load i8, ptr addrspace(200) %t, align 1, !mem.last_use !1
  br i1 %d, label %l, label %j
l:
  %w = load i8, ptr addrspace(200) @g, align 1
  ret void
y:
  br label %j
j:
  call void @f()
  ret void
}
; CHECK-LABEL: define void @fan(
; CHECK: l:
; CHECK-NEXT: load i8, ptr addrspace(200) @g
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %b
; CHECK: j:
; CHECK-NEXT: call addrspace(200) void @f()
; CHECK-NEXT: ret void
; OLD-LABEL: define void @fan(
; OLD-NOT: store volatile ptr addrspace(200) null
; OLD: ret void

define internal void @callee(i1 %c) {
entry:
  br i1 %c, label %a, label %e
a:
  store i8 1, ptr addrspace(200) @g, align 1
  br label %m
e:
  br label %m
m:
  ret void
}

define void @caller(ptr addrspace(200) %p, i1 %c) {
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %b, align 16, !mem.loan !2
  call void @esc(ptr addrspace(200) %b)
  call void @callee(i1 %c), !mem.last_use !3
  %w = load i8, ptr addrspace(200) @g, align 1
  ret void
}
; INL-LABEL: define void @caller(
; INL: store i8 1, ptr addrspace(200) @g
; INL-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %b
; INL: load i8, ptr addrspace(200) @g
; INL-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %b
; INL-OLD-LABEL: define void @caller(
; INL-OLD: store i8 1, ptr addrspace(200) @g
; INL-OLD-NOT: store volatile ptr addrspace(200) null
; INL-OLD: load i8, ptr addrspace(200) @g
; INL-OLD-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %b

!0 = !{i64 5}
!1 = !{i64 5}
!2 = !{i64 7}
!3 = !{i64 7}
