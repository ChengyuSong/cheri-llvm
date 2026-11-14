; [LLM-generated] M7.1d B2c-3a. Mid-end CSE of a post-push Vec header reload
; with the inlined push_mut grow/no-grow merge can make the element's store
; address a GEP of phi(load %v, load %v) rather than a later load %v.
; identifySlot must treat that PHI as the same field as a subsequent load
; so a ptr::read copy in a named local is still wiped at the source end.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()
declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64 immarg)

define void @eat_box(ptr addrspace(200) %b) {
  call void @free(ptr addrspace(200) %b) [ "mem.free"(ptr addrspace(200) %b) ]
  ret void
}

define void @copy_vec_slot_phi_buf(ptr addrspace(200) %buf, i1 %grew) {
  %v = alloca ptr addrspace(200), align 16, addrspace(200)
  %hold = alloca ptr addrspace(200), align 16, addrspace(200)
  %heap = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  store ptr addrspace(200) %heap, ptr addrspace(200) %v, align 16
  ; Earlier header reload (as emitted after a previous push / store_into_slot).
  %early = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  br i1 %grew, label %grow, label %merge

grow:
  %post = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  br label %merge

merge:
  %p0 = phi ptr addrspace(200) [ %early, %0 ], [ %post, %grow ]
  %slot = getelementptr inbounds i8, ptr addrspace(200) %p0, i64 16
  %cslot = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %slot, i64 16, i64 256)
  %claimed = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %buf, i64 8, i64 261)
  store ptr addrspace(200) %claimed, ptr addrspace(200) %cslot, align 16
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
; CHECK-LABEL: define void @copy_vec_slot_phi_buf(
; CHECK: call {{.*}}@llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %hold, align 16
; CHECK: call {{.*}}@eat_box(
; CHECK: ret void
; NONE-LABEL: define void @copy_vec_slot_phi_buf(
; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: call {{.*}}@eat_box(

; STATS: store_into_facts=1
; STATS-SAME: store_into_nulls=1
