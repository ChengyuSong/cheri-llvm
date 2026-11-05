; [LLM-generated] M5r R10 (D70): a narrowing whose result is only accessed (load
; through it, a GEP/PHI induction, compares) gets no explicit tag test; its
; accesses carry the kind-5 cheri_trap_map record instead. A narrowing that escapes
; (passed to a call) keeps the R9 lazy check. The second run uses -cheri-narrow-tag-check-map-uses=false.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check -cheri-narrow-tag-check-map-uses=false < %s | FileCheck %s --check-prefix=NOMAP
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare void @use(ptr addrspace(200))

define i64 @sum(ptr addrspace(200) %p, i64 %n) {
entry:
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  %e = getelementptr i8, ptr addrspace(200) %q, i64 %n
  br label %h
h:
  %c = phi ptr addrspace(200) [ %q, %entry ], [ %c1, %h ]
  %a = phi i64 [ 0, %entry ], [ %a1, %h ]
  %v = load i64, ptr addrspace(200) %c
  %a1 = add i64 %a, %v
  %c1 = getelementptr i8, ptr addrspace(200) %c, i64 8
  %d = icmp eq ptr addrspace(200) %c1, %e
  br i1 %d, label %x, label %h
x:
  ret i64 %a1
}
; CHECK-LABEL: define i64 @sum(
; CHECK-NOT: cap.tag.get
; CHECK: load i64, ptr addrspace(200) %c, align 8, !pcsections
; CHECK: ret i64
; NOMAP-LABEL: define i64 @sum(
; NOMAP: cap.tag.get

define void @esc(ptr addrspace(200) %p, i64 %n) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  call void @use(ptr addrspace(200) %q)
  ret void
}
; CHECK-LABEL: define void @esc(
; CHECK: cap.tag.get
