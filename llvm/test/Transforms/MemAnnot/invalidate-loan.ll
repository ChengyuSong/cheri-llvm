; [LLM-generated] M5r R5 Track B: loan-end invalidation (D36) and the cheaper
; filters (D37). A frame slot whose every capability store carries the rustc
; slot fact !mem.loan !{L} is nulled after the !mem.last_use carrier of L.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s --check-prefix=LOAN
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=scope+free < %s | FileCheck %s --check-prefix=SF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=all < %s | FileCheck %s --check-prefix=ALL
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=all -cheri-invalidate-loan-skip=false < %s | FileCheck %s --check-prefix=NOSKIP
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-asm-noescape=false < %s | FileCheck %s --check-prefix=ASMESC
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=all -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @g()
declare void @use(ptr addrspace(200))
declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))

; The slot only ever holds loan 5's reference: nulled after its last use.
define void @loan(ptr addrspace(200) %p) {
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  %v = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16, !mem.last_use !0
  call void @g()
  ret void
}
; LOAN-LABEL: define void @loan(
; LOAN: load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16
; LOAN-NEXT: store ptr addrspace(200) null, ptr addrspace(200) %r, align 16
; LOAN-NEXT: call addrspace(200) void @g()
; SF-LABEL: define void @loan(
; SF-NOT: store ptr addrspace(200) null
; SF: ret void

; An untagged store may put another value in the slot: no clear.
define void @mixed(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  %v = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16, !mem.last_use !0
  store volatile ptr addrspace(200) %q, ptr addrspace(200) %r, align 16
  call void @g()
  ret void
}
; LOAN-LABEL: define void @mixed(
; LOAN-NOT: store ptr addrspace(200) null
; LOAN: ret void

; The slot escapes into a call (which may write it): no clear. An empty-asm
; (black_box) use does not count as an escape.
define void @escaped(ptr addrspace(200) %p) {
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  call void @use(ptr addrspace(200) %r)
  %v = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16, !mem.last_use !0
  ret void
}
; LOAN-LABEL: define void @escaped(
; LOAN-NOT: store ptr addrspace(200) null
; LOAN: ret void
define void @blackbox(ptr addrspace(200) %p) {
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !0
  call void asm sideeffect "", "C,~{memory}"(ptr addrspace(200) %r)
  %v = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16, !mem.last_use !0
  call void @g()
  ret void
}
; LOAN-LABEL: define void @blackbox(
; LOAN: load volatile ptr addrspace(200), ptr addrspace(200) %r
; LOAN-NEXT: store ptr addrspace(200) null, ptr addrspace(200) %r
; ASMESC-LABEL: define void @blackbox(
; ASMESC-NOT: store ptr addrspace(200) null
; ASMESC: ret void

; A reference into %buf in a loan slot: its clear lies on every path to the
; end of %buf's scope, so the scope event needs no range check for it.
define void @skip() {
  %buf = alloca [4 x i64], align 16, addrspace(200)
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %buf)
  %e = getelementptr inbounds i8, ptr addrspace(200) %buf, i64 8
  store volatile ptr addrspace(200) %e, ptr addrspace(200) %r, align 16, !mem.loan !1
  %v = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16, !mem.last_use !1
  call void @g()
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %buf)
  %w = load volatile ptr addrspace(200), ptr addrspace(200) %r, align 16
  ret void
}
; ALL-LABEL: define void @skip(
; ALL: %v = load volatile
; ALL-NEXT: store ptr addrspace(200) null, ptr addrspace(200) %r
; ALL-NOT: cheri.inv.cap
; ALL: ret void
; NOSKIP-LABEL: define void @skip(
; NOSKIP: %cheri.inv.cap = load ptr addrspace(200), ptr addrspace(200) %r
; NOSKIP: call addrspace(200) void @llvm.lifetime.end
; STATS: loan_facts=5 loan_slots=3 loan_clears=3 loan_skipped=1

!0 = !{i64 5}
!1 = !{i64 9}
