; [LLM-generated] M6.0 D87. The loan value is live across an asm that clobbers
; every allocatable register, so RA spills it. The clear reloads that spill
; and then stores null to the spill slot. A second function pins the loan in
; callee-saved x20 (s4); the register is cleared before the later call, and
; the prologue save of the incoming x20 is not overwritten with null.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(i64, ptr addrspace(200))
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))
declare void @later() addrspace(200)

define void @pressure(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: pressure:
; CHECK: csc a0, 0(sp) {{.*}} Folded Spill
; CHECK: clc a0, 0(sp) {{.*}} Folded Reload
; CHECK-NEXT: csc zero, 0(sp) {{.*}} Folded Spill
; CHECK-NEXT: cmove a0, zero
; CHECK-NOT: clc a0
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(i64 16, ptr addrspace(200) %s)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16, !mem.loan !0
  %c = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void asm sideeffect "", "~{x1},~{x3},~{x4},~{x5},~{x6},~{x7},~{x8},~{x9},~{x10},~{x11},~{x12},~{x13},~{x14},~{x15},~{x16},~{x17},~{x18},~{x19},~{x20},~{x21},~{x22},~{x23},~{x24},~{x25},~{x26},~{x27},~{x28},~{x29},~{x30},~{x31}"()
  %v = load i32, ptr addrspace(200) %c, align 4, !mem.last_use !0
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %s)
  ret void
}

define void @saved(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: saved:
; CHECK: csc s4, 16(sp) {{.*}} Folded Spill
; CHECK: cmove s4, a0
; CHECK: cmove s4, zero
; CHECK-NEXT: ccall later
; CHECK-NOT: csc zero, 16(sp)
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(i64 16, ptr addrspace(200) %s)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16, !mem.loan !0
  %pinned = call ptr addrspace(200) asm sideeffect "", "={x20},{x20}"(ptr addrspace(200) %p)
  %v = load i32, ptr addrspace(200) %pinned, align 4, !mem.last_use !0
  call void @later()
  call void @llvm.lifetime.end.p200(i64 16, ptr addrspace(200) %s)
  ret void
}

!0 = !{i64 7}
