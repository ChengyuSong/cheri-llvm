; [LLM-generated] M7.1d B3a. A cap argument marked mem.ffi_borrow is
; narrowed by dropping Global (candperm with ~1) immediately before the
; call. mem.ffi_retain is left alone. Unmarked caps are not narrowed
; (fail-safe). Function-pointer arguments are not marked by rustc and
; must stay un-narrowed even if they are addrspace(200).
; -cheri-invalidate-ffi-narrow=false and -cheri-invalidate=none emit no
; candperm (flag-off / none are byte-identical in this pass).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-ffi-narrow=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @ffi_stash(ptr addrspace(200))
declare void @ffi_retain(ptr addrspace(200))
declare void @ffi_register(ptr addrspace(200))
declare i64 @ffi_use(ptr addrspace(200))

define void @borrow(ptr addrspace(200) %p) {
  call void @ffi_stash(ptr addrspace(200) "mem.ffi_borrow" %p)
  ret void
}
; CHECK-LABEL: define void @borrow(
; CHECK: [[N:%.*]] = call {{.*}}@llvm.cheri.cap.perms.and.i64(ptr addrspace(200) %p, i64 -2)
; CHECK: call {{.*}}@ffi_stash(ptr addrspace(200) {{.*}}[[N]]
; CHECK: ret void
; NONE-LABEL: define void @borrow(
; NONE-NOT: cap.perms.and
; NONE: call {{.*}}@ffi_stash(ptr addrspace(200) %p
; FLAGOFF-LABEL: define void @borrow(
; FLAGOFF-NOT: cap.perms.and
; FLAGOFF: call {{.*}}@ffi_stash(ptr addrspace(200) %p

define void @retain(ptr addrspace(200) %p) {
  call void @ffi_retain(ptr addrspace(200) "mem.ffi_retain" %p)
  ret void
}
; CHECK-LABEL: define void @retain(
; CHECK-NOT: cap.perms.and
; CHECK: call {{.*}}@ffi_retain(ptr addrspace(200) "mem.ffi_retain" %p)
; CHECK: ret void

define void @unmarked(ptr addrspace(200) %p) {
  call void @ffi_stash(ptr addrspace(200) %p)
  ret void
}
; CHECK-LABEL: define void @unmarked(
; CHECK-NOT: cap.perms.and
; CHECK: call {{.*}}@ffi_stash(ptr addrspace(200) %p)
; CHECK: ret void

define void @fnptr(ptr addrspace(200) %cb) {
  call void @ffi_register(ptr addrspace(200) %cb)
  ret void
}
; CHECK-LABEL: define void @fnptr(
; CHECK-NOT: cap.perms.and
; CHECK: call {{.*}}@ffi_register(ptr addrspace(200) %cb)
; CHECK: ret void

define i64 @use_during(ptr addrspace(200) %p) {
  %v = call i64 @ffi_use(ptr addrspace(200) "mem.ffi_borrow" %p)
  ret i64 %v
}
; CHECK-LABEL: define i64 @use_during(
; CHECK: [[N:%.*]] = call {{.*}}@llvm.cheri.cap.perms.and.i64(ptr addrspace(200) %p, i64 -2)
; CHECK: call {{.*}}@ffi_use(ptr addrspace(200) {{.*}}[[N]]
; CHECK: ret i64

; STATS: ffi_borrow_facts=2
; STATS: ffi_narrows=2
; STATS: ffi_retain_skipped=1
