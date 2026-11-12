; [LLM-generated] M7.1b. A loan stored into a heap container is a caller-side fact:
;   call void @llvm.mem.fact() [ "mem.loan_into"(ptr %owner_ptr_field, ptr %loan, i64 id) ]
; At a last use of that id the late pass re-reads the field and, when the
; buffer is still live, scans [base, base+length) in 16-byte steps. A slot is
; nulled only when its capability is exactly the loan. The scan is a loop in
; the function. No fact, a freed buffer, a dead slot, or a missing loan value
; produces no scan. M7.1d A: a mem.move of the owner no longer suppresses the
; scan when the buffer is still live; -cheri-invalidate-loan-into-moved-live=false
; restores the old skip.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=scope+free < %s | FileCheck %s --check-prefix=NONE
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-loan-into-moved-live=false < %s | FileCheck %s --check-prefix=MOVEDOFF
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-loan-into-moved-live=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
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
; The move-null of %s leaves the buffer itself live. M7.1d A scans it via the
; still-named buffer capability (%buf). The off switch keeps the old skip.
; CHECK-LABEL: define void @skip_moved(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void
; MOVEDOFF-LABEL: define void @skip_moved(
; MOVEDOFF-NOT: @llvm.cheri.cap.equal.exact
; MOVEDOFF: ret void

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
; MOVEDOFF-LABEL: define void @reestablish(
; MOVEDOFF: call {{.*}}@use(ptr addrspace(200) %loan)
; MOVEDOFF: @llvm.cheri.cap.equal.exact
; MOVEDOFF: store volatile ptr addrspace(200) null
; MOVEDOFF: ret void

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


; memcpy the owner to a dest, then mem.move the source. The dest still holds
; the buffer at last use, so the scan re-reads that carrier.
define void @moved_live_copy(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  %d = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 6) ]
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %d, ptr addrspace(200) %s, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !6
  ret void
}
; CHECK-LABEL: define void @moved_live_copy(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: load ptr addrspace(200), ptr addrspace(200) %d, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void
; MOVEDOFF-LABEL: define void @moved_live_copy(
; MOVEDOFF-NOT: @llvm.cheri.cap.equal.exact
; MOVEDOFF: ret void

; The dest is forgotten before last use. The scan uses the buffer cap loaded
; from the dest while it was still named.
define void @moved_live_forget(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  %d = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %d)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 7) ]
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %d, ptr addrspace(200) %s, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  %p = load ptr addrspace(200), ptr addrspace(200) %d, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %d) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %d)
  call void @use(ptr addrspace(200) %loan), !mem.last_use !7
  ret void
}
; CHECK-LABEL: define void @moved_live_forget(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null
; CHECK: ret void
; MOVEDOFF-LABEL: define void @moved_live_forget(
; MOVEDOFF-NOT: @llvm.cheri.cap.equal.exact
; MOVEDOFF: ret void


; mem.move then mem.free of the buffer. The leftover is in a freed object
; (the as_ptr-then-drop shape). M7.1d A must still skip; that is slice B.
define void @moved_then_freed(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 8) ]
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !8
  ret void
}
; CHECK-LABEL: define void @moved_then_freed(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void
; MOVEDOFF-LABEL: define void @moved_then_freed(
; MOVEDOFF-NOT: @llvm.cheri.cap.equal.exact
; MOVEDOFF: ret void

declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)

define void @none_end() {
  ret void
}

; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: define void @none_end(

; STATS: loan_into_facts=12
; STATS-SAME: loan_into_scans=7
; STATS-SAME: loan_into_nulls=7
; STATS-SAME: loan_into_skipped_freed=2
; STATS-SAME: loan_into_skipped_moved=1
; STATS-SAME: loan_into_moved_live=3
; STATS-SAME: loan_into_skipped_promoted=0
; STATS-SAME: loan_into_skipped_noval=1

; STATS-OFF: loan_into_facts=12
; STATS-OFF-SAME: loan_into_scans=4
; STATS-OFF-SAME: loan_into_nulls=4
; STATS-OFF-SAME: loan_into_skipped_freed=1
; STATS-OFF-SAME: loan_into_skipped_moved=5
; STATS-OFF-SAME: loan_into_moved_live=0
; STATS-OFF-SAME: loan_into_skipped_promoted=0
; STATS-OFF-SAME: loan_into_skipped_noval=1

!1 = !{i64 1}
!2 = !{i64 2}
!3 = !{i64 3}
!4 = !{i64 4}
!5 = !{i64 5}
!6 = !{i64 6}
!7 = !{i64 7}
!8 = !{i64 8}
