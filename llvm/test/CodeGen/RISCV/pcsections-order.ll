; [LLM-generated] PC sections of a function are emitted in the order their
; metadata is first used, not in MDNode pointer order, so the object's section
; order does not change from one run to the next.
; RUN: llc -mtriple=riscv64 < %s | FileCheck %s

@a = global i64 0

define void @f() {
; CHECK-LABEL: f:
; CHECK:       .section sec_c,"awo",@progbits,.text
; CHECK-NEXT:  .Lpcsection_base0:
; CHECK-NEXT:  .word .Lpcsection0-.Lpcsection_base0
; CHECK-NEXT:  .Lpcsection_base1:
; CHECK-NEXT:  .word .Lpcsection3-.Lpcsection_base1
; CHECK-NEXT:  .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  .Lpcsection_base2:
; CHECK-NEXT:  .word .Lpcsection1-.Lpcsection_base2
; CHECK-NEXT:  .section sec_b,"awo",@progbits,.text
; CHECK-NEXT:  .Lpcsection_base3:
; CHECK-NEXT:  .word .Lpcsection2-.Lpcsection_base3
  store volatile i64 1, ptr @a, !pcsections !0
  store volatile i64 2, ptr @a, !pcsections !1
  store volatile i64 3, ptr @a, !pcsections !2
  store volatile i64 4, ptr @a, !pcsections !0
  ret void
}

!0 = !{!"sec_c"}
!1 = !{!"sec_a"}
!2 = !{!"sec_b"}
