; [LLM-generated] M6.0 D86. A volatile null before lifetime.end survives -O2
; and keeps its cheri_inv_loan pcsections label. D92's scope register clear
; sits on the chain before lifetime.end, so visitLIFETIME_END no longer
; deletes the plain store; that store still has no cheri_inv section.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))

define void @nonvol(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: nonvol:
; CHECK: csc zero, 0(sp)
; CHECK: cmove a0, zero
; CHECK-NOT: .section cheri_inv
; CHECK: cret
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %a, align 16
  store ptr addrspace(200) null, ptr addrspace(200) %a, align 16
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %a)
  ret void
}

define void @vol(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: vol:
; CHECK: .Lpcsection
; CHECK-NEXT: csc zero, 0(sp)
; CHECK: .section cheri_inv_loan
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %a, align 16
  store volatile ptr addrspace(200) null, ptr addrspace(200) %a, align 16, !pcsections !0
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %a)
  ret void
}

!0 = !{!"cheri_inv_loan"}
