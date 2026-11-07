; [LLM-generated] M6.1 D95. Do not clear a capability that is still used after
; the free or the lifetime.end. realloc may return the same object, and a
; stack cap may be used after lifetime.end. D94: a scope with no later call
; is not cleared; a scope with a later call and a dead cap is.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @realloc(ptr addrspace(200)) addrspace(200)
declare void @use(ptr addrspace(200)) addrspace(200)
declare void @later() addrspace(200)
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))

define void @realloc_same(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: define void @realloc_same(
; CHECK-NOT: llvm.cheri.cap.invalidate
; CHECK: ret void
  %g = getelementptr inbounds i8, ptr addrspace(200) %p, i64 8
  %q = call ptr addrspace(200) @realloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) %p)
  call void @use(ptr addrspace(200) %g)
  call void @use(ptr addrspace(200) %q)
  ret void
}

define void @freed_dead(ptr addrspace(200) %p) addrspace(200) {
; CHECK-LABEL: define void @freed_dead(
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p)
; CHECK: call {{.*}}@later()
  call void @realloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @later()
  ret void
}

define void @scope_live() addrspace(200) {
; CHECK-LABEL: define void @scope_live(
; CHECK-NOT: llvm.cheri.cap.invalidate
; CHECK: ret void
  %a = alloca i8, align 16, addrspace(200)
  %g = getelementptr inbounds i8, ptr addrspace(200) %a, i64 1
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @use(ptr addrspace(200) %g)
  call void @use(ptr addrspace(200) %a)
  ret void
}

define void @scope_nocall() addrspace(200) {
; CHECK-LABEL: define void @scope_nocall(
; CHECK-NOT: llvm.cheri.cap.invalidate
; CHECK: ret void
  %a = alloca i8, align 16, addrspace(200)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  ret void
}

define void @scope_later() addrspace(200) {
; CHECK-LABEL: define void @scope_later(
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %a)
; CHECK: call {{.*}}@llvm.lifetime.end
; CHECK: call {{.*}}@later()
  %a = alloca i8, align 16, addrspace(200)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @later()
  ret void
}
