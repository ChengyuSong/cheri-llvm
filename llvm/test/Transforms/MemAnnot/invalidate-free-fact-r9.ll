; [LLM-generated] M5r R9 (D67): a "mem.free" kept on llvm.mem.fact (an inlined deallocator) is a free event for -cheri-invalidate=free: live frame slots whose base lies in the freed bounds are cleared after it.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=free < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
declare void @llvm.mem.fact()
declare void @use(ptr addrspace(200))
define i64 @f(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.free"(ptr addrspace(200) %p) ]
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  %x = load i64, ptr addrspace(200) %q
  ret i64 %x
}
; CHECK-LABEL: define i64 @f(
; CHECK: store volatile ptr addrspace(200) %p, ptr addrspace(200) %s
; CHECK-NOT: llvm.mem.fact
; CHECK: @llvm.cheri.cap.base.get.i64(ptr addrspace(200) %p)
; CHECK: @llvm.cheri.cap.tag.clear
; CHECK: store ptr addrspace(200) %{{.*}}, ptr addrspace(200) %s, align 16, !pcsections
; CHECK: %q = load volatile
