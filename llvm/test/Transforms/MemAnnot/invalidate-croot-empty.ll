; [LLM-generated] M7.1d CR-1. An absent or empty typic C-root table plants
; no walk at mem.free (official KPI typic set is empty; do not hook
; alloc/core with a length-0 check).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@FFI_SLOT = addrspace(200) global ptr addrspace(200) null, align 16

declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

define void @no_table(ptr addrspace(200) %buf) {
  store volatile ptr addrspace(200) %buf, ptr addrspace(200) @FFI_SLOT, align 16
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @no_table(
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) @FFI_SLOT
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: ret void
; STATS: croot_slots=0
; STATS-NOT: croot_walks=1
; STATS-NOT: croot_nulls=1
