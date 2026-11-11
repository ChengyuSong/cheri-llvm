; [LLM-generated] M7.1b. A loan stored into a heap container is a caller-side fact:
;   call void @llvm.mem.fact() [ "mem.loan_into"(ptr %owner_ptr_field, ptr %loan, i64 id) ]
; At a last use of that id the late pass re-reads the field and, when the
; buffer is still live, scans [base, base+length) in 16-byte steps. A slot is
; nulled only when its capability is exactly the loan. The scan is a loop in
; the function. No fact, a freed buffer, a moved-from field, a dead slot, or
; a missing loan value produces no scan.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=scope+free < %s | FileCheck %s --check-prefix=NONE
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()
declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))

define void @basic(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 1) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; The fact is stripped. The scan re-reads %s after the last use, starts at
; the buffer's base, and nulls only an exact match.
; CHECK-LABEL: define void @basic(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK: @llvm.cheri.cap.tag.get
; CHECK: @llvm.cheri.cap.base.get
; CHECK: @llvm.cheri.cap.address.set
; CHECK: @llvm.cheri.cap.length.get
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: br i1
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void

; Grow freed the old buffer and stored a new one. The scan loads %s again
; after that store. It must not keep using the freed pointer.
define void @grow(ptr addrspace(200) %oldbuf, ptr addrspace(200) %newbuf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %oldbuf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 2) ]
  %old = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @free(ptr addrspace(200) %old) [ "mem.free"(ptr addrspace(200) %old) ]
  store ptr addrspace(200) %newbuf, ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %loan), !mem.last_use !2
  ret void
}
; CHECK-LABEL: define void @grow(
; CHECK: call {{.*}}@free(ptr addrspace(200) %old)
; CHECK: store ptr addrspace(200) %newbuf, ptr addrspace(200) %s, align 16
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void

; A different capability in the next 16-byte slot is not stored. The null is
; the true edge of an exact compare, and the index advances by 16.
define void @equal(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 3) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !3
  ret void
}
; CHECK-LABEL: define void @equal(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: phi i64 [ 0, {{%.*}} ], [ {{%.*}}, {{%.*}} ]
; CHECK: icmp ult i64
; CHECK: shl i64 {{%.*}}, 4
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: br i1 {{%.*}}, label %[[NULL:loaninto\.null[0-9]*]], label %[[NEXT:loaninto\.next[0-9]*]]
; CHECK: [[NULL]]:
; CHECK: store volatile ptr addrspace(200) null
; CHECK: br label %[[NEXT]]
; CHECK: ret void

define void @skip_free(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 1) ]
  %p = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @skip_free(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @skip_life(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 1) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @skip_life(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @skip_moved(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 5) ]
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !5
  ret void
}
; CHECK-LABEL: define void @skip_moved(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

; The move kills the first fact. The second fact is after the move, so the
; loan is in the container again and the scan runs.
define void @reestablish(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 4) ]
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 4) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !4
  ret void
}
; CHECK-LABEL: define void @reestablish(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void

define void @no_fact(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @no_fact(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @noval(ptr addrspace(200) %buf) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) poison, i64 1) ]
  call void @use(ptr addrspace(200) poison), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @noval(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void

define void @none_end() {
  ret void
}

; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: define void @none_end(

; STATS: loan_into_facts=9
; STATS-SAME: loan_into_scans=4
; STATS-SAME: loan_into_nulls=4
; STATS-SAME: loan_into_skipped_freed=1
; STATS-SAME: loan_into_skipped_moved=2
; STATS-SAME: loan_into_skipped_promoted=0
; STATS-SAME: loan_into_skipped_noval=1

!1 = !{i64 1}
!2 = !{i64 2}
!3 = !{i64 3}
!4 = !{i64 4}
!5 = !{i64 5}
