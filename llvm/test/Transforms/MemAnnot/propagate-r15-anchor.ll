; [LLM-generated] M5r R15 follow-up. A last-use that cannot move onto a later
; carrier becomes llvm.mem.fact ["mem.last_use"(i64, ...)]. That call is an
; architecture-neutral program point, not a CHERI clear. A widened memory op
; takes a lane's ids only when the widened op is after that lane. A rekey that
; would alias another loan drops the copy instead of clearing the wrong slot.
;
; RUN: opt -S -passes=dce < %s | FileCheck %s --check-prefix=DCE
; RUN: opt -S -passes='default<O2>' < %s | FileCheck %s --check-prefix=O2
; RUN: opt -S -passes='loop-mssa(licm)' < %s | FileCheck %s --check-prefix=LICM
; RUN: opt -S -passes=slp-vectorizer < %s | FileCheck %s --check-prefix=SLP
; RUN: opt -S -passes=loop-vectorize -force-vector-width=4 < %s | FileCheck %s --check-prefix=LV
; RUN: opt -S -passes=inline -mem-inline-loan-salt=5 < %s | FileCheck %s --check-prefix=ZERO
; RUN: opt -S -passes=inline -mem-inline-loan-salt=7 < %s | FileCheck %s --check-prefix=COLLIDE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s --check-prefix=INV

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
target triple = "x86_64-unknown-linux-gnu"

declare void @llvm.mem.fact()
declare void @use(i32)

; The load is dead. Its value is not the invalidation. The loan still ends
; at this point, so DCE and O2 keep an anchor instead of deleting the fact.
define i32 @dead_load(ptr %p) {
; DCE-LABEL: define i32 @dead_load(
; DCE-NEXT: call addrspace(200) void @llvm.mem.fact() [ "mem.last_use"(i64 7) ]
; DCE-NEXT: ret i32 1
; O2-LABEL: define {{.*}}@dead_load(
; O2: call addrspace(200) void @llvm.mem.fact() [ "mem.last_use"(i64 7) ]
; O2: ret i32 1
;
  %a = load i32, ptr %p, align 4, !mem.last_use !0
  ret i32 1
}

; The load is live-out, so LICM sinks it to the exit. The marker stays on
; that sunk load (later than the loop), not on an instruction before the loop.
define i32 @licm_anchor(ptr noalias dereferenceable(4) %p) {
; LICM-LABEL: define i32 @licm_anchor(
; LICM: br label %loop
; LICM: br i1 {{.*}}, label %loop, label %exit
; LICM: load i32, ptr %p, align 4, !mem.last_use
; LICM-NEXT: add i32
; LICM-NEXT: ret i32
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  %s = add i32 %v, 1
  %i1 = add nuw i64 %i, 1
  %c = icmp ult i64 %i1, 4
  br i1 %c, label %loop, label %exit
exit:
  %r = phi i32 [ %s, %loop ]
  ret i32 %r
}

; The widened load is after one lane and before the other. The later lane
; keeps an anchor so its id is not cleared at the earlier widened load.
; Both loan ids remain.
define void @slp_mixed(ptr %a, ptr %b) {
; SLP-LABEL: define void @slp_mixed(
; SLP: load <2 x i32>{{.*}}!mem.last_use [[ONE:![0-9]+]]
; SLP: [ "mem.last_use"(i64 [[OTHER:[0-9]+]]) ]
; SLP: [[ONE]] = !{i64 [[LANE:[0-9]+]]}
;
  %a1 = getelementptr inbounds i32, ptr %a, i64 1
  %b1 = getelementptr inbounds i32, ptr %b, i64 1
  %x0 = load i32, ptr %a, align 4, !mem.last_use !0
  %x1 = load i32, ptr %a1, align 4, !mem.last_use !1
  %y0 = add i32 %x0, 7
  %y1 = add i32 %x1, 7
  store i32 %y0, ptr %b, align 4
  store i32 %y1, ptr %b1, align 4
  ret void
}

; The vector body executes instead of the scalar body when the trip count is
; a multiple of the width. The widened load keeps the marker; the scalar
; remainder keeps it too.
define void @lv_last(ptr noalias %a, ptr noalias %b, i64 %n) {
; LV-LABEL: define void @lv_last(
; LV: load <4 x i32>, {{.*}}!mem.last_use
; LV: load i32, {{.*}}!mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %pa = getelementptr inbounds i32, ptr %a, i64 %i
  %pb = getelementptr inbounds i32, ptr %b, i64 %i
  %v = load i32, ptr %pa, align 4, !mem.last_use !0
  %w = add i32 %v, 1
  store i32 %w, ptr %pb, align 4
  %i1 = add i64 %i, 1
  %cnd = icmp ult i64 %i1, %n
  br i1 %cnd, label %loop, label %exit
exit:
  ret void
}

; Salt 5, applied twice (inner into mid, mid into @zero). The second mix
; xors the high bits with themselves and would be 0, which aliases rustc's
; unrekeyed ids. That copy is dropped. This is an unsound id, not a missed
; clear of a distinct loan.
define internal void @inner_zero(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !2
  %v = load i32, ptr %cap, align 4, !mem.last_use !2
  ret void
}

define internal void @mid_zero(ptr %slot, ptr %cap) alwaysinline {
  call void @inner_zero(ptr %slot, ptr %cap)
  ret void
}

define void @zero(ptr %slot, ptr %cap) {
; ZERO-LABEL: define void @zero(
; ZERO-NOT: !mem.loan
; ZERO-NOT: !mem.last_use
; ZERO: ret void
;
  call void @mid_zero(ptr %slot, ptr %cap)
  ret void
}

; 3 | (7 << 42). Salt 7 rekeys a fresh loan 3 onto this id. The caller's loan
; already uses it, so the inlined copy is dropped and the caller's id remains.
define internal void @inner_hit(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !2
  %v = load i32, ptr %cap, align 4, !mem.last_use !2
  ret void
}

define void @collide(ptr %slot, ptr %cap, ptr %other, ptr %ocap) {
; COLLIDE-LABEL: define void @collide(
; COLLIDE: store ptr %cap, ptr %slot{{.*}}!mem.loan [[KEEP:![0-9]+]]
; COLLIDE-NOT: !mem.loan
; COLLIDE: ret void
; COLLIDE: [[KEEP]] = !{i64 30786325577731}
;
  store ptr %cap, ptr %slot, align 8, !mem.loan !3
  call void @inner_hit(ptr %other, ptr %ocap)
  ret void
}

; The anchor is the last-use carrier. Loan mode nulls the slot after it.
define void @inv_anchor(ptr addrspace(200) %p) addrspace(200) {
; INV-LABEL: define void @inv_anchor(
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %r, align 16, !pcsections
;
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !4
  call void @llvm.mem.fact() [ "mem.last_use"(i64 5) ]
  ret void
}

!0 = !{i64 7}
!1 = !{i64 8}
!2 = !{i64 3}
!3 = !{i64 30786325577731}
!4 = !{i64 5}
