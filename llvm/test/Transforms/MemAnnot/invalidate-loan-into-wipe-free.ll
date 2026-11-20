; [LLM-generated] M7.2c lb register gaps, fix 1. rustc's
; mem.wipe_cap_words(P, len) nulls every capability word of buffer P right
; before its final dealloc. A mem.loan_into scan of that buffer anchored after
; the wipe is subsumed; with an out-of-line dealloc (no mem.free bundle here)
; it would also run through the stale buffer cap after the block may have
; been reused. Lowered wipe: the scan is dropped. Wipe lowering off: the scan
; runs at the wipe, before the dealloc. -cheri-invalidate-loan-into-wipe-free=false
; restores the previous placement.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-loan-into-wipe-free=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false < %s | FileCheck %s --check-prefix=NOWIPE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false -cheri-invalidate-loan-into-wipe-free=false < %s | FileCheck %s --check-prefix=NOWIPEOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-nw && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false -cheri-invalidate-stats-out=%t.stats-nw < %s && FileCheck %s --check-prefix=STATS-NOWIPE < %t.stats-nw
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-loan-into-wipe-free=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @dealloc(ptr addrspace(200))
declare void @claim(ptr addrspace(200))
declare void @llvm.mem.fact()
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)

; lb1 at O1: the owner is moved into a drop slot, the buffer cap is reloaded
; from it, wiped, then freed by an out-of-line dealloc; the loan's last use is
; carried by the next call (which may reuse the block).
define void @moved_wipe_dealloc(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %v = alloca ptr addrspace(200), align 16, addrspace(200)
  %d = alloca ptr addrspace(200), align 16, addrspace(200)
  %c = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %v, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %v, ptr addrspace(200) %loan, i64 1) ]
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %d, ptr addrspace(200) %v, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  %b = load ptr addrspace(200), ptr addrspace(200) %d, align 16
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %b, i64 32) ]
  call void @dealloc(ptr addrspace(200) %d)
  call void @claim(ptr addrspace(200) %c), !mem.last_use !1
  ret void
}
; CHECK-LABEL: define void @moved_wipe_dealloc(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: store ptr addrspace(200) null, ptr addrspace(200) %b
; CHECK: call {{.*}}@dealloc(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@claim(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void
; OFF-LABEL: define void @moved_wipe_dealloc(
; OFF: call {{.*}}@dealloc(
; OFF: call {{.*}}@claim(
; OFF: @llvm.cheri.cap.equal.exact
; OFF: ret void
; NOWIPE-LABEL: define void @moved_wipe_dealloc(
; NOWIPE-NOT: "mem.wipe_cap_words"
; NOWIPE: @llvm.cheri.cap.tag.get(ptr addrspace(200) %b)
; NOWIPE: @llvm.cheri.cap.equal.exact
; NOWIPE: call {{.*}}@dealloc(
; NOWIPE: call {{.*}}@claim(
; NOWIPE-NOT: @llvm.cheri.cap.equal.exact
; NOWIPE: ret void
; NOWIPEOFF-LABEL: define void @moved_wipe_dealloc(
; NOWIPEOFF: call {{.*}}@dealloc(
; NOWIPEOFF: call {{.*}}@claim(
; NOWIPEOFF: @llvm.cheri.cap.equal.exact
; NOWIPEOFF: ret void

; No move: the owner slot itself is wiped and passed to an out-of-line dealloc.
define void @slot_wipe_dealloc(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 2) ]
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %b, i64 32) ]
  call void @dealloc(ptr addrspace(200) %s)
  call void @use(ptr addrspace(200) %loan), !mem.last_use !2
  ret void
}
; CHECK-LABEL: define void @slot_wipe_dealloc(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: ret void
; OFF-LABEL: define void @slot_wipe_dealloc(
; OFF: call {{.*}}@dealloc(
; OFF: @llvm.cheri.cap.equal.exact
; OFF: ret void
; NOWIPE-LABEL: define void @slot_wipe_dealloc(
; NOWIPE: @llvm.cheri.cap.equal.exact
; NOWIPE: call {{.*}}@dealloc(
; NOWIPE-NOT: @llvm.cheri.cap.equal.exact
; NOWIPE: ret void

; A store of a new buffer after the wipe: the scan must stay (the slot no
; longer holds the wiped buffer at the last use).
define void @slot_wipe_reinit(ptr addrspace(200) %buf, ptr addrspace(200) %buf2, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 3) ]
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %b, i64 32) ]
  store ptr addrspace(200) %buf2, ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %loan), !mem.last_use !3
  ret void
}
; CHECK-LABEL: define void @slot_wipe_reinit(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: ret void

; The wipe is on one branch only: it does not cover every path, keep the scan.
define void @wipe_one_branch(ptr addrspace(200) %buf, ptr addrspace(200) %loan, i1 %c) {
entry:
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 4) ]
  br i1 %c, label %w, label %j
w:
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %b, i64 32) ]
  br label %j
j:
  call void @use(ptr addrspace(200) %loan), !mem.last_use !4
  ret void
}
; CHECK-LABEL: define void @wipe_one_branch(
; CHECK: call {{.*}}@use(ptr addrspace(200) %loan)
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: ret void

; STATS: loan_into_skipped_wiped=2 loan_into_wipe_anchored=0
; STATS-NOWIPE: loan_into_skipped_wiped=0 loan_into_wipe_anchored=2
; STATS-OFF: loan_into_skipped_wiped=0 loan_into_wipe_anchored=0

!1 = !{i64 1}
!2 = !{i64 2}
!3 = !{i64 3}
!4 = !{i64 4}
