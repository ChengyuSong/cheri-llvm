; [LLM-generated] M5r R7 (D52): the loan of slot %b ends at the store of the
; call result into the return slot %ret. SROA promotes %ret and erases that
; store; the loan id moves to the previous carrier (the call), so the loan
; clear of %b (D36) still has a carrier. The OLD prefix is the R6 behaviour.
; RUN: opt -S -passes='function(sroa),cheri-bounds-lowering' -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes='function(sroa),cheri-bounds-lowering' -cheri-invalidate=loan -mem-last-use-transfer-alloca=false < %s | FileCheck %s --check-prefix=OLD
; RUN: opt -disable-output -mem-annot-census -passes='mem-annot-census-start,function(sroa),cheri-bounds-lowering' < %s 2>&1 | FileCheck %s --check-prefix=CENSUS
; RUN: opt -disable-output -mem-annot-census -mem-last-use-transfer-alloca=false -passes='mem-annot-census-start,function(sroa),cheri-bounds-lowering' < %s 2>&1 | FileCheck %s --check-prefix=CENSUS-OLD
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare i1 @write(ptr addrspace(200))

define i8 @fmt(ptr addrspace(200) %self) {
  %ret = alloca i8, align 1, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  %p = getelementptr inbounds i8, ptr addrspace(200) %self, i64 1
  store ptr addrspace(200) %p, ptr addrspace(200) %b, align 16, !mem.loan !0
  %r = call i1 @write(ptr addrspace(200) %b)
  %z = zext i1 %r to i8
  store i8 %z, ptr addrspace(200) %ret, align 1, !mem.last_use !1
  %v = load i8, ptr addrspace(200) %ret, align 1
  ret i8 %v
}
; CHECK-LABEL: define i8 @fmt(
; CHECK: call addrspace(200) i1 @write(ptr addrspace(200) %b)
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %b, align 16, !pcsections
; OLD-LABEL: define i8 @fmt(
; OLD-NOT: store volatile ptr addrspace(200) null
; OLD: ret i8

; CENSUS: slot-loans: live=1 with_carrier=1 lost(promoted=0,carrier-deleted=0,md-dropped=0,none-at-start=0)
; CENSUS-OLD: last_use-live: start=0 late=0 promoted=2
; CENSUS-OLD: slot-loans: live=1 with_carrier=0 lost(promoted=1,

!0 = !{i64 5}
!1 = !{i64 9, i64 5}
