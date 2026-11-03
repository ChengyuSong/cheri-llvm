; RUN: opt -mtriple=riscv64 -mattr=+xcheri,+xcheripurecap -target-abi l64pc128d -passes=instcombine -S %s | FileCheck %s --check-prefixes=CHECK,RV64
; RUN: opt -mtriple=riscv64 -passes=instcombine -S %s | FileCheck %s --check-prefix=NOCHERI
;
; CRRL/CRAM of a constant length fold at the IR level, and an unused heap
; allocation whose capability is only bounded, compared and freed is removed.

target datalayout = "pf200:128:128:128:64-A200-P200-G200"

declare i64 @llvm.cheri.round.representable.length.i64(i64) addrspace(200)
declare i64 @llvm.cheri.representable.alignment.mask.i64(i64) addrspace(200)
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64) addrspace(200)
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64) addrspace(200)
declare noalias ptr addrspace(200) @malloc(i64) addrspace(200) allockind("alloc,uninitialized") allocsize(0) "alloc-family"="malloc"
declare void @free(ptr addrspace(200) allocptr) addrspace(200) allockind("free") "alloc-family"="malloc"

; 0x3ff8 carries into the next exponent: length 0x4000, alignment 32.
define i64 @crrl_carry() addrspace(200) {
; CHECK-LABEL: @crrl_carry(
; RV64-NEXT:  ret i64 16384
; NOCHERI:    call {{.*}}i64 @llvm.cheri.round.representable.length.i64(i64 16376)
  %r = call i64 @llvm.cheri.round.representable.length.i64(i64 16376)
  ret i64 %r
}

define i64 @cram_carry() addrspace(200) {
; CHECK-LABEL: @cram_carry(
; RV64-NEXT:  ret i64 -32
; NOCHERI:    call {{.*}}i64 @llvm.cheri.representable.alignment.mask.i64(i64 16376)
  %m = call i64 @llvm.cheri.representable.alignment.mask.i64(i64 16376)
  ret i64 %m
}

define i64 @crrl_small() addrspace(200) {
; CHECK-LABEL: @crrl_small(
; CHECK-NEXT:  ret i64 24
  %r = call i64 @llvm.cheri.round.representable.length.i64(i64 24)
  ret i64 %r
}

define i64 @crrl_dynamic(i64 %n) addrspace(200) {
; CHECK-LABEL: @crrl_dynamic(
; CHECK-NEXT:  call {{.*}}i64 @llvm.cheri.round.representable.length.i64(i64 %n)
  %r = call i64 @llvm.cheri.round.representable.length.i64(i64 %n)
  ret i64 %r
}

define i1 @unused_bounded_alloc(i64 %x) addrspace(200) {
; CHECK-LABEL: @unused_bounded_alloc(
; CHECK-NEXT:  ret i1 false
  %p = call ptr addrspace(200) @malloc(i64 32)
  %b = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 32)
  %c = icmp eq ptr addrspace(200) %b, null
  store i64 %x, ptr addrspace(200) %b
  call void @free(ptr addrspace(200) %b)
  ret i1 %c
}

define void @unused_bounded_alloc_inexact() addrspace(200) {
; CHECK-LABEL: @unused_bounded_alloc_inexact(
; CHECK-NEXT:  ret void
  %p = call ptr addrspace(200) @malloc(i64 100)
  %b = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 100)
  call void @free(ptr addrspace(200) %b)
  ret void
}

; Escaping bounded capability: the allocation stays.
define ptr addrspace(200) @escaping_bounded_alloc() addrspace(200) {
; CHECK-LABEL: @escaping_bounded_alloc(
; CHECK:       call {{.*}} @malloc(i64 32)
; CHECK:       @llvm.cheri.cap.bounds.set.exact
  %p = call ptr addrspace(200) @malloc(i64 32)
  %b = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 32)
  ret ptr addrspace(200) %b
}
