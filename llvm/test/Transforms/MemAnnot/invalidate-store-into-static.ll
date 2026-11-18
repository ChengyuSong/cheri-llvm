; [LLM-generated] M7.1d B2b. A capability stored into a GlobalVariable (or a
; constant GEP of one) is a ready dest:
;   call void @llvm.mem.fact() [ "mem.store_into"(ptr dest, ptr cap) ]
;   call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr base, i64 off, ptr cap) ]
; At the source mem.free, if dest still holds that cap (exact-equal), the
; late pass stores null through the global address immediately before the
; free. No ra/sp clear, no narrowing at the store. Reassigned dests are
; skipped. Cross-crate vs local is the same exact-equal rule.
; -cheri-invalidate-store-into=false emits no wipe.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into-int=false < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-store-into=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@SLOT = addrspace(200) global ptr addrspace(200) null, align 16
@HOLD = addrspace(200) global { i64, ptr addrspace(200) } zeroinitializer, align 16

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; dest is the global itself.
define void @static_slot(ptr addrspace(200) %buf) {
  store ptr addrspace(200) %buf, ptr addrspace(200) @SLOT, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) @SLOT, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) @SLOT)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @static_slot(
; CHECK: call {{.*}}@use(ptr addrspace(200) @SLOT)
; CHECK: load ptr addrspace(200), ptr addrspace(200) @SLOT, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) @SLOT, align 16
; CHECK-NOT: @llvm.cheri.cap.base.get
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void
; FLAGOFF-LABEL: define void @static_slot(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %buf)
; FLAGOFF-NOT: store volatile ptr addrspace(200) null
; FLAGOFF: ret void

; dest is a constant GEP of a static struct field (static_write).
define void @static_field(ptr addrspace(200) %buf) {
  %p = getelementptr inbounds { i64, ptr addrspace(200) }, ptr addrspace(200) @HOLD, i64 0, i32 1
  store ptr addrspace(200) %buf, ptr addrspace(200) %p, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %p, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @static_field(
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) getelementptr inbounds (i8, ptr addrspace(200) @HOLD, i64 16), align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void

; Same field, named as store_into_slot (base + const offset).
define void @static_field_slot(ptr addrspace(200) %buf) {
  %p = getelementptr inbounds { i64, ptr addrspace(200) }, ptr addrspace(200) @HOLD, i64 0, i32 1
  store ptr addrspace(200) %buf, ptr addrspace(200) %p, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) @HOLD, i64 16, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @static_field_slot(
; CHECK: getelementptr inbounds (i8, ptr addrspace(200) @HOLD, i64 16)
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) getelementptr inbounds (i8, ptr addrspace(200) @HOLD, i64 16), align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void

; A later store of a different cap is skipped (reassigned).
define void @reassigned(ptr addrspace(200) %buf, ptr addrspace(200) %other) {
  store ptr addrspace(200) %buf, ptr addrspace(200) @SLOT, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) @SLOT, ptr addrspace(200) %buf) ]
  store ptr addrspace(200) %other, ptr addrspace(200) @SLOT, align 16
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @reassigned(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: ret void

; Only the facted field is written. The sibling pad is not a cap dest here,
; but a second global slot must not be stored just because it is static.
define void @other_static_untouched(ptr addrspace(200) %buf) {
  store ptr addrspace(200) %buf, ptr addrspace(200) @SLOT, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) @SLOT, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @other_static_untouched(
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) @SLOT, align 16
; CHECK-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) @HOLD
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void

define void @none_end() {
  ret void
}
; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: define void @none_end(

; STATS: store_into_facts=5
; STATS-SAME: store_into_nulls=4
; STATS-SAME: store_into_skipped_unready=0
; STATS-SAME: store_into_skipped_reassigned=1
; STATS-OFF: store_into_facts=5
; STATS-OFF-SAME: store_into_nulls=0
