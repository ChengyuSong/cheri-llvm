; [LLM-generated] M7.2c gap fixes round 1, late IR pass part.
; 1. A call that takes a "mem.box_family" capability argument is may-free.
; 2. The loan_into scan loop exit carries a kind-0 invalidate of the loan.
; 3. store_into compares address/high/tag integers taken at the fact,
;    not the old capability.
; 4. rustc's post-dealloc llvm.mem.fact "mem.free" uses kind 3 (heap free);
;    a free bundle on another call (realloc) keeps kind 0.
; Each rule has its own off switch.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-box-family-mayfree=false -cheri-invalidate-loan-into-exit-anchor=false -cheri-invalidate-store-into-int=false -cheri-invalidate-heap-free-untag=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONEBOX
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare ptr addrspace(200) @realloc(ptr addrspace(200))
declare void @eat(ptr addrspace(200) "mem.box_family"="__rust_alloc")
declare void @llvm.mem.fact()

define void @moved_box(ptr addrspace(200) %b) {
  call void @eat(ptr addrspace(200) "mem.box_family"="__rust_alloc" %b)
  call void @use(ptr addrspace(200) null)
  ret void
}

define void @heap_free_live(ptr addrspace(200) %p) {
  call void @free(ptr addrspace(200) %p)
  call void @llvm.mem.fact() [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) null)
  call void @use(ptr addrspace(200) %p)
  ret void
}

define void @realloc_bundle(ptr addrspace(200) %p) {
  %q = call ptr addrspace(200) @realloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) %p)
  call void @use(ptr addrspace(200) %q)
  ret void
}

define void @store_into_int(ptr addrspace(200) %buf) {
  %dest = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %dest, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %dest, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %dest)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

define void @loan_into_exit(ptr addrspace(200) %buf, ptr addrspace(200) %loan) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %s, align 16
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %s, ptr addrspace(200) %loan, i64 1) ]
  call void @use(ptr addrspace(200) %loan), !mem.last_use !1
  ret void
}
!1 = !{i64 1}

; CHECK-LABEL: define void @moved_box(
; CHECK: call {{.*}}@eat(ptr addrspace(200) "mem.box_family"="__rust_alloc" %b) #[[MF:[0-9]+]]
; OFF-LABEL: define void @moved_box(
; OFF: call {{.*}}@eat(ptr addrspace(200) "mem.box_family"="__rust_alloc" %b){{$}}
; Under -cheri-invalidate=none the round-1 fixes are off (byte-stable ablation).
; NONEBOX-LABEL: define void @moved_box(
; NONEBOX: call {{.*}}@eat(ptr addrspace(200) "mem.box_family"="__rust_alloc" %b){{$}}

; CHECK-LABEL: define void @heap_free_live(
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p, i32 3)
; CHECK: call {{.*}}@use(ptr addrspace(200) %p)
; OFF-LABEL: define void @heap_free_live(
; OFF: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p, i32 0)

; CHECK-LABEL: define void @realloc_bundle(
; CHECK: @realloc(
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %p, i32 0)

; CHECK-LABEL: define void @store_into_int(
; CHECK: store ptr addrspace(200) %buf, ptr addrspace(200) %dest
; CHECK-NEXT: [[A:%.*]] = call {{.*}}@llvm.cheri.cap.address.get.i64(ptr addrspace(200) %buf)
; CHECK-NEXT: [[H:%.*]] = call {{.*}}@llvm.cheri.cap.high.get.i64(ptr addrspace(200) %buf)
; CHECK-NEXT: [[T:%.*]] = call {{.*}}@llvm.cheri.cap.tag.get(ptr addrspace(200) %buf)
; CHECK-NEXT: call {{.*}}@use(ptr addrspace(200) %dest)
; CHECK: %storeinto.got = load ptr addrspace(200), ptr addrspace(200) %dest
; CHECK-NOT: @llvm.cheri.cap.equal.exact
; CHECK: icmp eq i64 {{.*}}, [[A]]
; CHECK: icmp eq i64 {{.*}}, [[H]]
; CHECK: icmp eq i1 {{.*}}, [[T]]
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %dest
; CHECK: call {{.*}}@free(
; OFF-LABEL: define void @store_into_int(
; OFF-NOT: @llvm.cheri.cap.high.get
; OFF: @llvm.cheri.cap.equal.exact(ptr addrspace(200) %storeinto.got, ptr addrspace(200) %buf)

; CHECK-LABEL: define void @loan_into_exit(
; CHECK: @llvm.cheri.cap.equal.exact(ptr addrspace(200) %loaninto.eltv, ptr addrspace(200) %loan)
; CHECK: loaninto.cont:
; CHECK-NEXT: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %loan, i32 0)
; CHECK-NEXT: ret void
; OFF-LABEL: define void @loan_into_exit(
; OFF: loaninto.cont:
; OFF-NEXT: ret void

; CHECK: attributes #[[MF]] = { "cheri-may-free" }

; NONE-NOT: @llvm.cheri.cap.invalidate
; NONE-NOT: @llvm.cheri.cap.high.get

; STATS: loan_into_exit_anchor=1 store_into_int=1
