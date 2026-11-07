; [LLM-generated] M6.1 D92. At lifetime.end the alloca and an empty-asm copy of
; it are cleared. The copy is live across a full clobber, so RA spills it and
; the post-RA pass nulls that spill slot.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(i64, ptr addrspace(200))
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))

define void @scope_spill() addrspace(200) {
; CHECK-LABEL: scope_spill:
; CHECK: csc a0, 0(sp) {{.*}} Folded Spill
; CHECK: clc a0, 0(sp) {{.*}} Folded Reload
; CHECK-NEXT: csc zero, 0(sp) {{.*}} Folded Spill
; CHECK-NEXT: cmove a0, zero
  %a = alloca i8, align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(i64 1, ptr addrspace(200) %a)
  %c = call ptr addrspace(200) asm sideeffect "", "={x10},{x10}"(ptr addrspace(200) %a)
  call void asm sideeffect "", "~{x1},~{x3},~{x4},~{x5},~{x6},~{x7},~{x8},~{x9},~{x10},~{x11},~{x12},~{x13},~{x14},~{x15},~{x16},~{x17},~{x18},~{x19},~{x20},~{x21},~{x22},~{x23},~{x24},~{x25},~{x26},~{x27},~{x28},~{x29},~{x30},~{x31}"()
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  ret void
}

; IR-LABEL: define void @scope_spill(
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %a)
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %c)
; IR: call {{.*}}@llvm.lifetime.end
