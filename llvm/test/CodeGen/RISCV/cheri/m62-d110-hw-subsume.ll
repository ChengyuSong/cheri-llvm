; [LLM-generated] M6.2 D110 through instruction selection at -O0.
; The compare is `icmp ult` of the index against the setbounds length.
; ISel turns that into ADDI x0, len-1 and BLTU. A GEP that is only loaded
; or stored is deleted with the branch. The setbounds stays.
;
; -O2 is not this slice: MachineSink moves CSetBoundsImm into the use
; block before the pass, so the one-block pattern does not match.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O0 -stop-after=riscv-cheri-hw-subsume -verify-machineinstrs -o - %s | FileCheck %s

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64)
declare void @llvm.trap()
declare void @use_i64(i64)

define i8 @match(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: match
; CHECK: CSetBoundsImm
; CHECK-SAME: 32
; CHECK-NOT: BLTU
; CHECK-NOT: BGEU
; CHECK: CIncOffset
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

define void @store_byte(ptr addrspace(200) %base, i64 %i, i8 %v) addrspace(200) nounwind {
; CHECK-LABEL: name: store_byte
; CHECK: CSetBoundsImm
; CHECK-NOT: BLTU
; CHECK-NOT: BGEU
; CHECK: CSB
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok = icmp ult i64 %i, 32
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  store i8 %v, ptr addrspace(200) %p
  ret void
panic:
  call void @llvm.trap()
  unreachable
}

define void @escape_store(ptr addrspace(200) %base, ptr addrspace(200) %slot, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: escape_store
; CHECK: CSetBoundsImm
; CHECK: BLTU
; CHECK: CSC_128
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 32)
  %ok = icmp ult i64 %i, 32
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  store ptr addrspace(200) %p, ptr addrspace(200) %slot
  ret void
panic:
  call void @llvm.trap()
  unreachable
}

define ptr addrspace(200) @escape_ret(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: escape_ret
; CHECK: CSetBoundsImm
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

define i8 @shared(ptr addrspace(200) %base, i64 %i, i64 %j) addrspace(200) nounwind {
; CHECK-LABEL: name: shared
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

define void @call_arg(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: call_arg
; CHECK: CSetBoundsImm
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

define i8 @len4096(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: len4096
; CHECK: CSetBounds
; ISel of `ult i, 4096` is a shift and BNE, not BGEU. Either way it stays:
; 4096 is not an exact CSetBoundsImm length.
; CHECK: BNE
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 4096)
  %ok = icmp ult i64 %i, 4096
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  %v = load i8, ptr addrspace(200) %p
  ret i8 %v
panic:
  call void @llvm.trap()
  unreachable
}

define i8 @bound4095(ptr addrspace(200) %base, i64 %i) addrspace(200) nounwind {
; CHECK-LABEL: name: bound4095
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

define i8 @variable(ptr addrspace(200) %base, i64 %i, i64 %n) addrspace(200) nounwind {
; CHECK-LABEL: name: variable
; CHECK: CSetBounds
; CHECK: BGEU
  %cap = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 %n)
  %ok = icmp ult i64 %i, %n
  br i1 %ok, label %use, label %panic
use:
  %p = getelementptr inbounds i8, ptr addrspace(200) %cap, i64 %i
  %v = load i8, ptr addrspace(200) %p
  ret i8 %v
panic:
  call void @llvm.trap()
  unreachable
}
