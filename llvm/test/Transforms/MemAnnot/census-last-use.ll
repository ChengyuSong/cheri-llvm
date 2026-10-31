; [LLM-generated] M5r R3 (D18): last_use loss reasons in the late census.
; A carrier that accessed a promoted alloca counts as fail-safe:promoted.
; RUN: opt -mem-annot-census -disable-output \
; RUN:   -passes='mem-annot-census-start,sroa,mem-annot-census-late' < %s 2>&1 | FileCheck %s

define i64 @promoted(ptr %p) {
  %t = alloca i64, align 8
  %v = load i64, ptr %p, align 8
  store i64 %v, ptr %t, align 8, !mem.last_use !0
  %w = load i64, ptr %t, align 8
  ret i64 %w
}

define i64 @kept(ptr %p) {
  %v = load i64, ptr %p, align 8, !mem.last_use !1
  ret i64 %v
}

!0 = !{i64 11}
!1 = !{i64 12}

; CHECK: start: {{.*}} last_use=2
; CHECK: late: {{.*}} last_use=1
; CHECK: lost: {{.*}}last_use=1(fail-safe:promoted=1,carrier-deleted=0,md-dropped=0)
