; LLM-generated: on a target without capabilities (address space 0, e.g. a
; Fil-C-style or plain build) __mem_checked_narrow lowers to the identity.
; RUN: opt -S -passes='function(mem-annotate-c)' < %s | FileCheck %s
declare ptr @__mem_checked_narrow(ptr, i64)
; CHECK-LABEL: define i64 @get(
; CHECK-NOT: __mem_checked_narrow
; CHECK-NOT: bounds.set
; CHECK: getelementptr inbounds i64, ptr %a, i64 %i
define i64 @get(ptr %a, i64 %n, i64 %i) {
  %nb = call ptr @__mem_checked_narrow(ptr %a, i64 %n)
  %g = getelementptr inbounds i64, ptr %nb, i64 %i
  %v = load i64, ptr %g
  ret i64 %v
}
