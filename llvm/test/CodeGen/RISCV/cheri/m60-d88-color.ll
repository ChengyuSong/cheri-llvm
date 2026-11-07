; [LLM-generated] M6.0 D88. The clear is before LIFETIME_END. After stack
; coloring merges the two slots, that clear still runs before the second
; object's first store.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-before=stack-coloring < %s | FileCheck %s --check-prefix=BEFORE
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=stack-coloring < %s | FileCheck %s --check-prefix=AFTER

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(i64, ptr addrspace(200))
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))
declare void @use(ptr addrspace(200))

define void @color(ptr addrspace(200) %p, ptr addrspace(200) %q) addrspace(200) {
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(i64 16, ptr addrspace(200) %a)
  store ptr addrspace(200) %p, ptr addrspace(200) %a, align 16
  store volatile ptr addrspace(200) null, ptr addrspace(200) %a, align 16, !pcsections !0
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %a)
  call void @llvm.lifetime.start.p200(i64 16, ptr addrspace(200) %b)
  store ptr addrspace(200) %q, ptr addrspace(200) %b, align 16
  %lb = load ptr addrspace(200), ptr addrspace(200) %b, align 16
  call void @use(ptr addrspace(200) %lb)
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %b)
  ret void
}

; D92 inserts a register clear of the alloca before each lifetime.end.
; BEFORE: CSC_128 {{.*}}pcsections
; BEFORE: PseudoCheriCapInvalidate
; BEFORE: LIFETIME_END %stack.0
; BEFORE: LIFETIME_START %stack.1
; BEFORE-NOT: pcsections

; AFTER: CSC_128 {{.*}}%stack.0{{.*}}pcsections
; AFTER: PseudoCheriCapInvalidate
; AFTER: CSC_128 {{.*}}%stack.0

!0 = !{!"cheri_inv_loan"}
