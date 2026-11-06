; [LLM-generated] M5r R16: the census key of a loan is the low 42 bits.
; A packed id and an extended copy !{i64 orig, i64 disambiguator} of that
; orig are one key. A different orig is another key. The full id, not this
; key, is what a last-use clears.
;
; RUN: opt -mem-annot-census -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s

; CHECK: start: {{.*}} last_use=2
; CHECK: late: {{.*}} last_use=2

define void @f(ptr %p) {
  %a = load i32, ptr %p, align 4, !mem.last_use !0
  %b = load i32, ptr %p, align 4, !mem.last_use !1
  %c = load i32, ptr %p, align 4, !mem.last_use !2
  ret void
}

!0 = !{i64 3}
!1 = !{!{i64 3, i64 9}}
!2 = !{!{i64 4, i64 9}}
