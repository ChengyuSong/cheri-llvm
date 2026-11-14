; [LLM-generated] M7.1d B2a. A capability stored into a nameable local dest
; is a caller-side fact:
;   call void @llvm.mem.fact() [ "mem.store_into"(ptr dest, ptr cap) ]
; At the source mem.free, if dest is still a ready fat pointer and still
; holds that cap (exact-equal), the late pass stores null through dest
; immediately before the free. No buffer scan, no sibling write, no ra/sp
; clear, no narrowing at the store. Reassigned or unready dests are skipped.
; -cheri-invalidate-store-into=false emits no wipe (byte-identical policy
; to 0c127e28 when rustc also emits no fact).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; Dest is a named local slot. The cap is the freed buffer itself. The wipe
; is a single-slot exact-equal store immediately before mem.free.
define void @basic(ptr addrspace(200) %buf) {
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %dest)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @basic(
; CHECK: call {{.*}}@use(ptr addrspace(200) %dest)
; CHECK: load ptr addrspace(200), ptr addrspace(200) %dest, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %dest, align 16
; CHECK-NOT: @llvm.cheri.cap.base.get
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void
; FLAGOFF-LABEL: define void @basic(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %buf)
; FLAGOFF-NOT: store volatile ptr addrspace(200) null
; FLAGOFF: ret void

; Only the facted field is written. The sibling slot is not stored.
define void @sibling(ptr addrspace(200) %buf, ptr addrspace(200) %live) {
  %hold = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  %raw = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %hold, i64 0, i64 0
  %sib = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %hold, i64 0, i64 1
  store ptr addrspace(200) %live, ptr addrspace(200) %sib, align 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %raw, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %raw, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %sib)
  ret void
}
; CHECK-LABEL: define void @sibling(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %raw, align 16
; CHECK-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sib
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void

; A later store of a different cap to dest is skipped (reassigned).
define void @reassigned(ptr addrspace(200) %buf, ptr addrspace(200) %other) {
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  store ptr addrspace(200) %other, ptr addrspace(200) %dest, align 16
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @reassigned(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: ret void

; Dest is not available at the free (defined only on another path conceptually:
; a pointer that does not dominate the free). Here dest is an argument used
; only as a value, and we give a dest that is not a fat-pointer-ready address
; at the free: the dest SSA is a select defined after the fact but we use a
; dest that is an i8* integer-derived non-fat... Use a dest computed after
; the free so it does not dominate. That dest cannot be named at the free.
define void @unready(ptr addrspace(200) %buf, i1 %c) {
entry:
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  br i1 %c, label %factbb, label %do_free
factbb:
  ; The fact does not dominate the free, so the dest is not ready to wipe.
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  br label %do_free
do_free:
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @unready(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: ret void

; eat_box is known to free: its body has mem.free of the argument.
; A declaration with no body is not treated as the source end of life.
define void @eat_box(ptr addrspace(200) %b) {
  call void @free(ptr addrspace(200) %b) [ "mem.free"(ptr addrspace(200) %b) ]
  ret void
}

; Box::leak-like: takes a mem.box_family argument but does not free it.
define ptr addrspace(200) @leak_box(ptr addrspace(200) %b) {
  ret ptr addrspace(200) %b
}


; The source free lives in a callee. The caller moves an owned Box
; (mem.box_family) into that call; the wipe is immediately before it.
define void @consume_box(ptr addrspace(200) %buf) {
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  call void @eat_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  ret void
}
; CHECK-LABEL: define void @consume_box(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %dest, align 16
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void
; FLAGOFF-LABEL: define void @consume_box(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@eat_box(
; FLAGOFF: ret void

declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64 immarg)

; Heap dest (Box::new payload / Vec buffer): ready but not a named local.
; B2c-1: a ready heap cell (argument base, constant offset 0) is rematerialised
; and wiped at the consume of the referent. Statics remain skipped.
define void @heap_dest(ptr addrspace(200) %buf, ptr addrspace(200) %cell) {
  store ptr addrspace(200) %buf, ptr addrspace(200) %cell, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %cell, ptr addrspace(200) %buf) ]
  call void @eat_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  ret void
}
; CHECK-LABEL: define void @heap_dest(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %{{[^,]+}}, align 16
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void

; ptr::read dest: the fact cap is a load of a slot that stored a claim of
; the referent. Wipe the named local at the consume call.
define void @copy_local(ptr addrspace(200) %buf) {
  %slot = alloca ptr addrspace(200), align 16, addrspace(200)
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  %claimed = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %buf, i64 8, i64 261)
  store ptr addrspace(200) %claimed, ptr addrspace(200) %slot, align 16
  %copy = load ptr addrspace(200), ptr addrspace(200) %slot, align 16
  store ptr addrspace(200) %copy, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %copy) ]
  call void @eat_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  ret void
}
; CHECK-LABEL: define void @copy_local(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %dest, align 16
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void
; FLAGOFF-LABEL: define void @copy_local(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@eat_box(
; FLAGOFF: ret void

; A facted sibling cap (the still-live dummy) must not be treated as the
; consumed box just because both may come from the same allocator.
define void @sibling_consume(ptr addrspace(200) %buf, ptr addrspace(200) %dummy) {
  %hold = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  %raw = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %hold, i64 0, i64 0
  %sib = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %hold, i64 0, i64 1
  store ptr addrspace(200) %dummy, ptr addrspace(200) %sib, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %sib, ptr addrspace(200) %dummy) ]
  store ptr addrspace(200) %buf, ptr addrspace(200) %raw, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %raw, ptr addrspace(200) %buf) ]
  call void @eat_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  ret void
}
; CHECK-LABEL: define void @sibling_consume(
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %raw, align 16
; CHECK-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sib
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void


; Named local holding a store_into copy whose cap is then passed to a
; non-freeing consume (Box::leak). Dest must not be wiped.
define void @leak_local(ptr addrspace(200) %buf) {
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  %leaked = call ptr addrspace(200) @leak_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  call void @use(ptr addrspace(200) %dest)
  call void @use(ptr addrspace(200) %leaked)
  ret void
}
; CHECK-LABEL: define void @leak_local(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: call {{.*}}@leak_box(
; CHECK: ret void

; ptr::read of a Vec heap slot: two loads of the same Vec::ptr field, a
; store through claim(gep(load, len)) and a later load through
; claim(gep(load, 16)), with len resolved from a dominating constant store.
; The named local dest is wiped when the referent is consumed.
define void @copy_vec_slot(ptr addrspace(200) %buf) {
  %v = alloca ptr addrspace(200), align 16, addrspace(200)
  %len = alloca i64, align 8, addrspace(200)
  %hold = alloca ptr addrspace(200), align 16, addrspace(200)
  %heap = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  store ptr addrspace(200) %heap, ptr addrspace(200) %v, align 16
  store i64 0, ptr addrspace(200) %len, align 8
  ; push at index 1: store 1 to len, then store cap at gep([16 x i8], load(v), len)
  store i64 1, ptr addrspace(200) %len, align 8
  %p0 = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %l = load i64, ptr addrspace(200) %len, align 8
  %slot = getelementptr inbounds [16 x i8], ptr addrspace(200) %p0, i64 %l
  %cslot = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %slot, i64 16, i64 256)
  %claimed = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %buf, i64 8, i64 261)
  store ptr addrspace(200) %claimed, ptr addrspace(200) %cslot, align 16
  ; later increment of len must not hide the offset at the store
  store i64 2, ptr addrspace(200) %len, align 8
  ; ptr::read: load from claim(gep(i8, load(v), 16))
  %p1 = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %slot2 = getelementptr inbounds i8, ptr addrspace(200) %p1, i64 16
  %cslot2 = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %slot2, i64 16, i64 256)
  %copy = load ptr addrspace(200), ptr addrspace(200) %cslot2, align 16
  store ptr addrspace(200) %copy, ptr addrspace(200) %hold, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %hold, ptr addrspace(200) %copy) ]
  call void @eat_box(ptr addrspace(200) "mem.box_family"="__rust_alloc" %buf)
  ret void
}
; CHECK-LABEL: define void @copy_vec_slot(
; CHECK: call {{.*}}@llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %hold, align 16
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void

define void @none_end() {
  ret void
}
; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: define void @none_end(

; STATS: store_into_facts=11
; STATS-SAME: store_into_nulls=7
; STATS-SAME: store_into_skipped_unready=3
; STATS-SAME: store_into_skipped_reassigned=1
; STATS-OFF: store_into_facts=11
; STATS-OFF-SAME: store_into_nulls=0
