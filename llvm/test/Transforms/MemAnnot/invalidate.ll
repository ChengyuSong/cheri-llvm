; [LLM-generated] M5r R4 Track B prototype (-cheri-invalidate): frame capability
; slots are cleared at a free ("mem.free") and at a lifetime.end (scope).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=all < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=all -cheri-invalidate-filter=false < %s | FileCheck %s --check-prefix=NOFILT
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @dealloc(ptr addrspace(200))
declare void @use(ptr addrspace(200))

; A volatile frame slot keeps a pointer into %p across the free.
define void @uaf(ptr addrspace(200) %p) {
  %slot = alloca ptr addrspace(200), align 16, addrspace(200)
  %q = getelementptr i8, ptr addrspace(200) %p, i64 8
  store volatile ptr addrspace(200) %q, ptr addrspace(200) %slot, align 16
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  %r = load volatile ptr addrspace(200), ptr addrspace(200) %slot, align 16
  call void @use(ptr addrspace(200) %r)
  ret void
}
; CHECK-LABEL: define void @uaf(
; CHECK:         [[LO:%.*]] = call addrspace(200) i64 @llvm.cheri.cap.base.get.i64(ptr addrspace(200) %p)
; CHECK-NEXT:    [[LEN:%.*]] = call addrspace(200) i64 @llvm.cheri.cap.length.get.i64(ptr addrspace(200) %p)
; CHECK-NEXT:    call addrspace(200) void @dealloc(ptr addrspace(200) %p)
; CHECK-NEXT:    [[C:%.*]] = load ptr addrspace(200), ptr addrspace(200) %slot, align 16
; CHECK:         @llvm.cheri.cap.tag.clear(
; CHECK:         store ptr addrspace(200) {{.*}}, ptr addrspace(200) %slot, align 16
; NONE-LABEL: define void @uaf(
; NONE-NOT:     cheri.cap.tag.clear

; A slot outliving the scope of %x keeps a pointer into it; %x's own cap slot
; is nulled at its lifetime.end.
define void @scope(ptr addrspace(200) %v) {
  %slot = alloca ptr addrspace(200), align 16, addrspace(200)
  %x = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %x)
  store ptr addrspace(200) %v, ptr addrspace(200) %x, align 16
  store volatile ptr addrspace(200) %x, ptr addrspace(200) %slot, align 16
  call void @use(ptr addrspace(200) %x)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %x)
  %r = load volatile ptr addrspace(200), ptr addrspace(200) %slot, align 16
  call void @use(ptr addrspace(200) %r)
  ret void
}
; CHECK-LABEL: define void @scope(
; CHECK:         store ptr addrspace(200) null, ptr addrspace(200) %x, align 16
; CHECK:         @llvm.cheri.cap.address.get.i64(ptr addrspace(200) %x)
; CHECK:         load ptr addrspace(200), ptr addrspace(200) %slot, align 16
; CHECK:         @llvm.cheri.cap.tag.clear(
; CHECK:         call addrspace(200) void @llvm.lifetime.end.p200(ptr addrspace(200) %x)
; R4 filter: %slot only ever holds the argument %v (cannot point into %x),
; and the never-escaping %slot2 is not read after the scope end.
define void @filtered(ptr addrspace(200) %v) {
  %slot = alloca ptr addrspace(200), align 16, addrspace(200)
  %slot2 = alloca ptr addrspace(200), align 16, addrspace(200)
  %x = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %x)
  store volatile ptr addrspace(200) %v, ptr addrspace(200) %slot, align 16
  store ptr addrspace(200) %x, ptr addrspace(200) %slot2, align 16
  %r2 = load ptr addrspace(200), ptr addrspace(200) %slot2, align 16
  call void @use(ptr addrspace(200) %r2)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %x)
  %r = load volatile ptr addrspace(200), ptr addrspace(200) %slot, align 16
  call void @use(ptr addrspace(200) %r)
  ret void
}
; CHECK-LABEL: define void @filtered(
; CHECK-NOT:     cheri.cap.tag.clear
; CHECK:         ret void
; NOFILT-LABEL: define void @filtered(
; NOFILT-COUNT-2: cheri.cap.tag.clear
; NOFILT:        ret void

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
