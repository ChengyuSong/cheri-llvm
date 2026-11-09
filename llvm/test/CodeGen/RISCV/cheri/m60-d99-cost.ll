; [LLM-generated] M6.1 D99/D100. A local alloca is not cleared. An address
; that is passed to a call is cleared when a callee could still save it.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s --check-prefix=ASM
; RUN: FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))
declare void @later() addrspace(200)
declare void @use(ptr addrspace(200)) addrspace(200)

define void @local() addrspace(200) {
; IR-LABEL: define void @local(
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %a, i32 2)
; ASM-LABEL: local:
; ASM-NOT: cmove
; ASM: ccall later
  %a = alloca i8, align 16, addrspace(200)
  %b = load i8, ptr addrspace(200) %a
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @later()
  ret void
}

define void @escaped() addrspace(200) {
; IR-LABEL: define void @escaped(
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %c, i32 1)
; ASM-LABEL: escaped:
; ASM: cmove s4, zero
; ASM: ccall later
  %a = alloca i8, align 16, addrspace(200)
  %c = call ptr addrspace(200) asm sideeffect "", "={x20},{x20}"(ptr addrspace(200) %a)
  call void @use(ptr addrspace(200) %c)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @later()
  ret void
}

; STATS: capreg_skipped_noescape=
