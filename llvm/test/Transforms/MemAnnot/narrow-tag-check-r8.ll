; [LLM-generated] M5r R8 (D61): the D46 tag check is skipped for a narrowing
; with a constant length (CONST keeps it with -cheri-narrow-tag-check-const),
; and a loop-invariant narrowing that runs on every iteration is checked once
; in the preheader (NOHOIST keeps it in the loop).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check -cheri-narrow-tag-check-const < %s | FileCheck %s --check-prefix=CONST
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check -cheri-narrow-tag-check-hoist=false < %s | FileCheck %s --check-prefix=NOHOIST
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare void @use(ptr addrspace(200))

define ptr addrspace(200) @fixed(ptr addrspace(200) %p) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 16)
  ret ptr addrspace(200) %q
}
; CHECK-LABEL: define ptr addrspace(200) @fixed(
; CHECK-NOT: llvm.cheri.cap.tag.get
; CHECK: ret
; CONST-LABEL: define ptr addrspace(200) @fixed(
; CONST: llvm.cheri.cap.tag.get

define void @loop(ptr addrspace(200) %p, i64 %n, i64 %k) {
entry:
  br label %h
h:
  %i = phi i64 [ 0, %entry ], [ %i1, %h ]
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  call void @use(ptr addrspace(200) %q)
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %k
  br i1 %c, label %h, label %x
x:
  ret void
}
; CHECK-LABEL: define void @loop(
; CHECK: entry:
; CHECK: @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
; CHECK: llvm.cheri.cap.tag.get
; CHECK: h:
; CHECK-NOT: llvm.cheri.cap.tag.get
; CHECK: ret void
; NOHOIST-LABEL: define void @loop(
; NOHOIST: h:
; NOHOIST: @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
; NOHOIST: llvm.cheri.cap.tag.get
