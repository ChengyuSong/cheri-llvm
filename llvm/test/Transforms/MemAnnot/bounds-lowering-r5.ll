; [LLM-generated] M5r R5 (D30): base-wide guard recovery for a fully unrolled
; loop (semantics s6): the per-iteration accesses are constant-offset GEPs of
; the base (or the base itself) without !mem.guard, and the exit tests are
; `icmp eq len, K` sharing one panic block. Each split marker recovers the
; access at base + K * esz in its Ok block; ub removes every check.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub < %s | FileCheck %s --check-prefix=UB
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-recover-const=false < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@D = global [3 x i64] zeroinitializer

declare void @panic(i64, i64) noreturn cold

define void @unrolled(ptr addrspace(200) %s, i64 %len) {
entry:
  %e0 = icmp eq i64 %len, 0
  br i1 %e0, label %panic, label %b0
b0:
  %v0 = load i64, ptr addrspace(200) %s, align 8
  store i64 %v0, ptr @D, align 8
  %e1 = icmp eq i64 %len, 1
  br i1 %e1, label %panic, label %b1
b1:
  %p1 = getelementptr inbounds nuw i8, ptr addrspace(200) %s, i64 8
  %v1 = load i64, ptr addrspace(200) %p1, align 8
  store i64 %v1, ptr getelementptr (i8, ptr @D, i64 8), align 8
  %e2 = icmp eq i64 %len, 2
  br i1 %e2, label %panic, label %b2
b2:
  %p2 = getelementptr inbounds nuw i8, ptr addrspace(200) %s, i64 16
  %v2 = load i64, ptr addrspace(200) %p2, align 8
  store i64 %v2, ptr getelementptr (i8, ptr @D, i64 16), align 8
  ret void
panic:
  %k = phi i64 [ 0, %entry ], [ 1, %b0 ], [ 2, %b1 ]
  call void @panic(i64 %k, i64 %len) [ "mem.check"(ptr addrspace(200) %s, i64 %len, i64 8, i64 7, i64 0) ]
  unreachable
}
; UB-LABEL: define void @unrolled(
; UB: entry:
; UB-NOT: icmp eq
; UB: @llvm.cheri.cap.bounds.set.exact
; UB: b0:
; UB-NOT: icmp eq
; UB: b1:
; UB-NOT: icmp eq
; UB: b2:
; UB-NOT: @panic
; UB: ret void
; OFF-LABEL: define void @unrolled(
; OFF: %e0 = icmp eq i64 %len, 0
; OFF: %e1 = icmp eq i64 %len, 1
; OFF: %e2 = icmp eq i64 %len, 2

; The b1 access is at base + 24, not base + 1 * 8: it is not recovered, and
; it is an unguarded access of the base in the region of the first check, so
; every check is kept (fail-safe coverage).
define void @mismatch(ptr addrspace(200) %s, i64 %len) {
entry:
  %e0 = icmp eq i64 %len, 0
  br i1 %e0, label %panic, label %b0
b0:
  %v0 = load i64, ptr addrspace(200) %s, align 8
  store i64 %v0, ptr @D, align 8
  %e1 = icmp eq i64 %len, 1
  br i1 %e1, label %panic, label %b1
b1:
  %p1 = getelementptr inbounds nuw i8, ptr addrspace(200) %s, i64 24
  %v1 = load i64, ptr addrspace(200) %p1, align 8
  store i64 %v1, ptr getelementptr (i8, ptr @D, i64 8), align 8
  ret void
panic:
  %k = phi i64 [ 0, %entry ], [ 1, %b0 ]
  call void @panic(i64 %k, i64 %len) [ "mem.check"(ptr addrspace(200) %s, i64 %len, i64 8, i64 8, i64 0) ]
  unreachable
}
; UB-LABEL: define void @mismatch(
; UB: %e0 = icmp eq i64 %len, 0
; UB: %e1 = icmp eq i64 %len, 1
; UB: void @panic(i64 %k
; STATS: uncovered=1 {{.*}}recovered=4 recovered_markers=4
