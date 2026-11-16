; [LLM-generated] M7.1d CR-1. rustc (or a later CR-2 section) emits a typic
; C-root table of C-visible writable capability statics:
;   @__cheri_croot = { i64 N, ptr @__cheri_croot_slots }
;   @__cheri_croot_slots = [N x ptr addrspace(200)] [ptr @SLOT, ...]
; At each mem.free, if the table is present and non-empty, the late pass
; exact-equals the freed cap against each ready slot and stores null through
; that global (csc zero; no ra/sp clear). An empty or absent table plants
; no walk. -cheri-invalidate-croot=false and -cheri-invalidate=none plant
; no walk. This is not a B2b store_into fact on the slot.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-croot=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-croot=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@FFI_SLOT = addrspace(200) global ptr addrspace(200) null, align 16
@FFI_CB = addrspace(200) global ptr addrspace(200) null, align 16
@__cheri_croot_slots = linkonce_odr addrspace(200) constant [1 x ptr addrspace(200)] [ptr addrspace(200) @FFI_SLOT], section "cheri_croot", align 16
@__cheri_croot = linkonce_odr addrspace(200) constant { i64, ptr addrspace(200) } { i64 1, ptr addrspace(200) @__cheri_croot_slots }, section "cheri_croot", align 16

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; Table names FFI_SLOT only. A mem.free of a cap that still sits in that
; slot is nulled; FFI_CB is not in the table and is left alone.
define void @croot_slot(ptr addrspace(200) %buf) {
  store volatile ptr addrspace(200) %buf, ptr addrspace(200) @FFI_SLOT, align 16
  call void @use(ptr addrspace(200) @FFI_SLOT)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @croot_slot(
; CHECK: call {{.*}}@use(ptr addrspace(200) @FFI_SLOT)
; CHECK: load ptr addrspace(200), ptr addrspace(200) @FFI_SLOT, align 16
; CHECK: @llvm.cheri.cap.equal.exact
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) @FFI_SLOT, align 16
; CHECK-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) @FFI_CB
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void
; FLAGOFF-LABEL: define void @croot_slot(
; FLAGOFF-NOT: @llvm.cheri.cap.equal.exact
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %buf)
; FLAGOFF-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) @FFI_SLOT
; FLAGOFF: ret void
; NONE-LABEL: define void @croot_slot(
; NONE-NOT: @llvm.cheri.cap.equal.exact
; NONE: call {{.*}}@free(ptr addrspace(200) %buf)
; NONE-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) @FFI_SLOT
; NONE: ret void

; STATS: croot_slots=1
; STATS: croot_walks=1
; STATS: croot_nulls=1
; STATS-OFF-NOT: croot_walks=1
; STATS-OFF-NOT: croot_nulls=1

; A module with a free but no table is tested in invalidate-croot-empty.ll.
