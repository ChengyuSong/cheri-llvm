; [LLM-generated] M5r R16: !{i64 A, i64 B} is two packed loans. An extended copy
; is !{!"mem.loan.ext", i64 orig, i64 disambiguator} inside that list. Inline,
; unroll, and vectorize keep those shapes. They do not swap them.
;
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -verify-each < %s | FileCheck %s --check-prefix=FLAT
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 -verify-each < %s | FileCheck %s --check-prefix=MIX
; RUN: opt -S -passes=loop-unroll -unroll-count=2 -verify-each < %s | FileCheck %s --check-prefix=UNROLL
; RUN: opt -S -passes=loop-vectorize -force-vector-width=4 -verify-each < %s | FileCheck %s --check-prefix=LV

target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare void @use(ptr, i32)

define internal void @callee_flat(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !0
  %v = load i32, ptr %cap, align 4, !mem.last_use !0
  ret void
}

; Both loans fit in the packed field. The list stays two i64s.
define void @inl_flat(ptr %slot, ptr %cap) {
; FLAT-LABEL: define void @inl_flat(
; FLAT: store ptr %cap, ptr %slot{{.*}}!mem.loan [[M:![0-9]+]]
; FLAT: load i32, ptr %cap{{.*}}!mem.last_use [[M]]
; FLAT-NOT: mem.loan.ext
; FLAT: ret void
;
  call void @callee_flat(ptr %slot, ptr %cap)
  ret void
}

define internal void @callee_mixed(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !1
  %v = load i32, ptr %cap, align 4, !mem.last_use !1
  ret void
}

; The caller already holds the only packed key for loan 3. Loan 3 becomes an
; extended operand. The extended loan 5 still has a free packed key, so it
; becomes one i64. The list is still two loans, not one pair (3, 5).
define void @inl_mixed(ptr %slot, ptr %cap, ptr %held, ptr %hcap) {
; MIX-LABEL: define void @inl_mixed(
; MIX: store ptr %hcap, ptr %held{{.*}}!mem.loan [[KEEP:![0-9]+]]
; MIX: store ptr %cap, ptr %slot{{.*}}!mem.loan [[MX:![0-9]+]]
; MIX: load i32, ptr %cap{{.*}}!mem.last_use [[MX]]
;
  store ptr %hcap, ptr %held, align 8, !mem.loan !2
  call void @callee_mixed(ptr %slot, ptr %cap)
  ret void
}

define void @unroll_flat(ptr noalias %p) {
; UNROLL-LABEL: define void @unroll_flat(
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use [[UF:![0-9]+]]
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use [[UF]]
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %v = load i32, ptr %p, align 4, !mem.last_use !3
  call void @use(ptr %p, i32 %v)
  %i1 = add nuw i64 %i, 1
  %c = icmp ult i64 %i1, 2
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

define void @unroll_mixed(ptr noalias %p) {
; UNROLL-LABEL: define void @unroll_mixed(
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use [[UM:![0-9]+]]
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use [[UM]]
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %v = load i32, ptr %p, align 4, !mem.last_use !4
  call void @use(ptr %p, i32 %v)
  %i1 = add nuw i64 %i, 1
  %c = icmp ult i64 %i1, 2
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

define void @lv_flat(ptr noalias %a, ptr noalias %b, i64 %n) {
; LV-LABEL: define void @lv_flat(
; LV: load <4 x i32>{{.*}}!mem.last_use [[LF:![0-9]+]]
; LV: load i32{{.*}}!mem.last_use [[LF]]
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !5
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

define void @lv_mixed(ptr noalias %a, ptr noalias %b, i64 %n) {
; LV-LABEL: define void @lv_mixed(
; LV: load <4 x i32>{{.*}}!mem.last_use [[LM:![0-9]+]]
; LV: load i32{{.*}}!mem.last_use [[LM]]
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !6
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
}

; FLAT: [[M]] = !{i64 4398046511107, i64 4398046511109}
; MIX: [[KEEP]] = !{i64 4398046511107}
; MIX: [[MX]] = !{[[MXE:![0-9]+]], i64 4398046511109}
; MIX: [[MXE]] = !{!"mem.loan.ext", i64 3, i64 1}
; UNROLL-DAG: [[UF]] = !{i64 7, i64 8}
; UNROLL-DAG: [[UM]] = !{i64 7, [[UME:![0-9]+]]}
; UNROLL-DAG: [[UME]] = !{!"mem.loan.ext", i64 8, i64 1}
; LV-DAG: [[LF]] = !{i64 11, i64 13}
; LV-DAG: [[LM]] = !{i64 11, [[LME:![0-9]+]]}
; LV-DAG: [[LME]] = !{!"mem.loan.ext", i64 13, i64 1}

!0 = !{i64 3, i64 5}
!1 = !{i64 3, !{!"mem.loan.ext", i64 5, i64 2}}
!2 = !{i64 4398046511107}
!3 = !{i64 7, i64 8}
!4 = !{i64 7, !{!"mem.loan.ext", i64 8, i64 1}}
!5 = !{i64 11, i64 13}
!6 = !{i64 11, !{!"mem.loan.ext", i64 13, i64 1}}
