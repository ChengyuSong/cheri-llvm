; [LLM-generated] M7.1a. Consume the fact rustc emits (cheri-rust PR 9):
;   call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %slot) ]
; %slot is the moved-from alloca, or that alloca plus a constant field offset.
; Box: the fact is the next instruction after the load, before the call that
; receives the register. The slot is nulled there; the register clear is after
; the call, which still uses the loaded owner.
; Vec: the slot is the call argument. The fact (and the null) are the next
; instruction after the call.
; An escaped slot is still nulled. A re-init after the fact keeps the new
; value. No fact, a same-block re-init before the fact, a non-alloca, a
; variable or misaligned address, and a slot whose lifetime already ended
; are left alone. The clear follows the loan mode switch.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=scope+free < %s | FileCheck %s --check-prefix=SF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-cap-reg=false < %s | FileCheck %s --check-prefix=NOCAP
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @eat_box(ptr addrspace(200))
declare void @eat_vec(ptr addrspace(200))
declare void @touch_box(ptr addrspace(200))
declare void @g()
declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @llvm.mem.fact()

; Box. Address-taken local, then load, fact, call. The call still receives
; the loaded owner. The null is between the fact and that call.
define void @basic(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @touch_box(ptr addrspace(200) %s)
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; The late pass strips the fact after consuming it. The null replaces that
; program point: after the load, before eat_box. The register clear follows
; the call that still uses the loaded owner.
; CHECK-LABEL: define void @basic(
; CHECK: call {{.*}}@touch_box(ptr addrspace(200) %s)
; CHECK: %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16, !pcsections [[PMV:![0-9]+]]
; CHECK-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %b, i32 0)
; NONE-LABEL: define void @basic(
; NONE-NOT: store {{(volatile )?}}ptr addrspace(200) null
; NONE: ret void
; SF-LABEL: define void @basic(
; SF-NOT: store {{(volatile )?}}ptr addrspace(200) null
; SF: ret void
; NOCAP-LABEL: define void @basic(
; NOCAP: %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; NOCAP-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; NOCAP-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; NOCAP-NOT: llvm.cheri.cap.invalidate
; NOCAP: ret void

; Vec passed by reference. The fact is the next instruction after the call.
define void @vec(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @eat_vec(ptr addrspace(200) %s)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @g()
  ret void
}
; CHECK-LABEL: define void @vec(
; CHECK: call {{.*}}@eat_vec(ptr addrspace(200) %s)
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p, i32 0)
; CHECK-NEXT: call {{.*}}@g()

; Slot address escaped, then the owner is loaded and moved. Still nulled.
define void @escaped(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @touch_box(ptr addrspace(200) %s)
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @escaped(
; CHECK: call {{.*}}@touch_box(ptr addrspace(200) %s)
; CHECK: %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; CHECK-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; CHECK-NOT: cheri.inv.cap
; CHECK: ret void

; Re-init after the move. The new store is after the fact and after the call
; that consumed the old owner, and it is not overwritten by another null.
define void @reinit_after(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @eat_box(ptr addrspace(200) %b)
  store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
  %w = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @eat_box(ptr addrspace(200) %w)
  ret void
}
; CHECK-LABEL: define void @reinit_after(
; CHECK: %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; CHECK-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %b, i32 0)
; CHECK-NEXT: store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
; CHECK-NEXT: %w = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; No fact: the Box shape is left unchanged.
define void @no_fact(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @no_fact(
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK-NOT: llvm.cheri.cap.invalidate
; CHECK: ret void

; Re-init store is the last write before the fact, with no load of the slot,
; no call taking the slot, and no use of the stored value in between.
define void @reinit_before(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @eat_box(ptr addrspace(200) %b)
  store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @g()
  ret void
}
; CHECK-LABEL: define void @reinit_before(
; CHECK: store ptr addrspace(200) %q, ptr addrspace(200) %s, align 16
; CHECK-NEXT: call {{.*}}@g()
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; The operand is not an alloca.
define void @not_alloca(ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @not_alloca(
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; Constant field offset. Only that field is nulled. Box placement: load, fact,
; then the call.
define void @field(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %s = alloca [32 x i8], align 16, addrspace(200)
  %field = getelementptr inbounds i8, ptr addrspace(200) %s, i64 16
  %other = getelementptr inbounds i8, ptr addrspace(200) %s, i64 0
  store ptr addrspace(200) %p, ptr addrspace(200) %field, align 16
  store ptr addrspace(200) %q, ptr addrspace(200) %other, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %field, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %field) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @field(
; CHECK: %b = load ptr addrspace(200), ptr addrspace(200) %field, align 16
; CHECK-NEXT: store volatile ptr addrspace(200) null, ptr addrspace(200) %field, align 16
; CHECK-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; CHECK-NOT: null, ptr addrspace(200) %other
; CHECK: ret void

; A variable index is not a constant field offset.
define void @var_index(ptr addrspace(200) %p, i64 %i) {
  %s = alloca [32 x i8], align 16, addrspace(200)
  %field = getelementptr i8, ptr addrspace(200) %s, i64 %i
  store ptr addrspace(200) %p, ptr addrspace(200) %field, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %field, align 16
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %field) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @var_index(
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; A constant offset that is not 16-byte aligned is not a slot.
define void @misaligned(ptr addrspace(200) %p) {
  %s = alloca [32 x i8], align 16, addrspace(200)
  %field = getelementptr inbounds i8, ptr addrspace(200) %s, i64 8
  store ptr addrspace(200) %p, ptr addrspace(200) %field, align 8
  %b = load ptr addrspace(200), ptr addrspace(200) %field, align 8
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %field) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @misaligned(
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; lifetime.end already reached the fact. Do not store into the dead slot.
define void @ended(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  store ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  %b = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %s) ]
  call void @eat_box(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @ended(
; CHECK: call {{.*}}@llvm.lifetime.end.p200(ptr addrspace(200) %s)
; CHECK-NEXT: call {{.*}}@eat_box(ptr addrspace(200) %b)
; CHECK-NOT: store {{(volatile )?}}ptr addrspace(200) null
; CHECK: ret void

; CHECK: [[PMV]] = !{!"cheri_inv_move"}
; basic, vec, escaped, reinit_after, field.
; STATS: move_nulls=5
