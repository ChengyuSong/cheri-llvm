; [LLM-generated] M6.0 D87. llvm.cheri.cap.invalidate only clears the register.
; cheri-bound-allocas must treat that use as known and not needing bounds,
; and must not warn "Don't know how to handle intrinsic".
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O0 -stop-after=cheri-bound-allocas < %s -o - 2>%t.err0 | FileCheck %s
; RUN: FileCheck %s --check-prefix=ERR --allow-empty < %t.err0
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=cheri-bound-allocas < %s -o - 2>%t.err2 | FileCheck %s
; RUN: FileCheck %s --check-prefix=ERR --allow-empty < %t.err2

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.cheri.cap.invalidate(ptr addrspace(200))

define void @direct(ptr addrspace(200) %p) addrspace(200) optnone noinline {
  %a = alloca i32, align 4, addrspace(200)
  store volatile i32 1, ptr addrspace(200) %a, align 4
  call void @llvm.cheri.cap.invalidate(ptr addrspace(200) %a)
  ret void
}

define void @through_gep() addrspace(200) {
  %a = alloca i32, align 4, addrspace(200)
  %g = getelementptr inbounds i32, ptr addrspace(200) %a, i64 0
  store volatile i32 1, ptr addrspace(200) %a, align 4
  call void @llvm.cheri.cap.invalidate(ptr addrspace(200) %g)
  ret void
}

; ERR-NOT: Don't know how to handle intrinsic
; ERR-NOT: DON'T know how to handle

; CHECK-LABEL: define void @direct(
; CHECK-NOT: llvm.cheri.bounded.stack.cap
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %a)
; CHECK-LABEL: define void @through_gep(
; CHECK-NOT: llvm.cheri.bounded.stack.cap
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %g)
