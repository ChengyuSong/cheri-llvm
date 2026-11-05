; [LLM-generated] M5r R9 (D66): the D46 check branches on the narrowed result's
; tag first; the input's tag is read only on that cold path (prefix EAGER = R8 form,
; both tags and an `and` on the hot path).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check -cheri-narrow-tag-check-lazy=false < %s | FileCheck %s --check-prefix=EAGER
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)
declare void @use(ptr addrspace(200))

define void @var(ptr addrspace(200) %p, i64 %n) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  call void @use(ptr addrspace(200) %q)
  ret void
}
; CHECK-LABEL: define void @var(
; CHECK: %q = call {{.*}}@llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.tag.get(ptr addrspace(200) %q)
; CHECK-NOT: cap.tag.get
; CHECK: br i1
; CHECK: call {{.*}}@llvm.cheri.cap.tag.get(ptr addrspace(200) %p)
; CHECK-NEXT: br i1
; CHECK: load volatile i8, ptr addrspace(200) %q{{.*}}!pcsections
; CHECK-NEXT: unreachable
; CHECK: call {{.*}}void @use(
; EAGER-LABEL: define void @var(
; EAGER: tag.get{{.*}}(ptr addrspace(200) %p)
; EAGER-NEXT: tag.get
; EAGER-NEXT: xor
; EAGER-NEXT: and
