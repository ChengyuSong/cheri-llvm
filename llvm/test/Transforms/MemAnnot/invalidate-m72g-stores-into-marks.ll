; [LLM-generated] M7.2g: callee store marks. At a direct call to a function whose
; parameter carries "mem.stores_into"="<key>:<off>[:*<d>]" (paired with the
; parameter marked "mem.stores_into_dst"="<key>"), the late pass adds
;   call @llvm.mem.fact() [ "mem.store_into_slot"(dst arg, i64 off, cap) ]
; after the call and lowers it like a local fact: at the free of the stored
; pointer's target, compare the slot and null it only if it still holds that
; pointer. With ":*d" the cap is the pointer read at offset d through the
; argument. An unpaired key, the off switch, -cheri-invalidate-store-into=false
; and -cheri-invalidate=none add nothing.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stores-into-marks=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-store-into=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare void @put(ptr addrspace(200) "mem.stores_into_dst"="1" %r, ptr addrspace(200) "mem.stores_into"="1:16" %p)
declare void @put_deref(ptr addrspace(200) "mem.stores_into_dst"="0" %r, ptr addrspace(200) "mem.stores_into"="0:16:*0" %b)
declare void @put_unpaired(ptr addrspace(200) "mem.stores_into_dst"="3" %r, ptr addrspace(200) "mem.stores_into"="0:16" %p)

; The stored argument itself.
define void @direct(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @direct(
; CHECK: call {{.*}}@put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
; CHECK-NEXT: @llvm.cheri.cap.address.get.i64(ptr addrspace(200) %buf)
; CHECK: call {{.*}}@use(ptr addrspace(200) %heap)
; CHECK: %[[S:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
; CHECK: load ptr addrspace(200), ptr addrspace(200) %[[S]], align 16
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %[[S]], align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; OFF-LABEL: define void @direct(
; OFF-NOT: store volatile ptr addrspace(200) null
; OFF: call {{.*}}@free(ptr addrspace(200) %buf)

; The pointer read through the argument (a Box held in a local).
define void @deref(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %b, align 16
  call void @put_deref(ptr addrspace(200) %heap, ptr addrspace(200) %b)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %b)
  ret void
}
; CHECK-LABEL: define void @deref(
; CHECK: call {{.*}}@put_deref(ptr addrspace(200) %heap, ptr addrspace(200) %b)
; CHECK-NEXT: %storesinto.cap = load ptr addrspace(200), ptr addrspace(200) %b, align 16
; CHECK: %[[S2:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %[[S2]], align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; OFF-LABEL: define void @deref(
; OFF-NOT: storesinto
; OFF: call {{.*}}@free(ptr addrspace(200) %buf)

; No parameter carries key 0 as a destination: nothing.
define void @unpaired(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put_unpaired(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}
; CHECK-LABEL: define void @unpaired(
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; STATS: cheri-stores-into-marks: {{.*}} calls=2 facts=2
