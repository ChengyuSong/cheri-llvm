; [LLM-generated] M7.1d B2c. Indexed / GEP destinations:
;   call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr base, i64 off, ptr cap) ]
; or a mem.store_into whose dest peels to base+offset. At the source mem.free
; the late pass rematerialises GEP(i8, base, off) if base and off are ready
; and the buffer has not moved, then exact-equal + store null. Unready or
; realloc dests are skipped. No ra/sp clear.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; Heap dest, constant byte offset, named as store_into_slot.
define void @heap_slot_const(ptr addrspace(200) %buf, ptr addrspace(200) %heap) {
  %slotstore = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slotstore, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 16, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @heap_slot_const(
; CHECK: call {{.*}}@use(ptr addrspace(200) %heap)
; CHECK: %[[P:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
; CHECK: load ptr addrspace(200), ptr addrspace(200) %[[P]], align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %[[P]], align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; FLAGOFF-LABEL: define void @heap_slot_const(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %buf)

; Same dest, but rustc emitted mem.store_into of the GEP (B2a shape). Peel it.
define void @heap_store_into_const(ptr addrspace(200) %buf, ptr addrspace(200) %heap) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @heap_store_into_const(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %{{[^,]+}}, align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; Variable index: rematerialise GEP(i8, base, %i) at the free.
define void @var_idx(ptr addrspace(200) %buf, ptr addrspace(200) %heap, i64 %i) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 %i
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 %i, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @var_idx(
; CHECK: store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
; CHECK: %[[Q:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 %i
; CHECK: load ptr addrspace(200), ptr addrspace(200) %[[Q]], align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %[[Q]], align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; Variable GEP of a local array, facted as store_into (peeled).
define void @array_var(ptr addrspace(200) %buf, i64 %i) {
  %a = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  %slot = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %a, i64 0, i64 %i
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %a)
  ret void
}
; CHECK-LABEL: define void @array_var(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %{{[^,]+}}, align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; A store to the Vec ptr field between the fact and the free: skip (realloc).
define void @realloc_skip(ptr addrspace(200) %buf, ptr addrspace(200) %heap, ptr addrspace(200) %newheap) {
  %v = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %heap, ptr addrspace(200) %v, align 16
  %base = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %slot = getelementptr inbounds i8, ptr addrspace(200) %base, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %base, i64 16, ptr addrspace(200) %buf) ]
  store ptr addrspace(200) %newheap, ptr addrspace(200) %v, align 16
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @realloc_skip(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK-NOT: store volatile ptr addrspace(200) null

; Index does not dominate the free: skip.
define void @idx_unready(ptr addrspace(200) %buf, ptr addrspace(200) %heap, i1 %c) {
entry:
  br i1 %c, label %haveidx, label %do_free
haveidx:
  %i = add i64 16, 0
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 %i
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 %i, ptr addrspace(200) %buf) ]
  br label %do_free
do_free:
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @idx_unready(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; Statics are out of B2c-1/2 scope: skip even if the global base is ready.
@gbuf = addrspace(200) global [2 x ptr addrspace(200)] zeroinitializer
define void @static_skip(ptr addrspace(200) %buf) {
  %slot = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) @gbuf, i64 0, i64 1
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) @gbuf, i64 16, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @static_skip(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64)

; rustc often facts mem.store_into of a mem.claim wrapping a variable GEP.
; The late pass must peel the claim and rematerialise base+idx*scale.
define void @claim_var(ptr addrspace(200) %buf, i64 %i) {
  %a = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  %gep = getelementptr inbounds [2 x ptr addrspace(200)], ptr addrspace(200) %a, i64 0, i64 %i
  %c = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %gep, i64 16, i64 256)
  store ptr addrspace(200) %buf, ptr addrspace(200) %c, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %c, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @claim_var(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %{{[^,]+}}, align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

define void @none_end() {
  ret void
}
; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: define void @none_end(

; 5 wipes (heap_slot_const, heap_store_into_const, var_idx, array_var, claim_var) +
; 3 unready (realloc_skip, idx_unready, static_skip). Facts = 8.
; STATS: store_into_facts=8
; STATS-SAME: store_into_nulls=5
; STATS-SAME: store_into_skipped_unready=3
; STATS-SAME: store_into_skipped_reassigned=0
