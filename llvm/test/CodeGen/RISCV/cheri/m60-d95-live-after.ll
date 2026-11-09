; [LLM-generated] M6.1 D94/D97. The IR clear is still emitted when a value is
; used again (D95 is gone). The post-RA pass drops it if the physical
; register is live, so the later use is not handed a null capability.
; D94: a scope with no later call is not cleared.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s --check-prefix=ASM

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @realloc(ptr addrspace(200)) addrspace(200)
declare void @use(ptr addrspace(200)) addrspace(200)
declare void @later() addrspace(200)
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))

define void @realloc_same(ptr addrspace(200) %p) addrspace(200) {
; IR-LABEL: define void @realloc_same(
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p,
; IR: call {{.*}}@use(ptr addrspace(200) %p)
; ASM-LABEL: realloc_same:
; ASM: ccall realloc
; ASM-NOT: cmove {{.*}}, zero
; ASM: ccall use
  %g = getelementptr inbounds i8, ptr addrspace(200) %p, i64 8
  %q = call ptr addrspace(200) @realloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) %p)
  call void @use(ptr addrspace(200) %g)
  call void @use(ptr addrspace(200) %q)
  ret void
}

define void @freed_dead(ptr addrspace(200) %p) addrspace(200) {
; IR-LABEL: define void @freed_dead(
; IR: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p,
; IR: call {{.*}}@later()
; ASM-LABEL: freed_dead:
; ASM: cmove {{.*}}, zero
; ASM: ccall later
  call void @realloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @later()
  ret void
}

define void @scope_live() addrspace(200) {
; IR-LABEL: define void @scope_live(
; IR: call {{.*}}@llvm.cheri.cap.invalidate
; IR: call {{.*}}@use(ptr addrspace(200) %g)
; ASM-LABEL: scope_live:
; ASM: ccall use
; ASM: ccall use
  %a = alloca i8, align 16, addrspace(200)
  %g = getelementptr inbounds i8, ptr addrspace(200) %a, i64 1
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @use(ptr addrspace(200) %g)
  call void @use(ptr addrspace(200) %a)
  ret void
}

define void @scope_nocall() addrspace(200) {
; IR-LABEL: define void @scope_nocall(
; IR-NOT: llvm.cheri.cap.invalidate
; IR: ret void
; ASM-LABEL: scope_nocall:
; ASM-NOT: cmove
; ASM: cret
  %a = alloca i8, align 16, addrspace(200)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  ret void
}

define void @scope_later() addrspace(200) {
; IR-LABEL: define void @scope_later(
; IR-NOT: llvm.cheri.cap.invalidate
; IR: call {{.*}}@llvm.lifetime.end
; IR: call {{.*}}@later()
; ASM-LABEL: scope_later:
; ASM-NOT: cmove
; ASM: ccall later
  ; D99. Nothing reads this alloca, so there is no capability to clear.
  %a = alloca i8, align 16, addrspace(200)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @later()
  ret void
}
