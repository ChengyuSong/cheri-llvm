; [LLM-generated] M5r R13 (D81): a narrowing whose select of two derived arms is used
; only by accesses, an `assume` "nonnull" bundle and a "mem.alloc_inbounds" fact
; (k5_fields_sum) gets no explicit tag test (D70); a real escape (a call argument) does.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64)
declare void @llvm.mem.fact()
declare void @llvm.assume(i1)
declare void @sink(ptr addrspace(200))
define i64 @facts(ptr addrspace(200) %p, i64 %n, i1 %b) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %q, i64 %n, i64 256)
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr addrspace(200) %q) ]
  %s = select i1 %b, ptr addrspace(200) %q, ptr addrspace(200) %c
  call void @llvm.assume(i1 true) [ "nonnull"(ptr addrspace(200) %s) ]
  %v = load i64, ptr addrspace(200) %s
  ret i64 %v
}
; CHECK-LABEL: define i64 @facts(
; CHECK-NOT: cap.tag.get
; CHECK: ret i64
define i64 @escape(ptr addrspace(200) %p, i64 %n) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  call void @sink(ptr addrspace(200) %q)
  %v = load i64, ptr addrspace(200) %q
  ret i64 %v
}
; CHECK-LABEL: define i64 @escape(
; CHECK: cap.tag.get
