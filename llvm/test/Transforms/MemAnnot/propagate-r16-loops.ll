; [LLM-generated] M5r R16: last-use across the loop pipeline. A marker stays, and
; it is not placed before a slot reload that still executes first. verify-each
; runs the verifier after every pass of O1, O2, O3 and the loop passes.
; These runs are the cases below, not a proof that every loop transform is
; covered.
;
; RUN: opt -S -passes='default<O1>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -S -passes='default<O2>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -S -passes='default<O3>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -S -passes=loop-unroll -unroll-count=2 -verify-each < %s | FileCheck %s --check-prefix=UNROLL
; RUN: opt -S -passes=loop-vectorize -force-vector-width=4 -verify-each < %s | FileCheck %s --check-prefix=LV
; RUN: opt -S -passes='loop-mssa(licm)' -verify-each < %s | FileCheck %s --check-prefix=LICM

target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare void @use(ptr, i32)
declare void @llvm.mem.fact()

; The slot is reloaded, then the marked load. O1/O2/O3 may widen or unroll
; the indexed load. The marker stays after a reload of this slot.
define void @pipe_keep(ptr noalias %slot, ptr noalias %a, ptr noalias %b, i64 %n) {
; PIPE-LABEL: define {{.*}}@pipe_keep(
; PIPE: load ptr, ptr %slot
; PIPE-NOT: !mem.last_use
; PIPE: mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %cap = load ptr, ptr %slot, align 8
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !0
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  call void @use(ptr %cap, i32 %w)
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

; The indexed load is dead. The loan still ends in the loop, so the pipeline
; keeps an anchor instead of deleting the fact.
define i32 @pipe_anchor(ptr %p) {
; PIPE-LABEL: define {{.*}}@pipe_anchor(
; PIPE: mem.last_use
; PIPE: ret i32 1
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, 4
  br i1 %c, label %loop, label %exit
exit:
  ret i32 1
}

; Full unroll keeps both copies. Neither marker precedes that copy's reload.
define void @unroll_keep(ptr noalias %slot, ptr noalias %p) {
; UNROLL-LABEL: define void @unroll_keep(
; UNROLL: load ptr, ptr %slot
; UNROLL-NOT: !mem.last_use
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use
; UNROLL: load ptr, ptr %slot
; UNROLL-NOT: !mem.last_use
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %cap = load ptr, ptr %slot, align 8
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  call void @use(ptr %cap, i32 %v)
  %i1 = add nuw i64 %i, 1
  %c = icmp ult i64 %i1, 2
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

; The call blocks widening. The marker stays after the slot reload.
define void @lv_after_slot(ptr noalias %a, ptr noalias %b, ptr noalias %slot, i64 %n) {
; LV-LABEL: define void @lv_after_slot(
; LV: load ptr, ptr %slot
; LV-NOT: !mem.last_use
; LV: mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %cap = load ptr, ptr %slot, align 8
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !0
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  call void @use(ptr %cap, i32 %w)
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

; LICM hoists the invariant load of %p. The marker must not go with it.
; The slot reload stays in the loop (the call may write the slot) and the
; marker stays on that call, after the reload.
define void @licm_not_before_reload(ptr noalias dereferenceable(4) %p, ptr %slot) {
; LICM-LABEL: define void @licm_not_before_reload(
; LICM: load i32, ptr %p, align 4
; LICM-NOT: !mem.last_use
; LICM: load ptr, ptr %slot
; LICM-NOT: !mem.last_use
; LICM: call void @use(ptr %c, i32 %v), !mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %c = load ptr, ptr %slot, align 8
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  call void @use(ptr %c, i32 %v)
  %i1 = add nuw i64 %i, 1
  %cond = icmp ult i64 %i1, 4
  br i1 %cond, label %loop, label %exit
exit:
  ret void
}

; No call in the loop, so it can widen. The vector body and the scalar
; remainder both keep the marker.
define void @lv_wide(ptr noalias %a, ptr noalias %b, i64 %n) {
; LV-LABEL: define void @lv_wide(
; LV: load <4 x i32>{{.*}}!mem.last_use
; LV: load i32{{.*}}!mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !0
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

; Two loads with different loan ids. Each widened load keeps its own id.
define void @lv_two_ids(ptr noalias %a, ptr noalias %b, i64 %n) {
; LV-LABEL: define void @lv_two_ids(
; LV: load <4 x i32>{{.*}}!mem.last_use [[A:![0-9]+]]
; LV: load <4 x i32>{{.*}}!mem.last_use [[A]]
; LV: load <4 x i32>{{.*}}!mem.last_use [[B:![0-9]+]]
; LV: load <4 x i32>{{.*}}!mem.last_use [[B]]
; LV: load i32{{.*}}!mem.last_use [[A]]
; LV: load i32{{.*}}!mem.last_use [[B]]
; LV-DAG: [[A]] = !{i64 7}
; LV-DAG: [[B]] = !{i64 8}
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !0
  %u = load i32, ptr %pb, align 4, !mem.last_use !1
  %w = add i32 %v, %u
  store i32 %w, ptr %pa, align 4
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

!0 = !{i64 7}
!1 = !{i64 8}
