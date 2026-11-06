; [LLM-generated] M5r R16: the census key of a loan is the low 42 bits.
; A packed id and an extended copy !{!"mem.loan.ext", i64 orig, i64 disambiguator}
; of that orig are one key. A different orig is another key. A bare
; !{i64, i64} is two packed loans, not one extended copy. The full id, not
; this key, is what a last-use clears.
;
; RUN: opt -mem-annot-census -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s

; CHECK: start: {{.*}} last_use=3
; CHECK: late: {{.*}} last_use=3

define void @f(ptr %p) {
  %a = load i32, ptr %p, align 4, !mem.last_use !0
  %b = load i32, ptr %p, align 4, !mem.last_use !1
  %c = load i32, ptr %p, align 4, !mem.last_use !2
  ; !{i64 3, i64 8} is two packed loans. 8 is a new key. It is not a
  ; disambiguator of 3, and 9 above is not a key of its own.
  %d = load i32, ptr %p, align 4, !mem.last_use !3
  ret void
}

!0 = !{i64 3}
!1 = !{!{!"mem.loan.ext", i64 3, i64 9}}
!2 = !{!{!"mem.loan.ext", i64 4, i64 9}}
!3 = !{i64 3, i64 8}
