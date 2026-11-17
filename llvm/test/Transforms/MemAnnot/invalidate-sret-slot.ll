; [LLM-generated] M7.1d S-1a. A static alloca used as an sret dest (a
; cap-holding return slot written by the callee) is a CapSlots member at
; offset 0, the pointer word only. Existing InvOwnNull then stores null
; through that ready alloca at lifetime.end, even though the address
; escaped to the sret callee. Offsets 16 and 32 (String/Vec usizes) are
; not wiped. -cheri-invalidate=none and -cheri-invalidate-own-null=false
; emit nothing. A non-sret alloca passed to a callee is not classified.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=ON
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-own-null=false < %s | FileCheck %s --check-prefix=OWNOFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-sret-slots=false < %s | FileCheck %s --check-prefix=SRETOFF
; RUN: rm -f %t.stats-sretoff && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate-sret-slots=false -cheri-invalidate-stats-out=%t.stats-sretoff < %s && FileCheck %s --check-prefix=STATS-SRETOFF < %t.stats-sretoff
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=none -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @make_string(ptr addrspace(200) sret([48 x i8]) align 16)
declare void @dealloc(ptr addrspace(200))
declare void @use(ptr addrspace(200))

define void @sret_drop() {
  %s = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  call void @make_string(ptr addrspace(200) sret([48 x i8]) align 16 %s)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @sret_drop(
; ON: call {{.*}}@make_string(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; ON-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %s
; ON: call {{.*}}@llvm.lifetime.end.p200
; NONE-LABEL: define void @sret_drop(
; NONE-NOT: store volatile ptr addrspace(200) null
; OWNOFF-LABEL: define void @sret_drop(
; OWNOFF-NOT: store volatile ptr addrspace(200) null
; SRETOFF-LABEL: define void @sret_drop(
; SRETOFF-NOT: store volatile ptr addrspace(200) null

; Same shape as bench: sret, then mem.free of the loaded cap, then lifetime.end.
; The null is a store through the alloca (ready address), after the free.
define void @sret_then_free() {
  %s = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  call void @make_string(ptr addrspace(200) sret([48 x i8]) align 16 %s)
  %p = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @sret_then_free(
; ON: call {{.*}}@dealloc(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

; A non-sret alloca passed to a callee, with no local cap store, is not a slot.
define void @not_sret() {
  %s = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  call void @use(ptr addrspace(200) %s)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @not_sret(
; ON-NOT: store volatile ptr addrspace(200) null
; ON: call {{.*}}@llvm.lifetime.end.p200

; STATS: sret_slots={{[1-9]}}
; STATS-OFF-NOT: store volatile
; The none run emits no own-nulls; sret_slots may still be counted if the
; collector runs, but the invalidate=none path must not plant a store.
; STATS-OFF-NOT: own_nulled={{[1-9]}}
; STATS-SRETOFF: sret_slots=0
; STATS-SRETOFF-NOT: own_nulled={{[1-9]}}
