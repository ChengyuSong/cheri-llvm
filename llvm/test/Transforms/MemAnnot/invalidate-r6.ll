; [LLM-generated] M5r R6 (D46): -cheri-narrow-tag-check: a user exact narrowing
; that turns a tagged capability into an untagged one faults right there, via
; a volatile load of the result tagged with a cheri_trap_map record (kind 5,
; no debug location: the function name as the file, line 0).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)

define ptr addrspace(200) @narrow(ptr addrspace(200) %p, i64 %n) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n)
  ret ptr addrspace(200) %q
}
; CHECK-LABEL: define ptr addrspace(200) @narrow(
; CHECK: %q = call addrspace(200) ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64
; CHECK: [[TI:%.*]] = call addrspace(200) i1 @llvm.cheri.cap.tag.get(ptr addrspace(200) %p)
; CHECK: [[TO:%.*]] = call addrspace(200) i1 @llvm.cheri.cap.tag.get(ptr addrspace(200) %q)
; CHECK: load volatile i8, ptr addrspace(200) %q, align 1, !pcsections [[MD:![0-9]+]]
; CHECK-NEXT: unreachable
; CHECK: [[MD]] = !{!"cheri_trap_map", [[AUX:![0-9]+]]}
; CHECK: [[AUX]] = !{i32 2091511821, i32 0, i32 0, i32 {{[0-9]+}}, [32 x i8] c"narrow\00
; OFF-LABEL: define ptr addrspace(200) @narrow(
; OFF-NOT: tag.get
; OFF: ret
