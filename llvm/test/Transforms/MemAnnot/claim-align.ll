; [LLM-generated] M5r R1: a claim must not stop InstCombine from raising the
; alignment of the claimed alloca (memset/load through a sub-range claim).
; RUN: opt -passes=infer-alignment -S %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64 immarg)
declare void @use(ptr addrspace(200))

; CHECK-LABEL: @f(
; CHECK: %a = alloca [64 x i8], align 16
; CHECK: load i128, ptr addrspace(200) %c, align 16
define i128 @f() addrspace(200) {
  %a = alloca [64 x i8], align 1, addrspace(200)
  call void @use(ptr addrspace(200) %a)
  %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %a, i64 20, i64 261)
  %v = load i128, ptr addrspace(200) %c, align 1
  ret i128 %v
}
