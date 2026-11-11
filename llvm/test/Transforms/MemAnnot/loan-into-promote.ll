; [LLM-generated] M7.1b: promoting the owner slot drops the fact instead of
; leaving a dangling slot operand. The renamed marker is what the late pass
; counts. The loan value stays so the drop is visible.
;
; RUN: opt -S -passes=mem2reg < %s | FileCheck %s --check-prefix=M2R
; RUN: opt -S -passes=sroa < %s | FileCheck %s --check-prefix=SROA
; RUN: rm -f %t.ll %t.stats && opt -S -passes=mem2reg -o %t.ll < %s && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats %t.ll && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @llvm.mem.fact()

define void @promo(ptr addrspace(200) %loan, ptr addrspace(200) %buf) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  %v = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %v)
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 7) ]
  ret void
}
; M2R-LABEL: define void @promo(
; M2R-NOT: alloca
; M2R: call {{.*}}@llvm.mem.fact() [ "mem.loan_into.promoted"(ptr addrspace(200) poison, ptr addrspace(200) %loan, i64 7) ]
; M2R-NOT: "mem.loan_into"(
; SROA-LABEL: define void @promo(
; SROA-NOT: alloca
; SROA: call {{.*}}@llvm.mem.fact() [ "mem.loan_into.promoted"(ptr addrspace(200) poison, ptr addrspace(200) %loan, i64 7) ]
; SROA-NOT: "mem.loan_into"(

; STATS: loan_into_facts=0
; STATS-SAME: loan_into_scans=0
; STATS-SAME: loan_into_skipped_promoted=1
