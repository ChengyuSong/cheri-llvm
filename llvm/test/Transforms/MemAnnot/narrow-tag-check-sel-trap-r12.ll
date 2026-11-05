; [LLM-generated] M5r R12 (D78/D76b): a narrowing whose only non-access uses are a
; "mem.check" operand bundle on llvm.trap, or a select with a same-base value, gets
; no explicit tag test (D70); a select with an unrelated pointer still escapes.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare void @llvm.trap()
define i64 @bundle(ptr addrspace(200) %p, i64 %n, i1 %b) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  br i1 %b, label %t, label %ok
t:
  call void @llvm.trap() [ "mem.check"(ptr addrspace(200) %q, i64 %n, i64 8, i64 1, i64 5) ]
  unreachable
ok:
  %v = load i64, ptr addrspace(200) %q
  ret i64 %v
}
; CHECK-LABEL: define i64 @bundle(
; CHECK-NOT: cap.tag.get
; CHECK: ret i64
define i64 @samebase(ptr addrspace(200) %p, i64 %n, i1 %b) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  %o = getelementptr i8, ptr addrspace(200) %p, i64 16
  %s = select i1 %b, ptr addrspace(200) %q, ptr addrspace(200) %o
  %v = load i64, ptr addrspace(200) %s
  ret i64 %v
}
; CHECK-LABEL: define i64 @samebase(
; CHECK-NOT: cap.tag.get
; CHECK: ret i64
define i64 @other(ptr addrspace(200) %p, ptr addrspace(200) %r, i64 %n, i1 %b) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  %s = select i1 %b, ptr addrspace(200) %q, ptr addrspace(200) %r
  %v = load i64, ptr addrspace(200) %s
  ret i64 %v
}
; CHECK-LABEL: define i64 @other(
; CHECK: cap.tag.get
