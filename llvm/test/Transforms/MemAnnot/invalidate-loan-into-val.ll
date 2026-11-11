; [LLM-generated] M7.1b. After the owner slot is promoted, the fact is
;   call void @llvm.mem.fact() [ "mem.loan_into.val"(ptr %buf, ptr %loan, i64 id) ]
; The scan uses %buf itself: tag and non-null, address set to base, then
; length>>4 steps of cap.equal.exact. A mem.free of %buf (or a pointer derived
; from it) before the last use skips the scan. A call that takes %buf and
; returns a new pointer is a grow/realloc; that pointer is not provably the
; same allocation, so the scan is skipped. The slot form is unchanged.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare ptr addrspace(200) @realloc(ptr addrspace(200), i64)
declare void @llvm.mem.fact()

define void @val_scan(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  call void @llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i64 1) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @val_scan(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: @llvm.cheri.cap.tag.get(ptr addrspace(200) %buf)
; CHECK: @llvm.cheri.cap.base.get
; CHECK: @llvm.cheri.cap.address.set
; CHECK: @llvm.cheri.cap.length.get
; CHECK: @llvm.cheri.cap.equal.exact(ptr addrspace(200) {{%.*}}, ptr addrspace(200) %loan)
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void

define void @val_free(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  call void @llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i64 1) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @val_free(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @val_free_derived(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  call void @llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i64 2) ]
  %q = getelementptr inbounds i8, ptr addrspace(200) %buf, i64 16
  call void @free(ptr addrspace(200) %q) [ "mem.free"(ptr addrspace(200) %q) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !2
  ret void
}
; CHECK-LABEL: define void @val_free_derived(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @val_reassign(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  call void @llvm.mem.fact() [ "mem.loan_into.val"(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i64 3) ]
  %new = call ptr addrspace(200) @realloc(ptr addrspace(200) %buf, i64 128)
  call void @use(ptr addrspace(200) %new)
  call void @use(ptr addrspace(200) %loan), !mem.last_use !3
  ret void
}
; CHECK-LABEL: define void @val_reassign(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

; STATS: loan_into_facts=0
; STATS-SAME: loan_into_scans=1
; STATS-SAME: loan_into_nulls=1
; STATS-SAME: loan_into_val_facts=4
; STATS-SAME: loan_into_skipped_val_freed=2
; STATS-SAME: loan_into_skipped_val_reassigned=1

!1 = !{i64 1}
!2 = !{i64 2}
!3 = !{i64 3}
