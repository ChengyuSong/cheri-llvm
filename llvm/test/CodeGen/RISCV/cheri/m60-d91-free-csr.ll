; [LLM-generated] M6.1 D91. A freed capability pinned in callee-saved s4/x20 is
; cleared after the dealloc call and before a later call, so the callee cannot
; save it. The prologue slot of the incoming s4 is not nulled. The clear also
; covers the argument the empty asm copied from.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200)) addrspace(200)
declare void @later() addrspace(200)

define void @freed(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: freed:
; CHECK: csc s4, 0(sp) {{.*}} Folded Spill
; CHECK: cmove s4, {{.*}}
; CHECK: ccall free
; CHECK: cmove s0, zero
; CHECK: cmove s4, zero
; CHECK-NEXT: ccall later
; CHECK: clc s4, 0(sp) {{.*}} Folded Reload
; CHECK-NOT: csc zero, 0(sp)
  %pinned = call ptr addrspace(200) asm sideeffect "", "={x20},{x20}"(ptr addrspace(200) %p)
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @later()
  ret void
}

; IR-LABEL: define void @freed(
; IR: call {{.*}}@free(ptr addrspace(200) %p)
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p)
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %pinned)
; IR: call {{.*}}@later()
