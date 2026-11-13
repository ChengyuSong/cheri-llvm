; [LLM-generated] M7.1d B2a: generic passes keep a "mem.store_into" fact.
; InstCombine must not delete a second fact for the same dest. LICM must
; not hoist it.
;
; RUN: opt -S -passes=instcombine < %s | FileCheck %s --check-prefix=IC
; RUN: opt -S -passes='loop-mssa(licm)' < %s | FileCheck %s --check-prefix=LICM
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @llvm.mem.fact()

define void @twice(ptr addrspace(200) %dest, ptr addrspace(200) %cap) {
  store ptr addrspace(200) %cap, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
  store ptr addrspace(200) %cap, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
  ret void
}
; IC-LABEL: define void @twice(
; IC: call {{.*}}@llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
; IC: store ptr addrspace(200) %cap, ptr addrspace(200) %dest, align 16
; IC: call {{.*}}@llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
; IC-NOT: mem.dropped

define void @nohoist(ptr addrspace(200) %dest, ptr addrspace(200) %cap, i32 %n) {
entry:
  store ptr addrspace(200) %cap, ptr addrspace(200) %dest, align 16
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %loop ]
  %v = load ptr addrspace(200), ptr addrspace(200) %dest, align 16
  call void @use(ptr addrspace(200) %v)
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
  %i1 = add i32 %i, 1
  %c = icmp ult i32 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}
; LICM-LABEL: define void @nohoist(
; LICM: entry:
; LICM-NOT: mem.store_into
; LICM: loop:
; LICM: call {{.*}}@llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %cap) ]
; LICM: exit:
; LICM-NOT: mem.store_into
