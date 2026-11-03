; LLM-generated test for the local M3.1 prototype: a contract's spatial fact
; ("mem.alloc_inbounds") is what lets cheri-skip-narrow drop a checked access
; narrow in a C definition, exactly as for a Rust &[T] parameter.
; RUN: opt -S -passes='mem-contract-c,function(cheri-skip-narrow)' < %s | FileCheck %s
; RUN: opt -S -passes='mem-contract-c,function(cheri-skip-narrow)' -mem-contract-spatial-only < %s | FileCheck %s
; RUN: opt -S -passes='function(cheri-skip-narrow)' < %s | FileCheck %s --check-prefix=NOCONTRACT
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@s.slice = private unnamed_addr addrspace(200) constant [19 x i8] c"mem.contract.slice\00", section "llvm.metadata"
@s.file = private unnamed_addr addrspace(200) constant [4 x i8] c"t.c\00", section "llvm.metadata"
@a.slice_u64 = private unnamed_addr addrspace(200) constant { i32, i32, i64, i64 } { i32 1, i32 2, i64 8, i64 8 }, section "llvm.metadata"
@llvm.global.annotations = appending addrspace(200) global [1 x { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) }] [{ ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @sum_def, ptr addrspace(200) @s.slice, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.slice_u64 }], section "llvm.metadata"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64)

; CHECK-LABEL: define i64 @sum_def(ptr addrspace(200) {{.*}}"mem.alloc_inbounds" "mem.range"="1:8" %p, i64 {{(noundef )?}}range(i64 0, 1152921504606846976) %n, i64 %i)
; CHECK-NOT: bounds.set
; CHECK: ret i64
; NOCONTRACT-LABEL: define i64 @sum_def(
; NOCONTRACT: call {{.*}}@llvm.cheri.cap.bounds.set.i64(
define i64 @sum_def(ptr addrspace(200) %p, i64 %n, i64 %i) {
  %sz = shl i64 %n, 3
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %sz) [ "mem.checked"(ptr addrspace(200) %p, i64 %sz) ], !cheri.access_narrow !0
  %g = getelementptr inbounds i64, ptr addrspace(200) %c, i64 %i
  %v = load i64, ptr addrspace(200) %g
  ret i64 %v
}
!0 = !{}
