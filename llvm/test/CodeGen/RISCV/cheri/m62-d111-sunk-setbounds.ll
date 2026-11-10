; [LLM-generated] M6.2 D111. At -O2 MachineSink places CSetBoundsImm in the
; success block. The compare in the predecessor is removed when the
; access is a non-escaping load or store through that capability.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-hw-subsume -verify-machineinstrs -o - %s | FileCheck %s

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64)
declare void @llvm.trap()
declare void @use_i64(i64)

define i8 @sunk_load(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: sunk_load
; CHECK: CSetBoundsImm
; CHECK-SAME: 32
; CHECK-NOT: BLTU
; CHECK-NOT: BGEU
; CHECK: CLB
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok = icmp ult i64 %i, 32
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  %v = load i8, ptr addrspace(200) %p
  ret i8 %v
panic:
  call void @llvm.trap()
  unreachable
}

define i8 @sunk_4095(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: sunk_4095
; CHECK: CSetBoundsImm
; CHECK-SAME: 4095
; CHECK-NOT: BLTU
; CHECK-NOT: BGEU
; CHECK: CLB
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 4095)
  %ok = icmp ult i64 %i, 4095
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  %v = load i8, ptr addrspace(200) %p
  ret i8 %v
panic:
  call void @llvm.trap()
  unreachable
}

define ptr addrspace(200) @sunk_returned(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: sunk_returned
; CHECK: BLTU
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok = icmp ult i64 %i, 32
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  ret ptr addrspace(200) %p
panic:
  call void @llvm.trap()
  unreachable
}

define i8 @sunk_shared(ptr addrspace(200) %base, i64 %i, i64 %j) addrspace(200) nounwind {
; CHECK-LABEL: name: sunk_shared
; CHECK: BLTU
; CHECK: BLTU
  %c1 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok1 = icmp ult i64 %i, 32
  br i1 %ok1, label %mid, label %panic
mid:
  %c2 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 16)
  %ok2 = icmp ult i64 %j, 16
  br i1 %ok2, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %c1, i64 %i
  %q = getelementptr inbounds i8, ptr addrspace(200) %c2, i64 %j
  %v = load i8, ptr addrspace(200) %p
  %w = load i8, ptr addrspace(200) %q
  %s = add i8 %v, %w
  ret i8 %s
panic:
  call void @llvm.trap()
  unreachable
}

define void @sunk_call(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: sunk_call
; CHECK: BLTU
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok = icmp ult i64 %i, 32
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  %v = load i8, ptr addrspace(200) %p
  call void @use_i64(i64 %i)
  ret void
panic:
  call void @llvm.trap()
  unreachable
}
