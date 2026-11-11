; [LLM-generated] M7.1a: generic passes keep a "mem.move" fact on its slot.
; It is not a droppable hint. InstCombine must not delete a second move of
; the same slot. mem2reg and SROA must not promote the slot and poison the
; operand. LICM must not hoist the fact out of the loop, and must not sink
; the slot's stores to the exit past the fact.
; RUN: opt -S -passes=instcombine < %s | FileCheck %s --check-prefix=IC
; RUN: opt -S -passes=mem2reg < %s | FileCheck %s --check-prefix=M2R
; RUN: opt -S -passes=sroa < %s | FileCheck %s --check-prefix=SROA
; RUN: opt -S -passes='loop-mssa(licm)' < %s | FileCheck %s --check-prefix=LICM
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @llvm.mem.fact()

define void @twice(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  %v = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %v)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
  %w = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %w)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  ret void
}
; IC-LABEL: define void @twice(
; IC: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; IC: store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
; IC: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; IC-NOT: mem.dropped
; M2R-LABEL: define void @twice(
; M2R: %s = alloca ptr addrspace(200)
; M2R: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; M2R: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; M2R-NOT: mem.dropped
; SROA-LABEL: define void @twice(
; SROA: %s = alloca ptr addrspace(200)
; SROA: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; SROA-NOT: mem.dropped

; The fact's pointer is loop-invariant. It stays at the move, in the loop.
define void @nohoist(ptr addrspace(200) %p, i32 %n) {
entry:
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %loop ]
  %v = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %v)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  %i1 = add i32 %i, 1
  %c = icmp ult i32 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}
; LICM-LABEL: define void @nohoist(
; LICM: entry:
; LICM-NOT: mem.move
; LICM: loop:
; LICM: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
; LICM: exit:
; LICM-NOT: mem.move
