; M3.3 [LLM-generated]: conversion narrows (!cheri.contract_narrow) are discharged
; when their operand is provably allocation-bounded, and kept otherwise.
; RUN: opt -S -passes=cheri-contract-discharge %s | FileCheck %s
; RUN: opt -S -passes=cheri-skip-narrow %s | FileCheck %s
; RUN: opt -S -passes=cheri-contract-discharge -cheri-skip-narrow=false %s | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -passes=cheri-contract-discharge -cheri-contract-discharge=false %s | FileCheck %s --check-prefix=KEEP
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64)
declare ptr addrspace(200) @source()
@g = addrspace(200) global [4 x i64] zeroinitializer

; A typed (alloc_inbounds) parameter, through a GEP: discharged.
; CHECK-LABEL: @typed_arg(
; CHECK-NOT: bounds.set
; KEEP-LABEL: @typed_arg(
; KEEP: bounds.set
define i64 @typed_arg(ptr addrspace(200) "mem.alloc_inbounds" %s, i64 %n) {
  %p = getelementptr i64, ptr addrspace(200) %s, i64 1
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v = load i64, ptr addrspace(200) %q
  ret i64 %v
}

; A raw parameter (from C): kept.
; CHECK-LABEL: @raw_arg(
; CHECK: call {{.*}}bounds.set{{.*}}%p, i64 %b){{.*}}!cheri.contract_narrow
define i64 @raw_arg(ptr addrspace(200) %p, i64 %b) {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %b), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v = load i64, ptr addrspace(200) %q
  ret i64 %v
}

; An untagged call result and a loaded pointer: kept.
; CHECK-LABEL: @call_and_load(
; CHECK: bounds.set{{.*}}%c,
; CHECK: bounds.set{{.*}}%l,
define i64 @call_and_load(ptr addrspace(200) "mem.alloc_inbounds" %pp) {
  %c = call ptr addrspace(200) @source()
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %c, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %l = load ptr addrspace(200), ptr addrspace(200) %pp
  %r = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %l, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v = load i64, ptr addrspace(200) %q
  %w = load i64, ptr addrspace(200) %r
  %s = add i64 %v, %w
  ret i64 %s
}

; A rustc-tagged value (an earlier conversion narrow), a global and an alloca: discharged.
; CHECK-LABEL: @tagged_global_alloca(
; CHECK: bounds.set{{.*}}%p, i64 32)
; CHECK-NOT: bounds.set
; CHECK: ret
define i64 @tagged_global_alloca(ptr addrspace(200) %p) {
  %a = alloca [4 x i64], addrspace(200)
  %n1 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 32), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %n2 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %n1, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %n3 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) @g, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %n4 = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %a, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v1 = load i64, ptr addrspace(200) %n2
  %v2 = load i64, ptr addrspace(200) %n3
  %v3 = load i64, ptr addrspace(200) %n4
  %s1 = add i64 %v1, %v2
  %s2 = add i64 %s1, %v3
  ret i64 %s2
}

; A loop phi over an alloc_inbounds parameter (slice iteration): discharged.
; A phi with one raw input: kept.
; CHECK-LABEL: @loop_phi(
; CHECK-NOT: bounds.set
; CHECK: ret
define i64 @loop_phi(ptr addrspace(200) "mem.alloc_inbounds" %s, i64 %n) {
entry:
  br label %loop
loop:
  %p = phi ptr addrspace(200) [ %s, %entry ], [ %p1, %loop ]
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v = load i64, ptr addrspace(200) %q
  %p1 = getelementptr inbounds i64, ptr addrspace(200) %p, i64 1
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret i64 %v
}
; CHECK-LABEL: @mixed_phi(
; CHECK: bounds.set
define i64 @mixed_phi(ptr addrspace(200) "mem.alloc_inbounds" %s, ptr addrspace(200) %raw, i1 %c) {
entry:
  br i1 %c, label %a, label %b
a:
  br label %m
b:
  br label %m
m:
  %p = phi ptr addrspace(200) [ %s, %a ], [ %raw, %b ]
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 8), !cheri.contract_narrow !0, !mem.alloc_inbounds !0
  %v = load i64, ptr addrspace(200) %q
  ret i64 %v
}

!0 = !{}
