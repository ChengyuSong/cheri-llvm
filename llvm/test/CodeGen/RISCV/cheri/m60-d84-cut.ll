; [LLM-generated] M6.0 D84. Facts end at riscv-cheri-bounds-lowering. The loan
; clear is a volatile null store tagged cheri_inv_loan, before lifetime.end.
; D89: that tag is !pcsections. The store's MachineMemOperand does not carry
; a loan id (no mem.loan after isel).
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=CUT
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=finalize-isel < %s | FileCheck %s --check-prefix=ISEL

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(i64, ptr addrspace(200))
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))

define void @loan(ptr addrspace(200) %p) addrspace(200) {
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(i64 16, ptr addrspace(200) %r)
  store ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  %c = load ptr addrspace(200), ptr addrspace(200) %r, align 16
  %v = load i32, ptr addrspace(200) %c, align 4, !mem.last_use !0
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %r)
  ret void
}

; CUT-LABEL: define void @loan(
; CUT-NOT: mem.fact
; CUT-NOT: "mem.
; CUT-NOT: !mem.guard
; CUT-NOT: !mem.last_use
; CUT-NOT: !mem.loan
; CUT-NOT: mem.claim
; CUT: store volatile ptr addrspace(200) null, ptr addrspace(200) %r{{.*}}!pcsections !0
; CUT: call {{.*}}@llvm.cheri.cap.invalidate
; CUT: call {{.*}}@llvm.lifetime.end
; CUT: !0 = !{!"cheri_inv_loan"}

; ISEL-NOT: mem.loan
; ISEL-NOT: mem.fact
; ISEL: CSC_128 {{.*}}pcsections !0 :: (volatile store {{.*}})
; ISEL: PseudoCheriCapInvalidate
; ISEL: LIFETIME_END

!0 = !{i64 5}
