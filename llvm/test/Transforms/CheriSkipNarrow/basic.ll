; LLM-generated test for the local CheriSkipNarrow prototype.
; RUN: opt -S -passes=cheri-skip-narrow < %s | FileCheck %s
; RUN: opt -S -passes=cheri-skip-narrow -cheri-skip-narrow=false < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200), i64)
declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)

; Proven by call metadata: removed.
; CHECK-LABEL: @proven_md(
; CHECK-NOT: bounds.set
; CHECK: load i64, ptr addrspace(200) %g
; OFF-LABEL: @proven_md(
; OFF: call {{.*}}@llvm.cheri.cap.bounds.set.i64(
define i64 @proven_md(ptr addrspace(200) %p, i64 %n, i64 %i) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %n) [ "mem.checked"(ptr addrspace(200) %p, i64 %n) ], !cheri.access_narrow !0, !mem.alloc_inbounds !0
  %g = getelementptr inbounds i64, ptr addrspace(200) %c, i64 %i
  %v = load i64, ptr addrspace(200) %g
  ret i64 %v
}

; Proven through an inbounds GEP of an alloc_inbounds argument: removed.
; CHECK-LABEL: @proven_arg(
; CHECK-NOT: bounds.set
define i64 @proven_arg(ptr addrspace(200) "mem.alloc_inbounds" %p, i64 %i) {
  %row = getelementptr inbounds i8, ptr addrspace(200) %p, i64 32
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %row, i64 32) [ "mem.checked"(ptr addrspace(200) %row, i64 32) ], !cheri.access_narrow !0
  %g = getelementptr inbounds i64, ptr addrspace(200) %c, i64 %i
  %v = load i64, ptr addrspace(200) %g
  ret i64 %v
}

; Non-inbounds GEP breaks propagation: kept.
; CHECK-LABEL: @plain_gep_kept(
; CHECK: bounds.set.exact
define i64 @plain_gep_kept(ptr addrspace(200) "mem.alloc_inbounds" %p, i64 %o) {
  %row = getelementptr i8, ptr addrspace(200) %p, i64 %o
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %row, i64 32) [ "mem.checked"(ptr addrspace(200) %row, i64 32) ], !cheri.access_narrow !0
  %v = load i64, ptr addrspace(200) %c
  ret i64 %v
}

; Sole check (software check removed, e.g. rustc elide): no !mem.checked, so kept
; even though the base is alloc_inbounds (regression test for an unsound skip).
; CHECK-LABEL: @sole_check_kept(
; CHECK: bounds.set.exact
define i64 @sole_check_kept(ptr addrspace(200) "mem.alloc_inbounds" %p, i64 %i) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 64), !cheri.access_narrow !0, !mem.alloc_inbounds !0
  %g = getelementptr inbounds i64, ptr addrspace(200) %c, i64 %i
  %v = load i64, ptr addrspace(200) %g
  ret i64 %v
}

; checked-only (e.g. raw fat pointer after RefProp) is not a proof: kept.
; CHECK-LABEL: @checked_only_kept(
; CHECK: bounds.set
define i64 @checked_only_kept(ptr addrspace(200) %p, i64 %n) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %n) [ "mem.checked"(ptr addrspace(200) %p, i64 %n) ], !cheri.access_narrow !0
  %v = load i64, ptr addrspace(200) %c
  ret i64 %v
}

; Allocation-level bounds (no !cheri.access_narrow) are never touched.
; CHECK-LABEL: @alloc_level_kept(
; CHECK: bounds.set.exact
define ptr addrspace(200) @alloc_level_kept(ptr addrspace(200) "mem.alloc_inbounds" %p) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 64), !mem.alloc_inbounds !0
  ret ptr addrspace(200) %c
}


; Legacy operand-less !mem.checked on a narrow is not a proof: kept.
; CHECK-LABEL: @legacy_md_kept(
; CHECK: bounds.set
define i64 @legacy_md_kept(ptr addrspace(200) "mem.alloc_inbounds" %p, i64 %n) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %n), !cheri.access_narrow !0, !mem.checked !0
  %v = load i64, ptr addrspace(200) %c
  ret i64 %v
}

; Bundle inconsistent with the narrow (checks a different length): kept, and
; the bundle is stripped from the kept call (replaced by !mem.checked !{}).
; CHECK-LABEL: @inconsistent_kept(
; CHECK: call {{.*}}bounds.set.i64(ptr addrspace(200) %p, i64 %n), !cheri.access_narrow !0, !mem.checked !0
; CHECK-NOT: "mem.checked"
define i64 @inconsistent_kept(ptr addrspace(200) "mem.alloc_inbounds" %p, i64 %n, i64 %m) {
  %c = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %p, i64 %n) [ "mem.checked"(ptr addrspace(200) %p, i64 %m) ], !cheri.access_narrow !0
  %v = load i64, ptr addrspace(200) %c
  ret i64 %v
}

; OFF (stronger mode): proven narrows stay, bundle stripped.
; OFF-LABEL: @proven_arg(
; OFF: call {{.*}}bounds.set.exact.i64(ptr addrspace(200) %row, i64 32), !cheri.access_narrow !0, !mem.checked !0
; OFF-NOT: "mem.checked"(

!0 = !{}
