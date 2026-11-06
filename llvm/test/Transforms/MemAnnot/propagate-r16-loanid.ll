; [LLM-generated] M5r R16: an inlined loan copy is never deleted because its packed
; copy key collided, the salt mix would be 0, or the packed field is full.
; The copy is another high value, or !{i64 orig, i64 disambiguator} and
; "mem.last_use.ext"(i64 orig, i64 disambiguator) when no high value is free.
; The last-use names that copy only. -mem-inline-loan-high-bits=1 makes the
; packed field one slot wide so a test can fill it. Production width stays 21.
;
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 -verify-each < %s | FileCheck %s --check-prefix=EX
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 < %s | opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -verify-each | FileCheck %s --check-prefix=INV

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
target triple = "x86_64-unknown-linux-gnu"

declare void @llvm.mem.fact()

define internal void @inner(ptr addrspace(200) %slot, ptr addrspace(200) %cap) alwaysinline {
  store ptr addrspace(200) %cap, ptr addrspace(200) %slot, align 16, !mem.loan !0
  call void @llvm.mem.fact() [ "mem.last_use"(i64 3) ]
  ret void
}

; Two copies. The second packed key is the first, so the second copy is extended.
define void @twice(ptr addrspace(200) %pa, ptr addrspace(200) %pb) addrspace(200) {
; EX-LABEL: define void @twice(
; EX: store ptr addrspace(200) %pa, ptr addrspace(200) %sa{{.*}}!mem.loan [[P:![0-9]+]]
; EX: [ "mem.last_use"(i64 4398046511107) ]
; EX: store ptr addrspace(200) %pb, ptr addrspace(200) %sb{{.*}}!mem.loan [[E:![0-9]+]]
; EX: [ "mem.last_use.ext"(i64 3, i64 1) ]
; INV-LABEL: define void @twice(
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV: ret void
;
  %sa = alloca ptr addrspace(200), align 16, addrspace(200)
  %sb = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @inner(ptr addrspace(200) %sa, ptr addrspace(200) %pa)
  call void @inner(ptr addrspace(200) %sb, ptr addrspace(200) %pb)
  ret void
}

define internal void @leaf(ptr addrspace(200) %slot, ptr addrspace(200) %cap) alwaysinline {
  store ptr addrspace(200) %cap, ptr addrspace(200) %slot, align 16, !mem.loan !0
  call void @llvm.mem.fact() [ "mem.last_use"(i64 3) ]
  ret void
}

define internal void @mid(ptr addrspace(200) %slot, ptr addrspace(200) %cap) alwaysinline {
  call void @leaf(ptr addrspace(200) %slot, ptr addrspace(200) %cap)
  ret void
}

; Nested inline, then a second copy. The second copy does not reuse the first.
define void @nest(ptr addrspace(200) %pa, ptr addrspace(200) %pb) addrspace(200) {
; EX-LABEL: define void @nest(
; EX: store ptr addrspace(200) %pa, ptr addrspace(200) %sa{{.*}}!mem.loan [[P]]
; EX: [ "mem.last_use"(i64 4398046511107) ]
; EX: store ptr addrspace(200) %pb, ptr addrspace(200) %sb{{.*}}!mem.loan [[E]]
; EX: [ "mem.last_use.ext"(i64 3, i64 1) ]
; INV-LABEL: define void @nest(
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV: ret void
;
  %sa = alloca ptr addrspace(200), align 16, addrspace(200)
  %sb = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @mid(ptr addrspace(200) %sa, ptr addrspace(200) %pa)
  call void @mid(ptr addrspace(200) %sb, ptr addrspace(200) %pb)
  ret void
}

define internal void @already(ptr addrspace(200) %slot, ptr addrspace(200) %cap) alwaysinline {
  store ptr addrspace(200) %cap, ptr addrspace(200) %slot, align 16, !mem.loan !2
  call void @llvm.mem.fact() [ "mem.last_use.ext"(i64 3, i64 4) ]
  ret void
}

; The caller already holds the only packed key and this extended copy.
; The inlined copy is a different disambiguator. Its last-use clears only
; its own slot.
define void @live(ptr addrspace(200) %cap, ptr addrspace(200) %ocap) addrspace(200) {
; EX-LABEL: define void @live(
; EX: store ptr addrspace(200) %cap, ptr addrspace(200) %slot{{.*}}!mem.loan [[P]]
; EX: store ptr addrspace(200) %cap, ptr addrspace(200) %also{{.*}}!mem.loan [[OLD:![0-9]+]]
; EX: store ptr addrspace(200) %ocap, ptr addrspace(200) %other{{.*}}!mem.loan [[E]]
; EX: [ "mem.last_use.ext"(i64 3, i64 1) ]
; INV-LABEL: define void @live(
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %slot
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %also
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %other
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %slot
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %also
; INV: ret void
;
  %slot = alloca ptr addrspace(200), align 16, addrspace(200)
  %also = alloca ptr addrspace(200), align 16, addrspace(200)
  %other = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %cap, ptr addrspace(200) %slot, align 16, !mem.loan !1
  store ptr addrspace(200) %cap, ptr addrspace(200) %also, align 16, !mem.loan !2
  call void @already(ptr addrspace(200) %other, ptr addrspace(200) %ocap)
  ret void
}

define void @ext_yes(ptr addrspace(200) %p) addrspace(200) {
; EX-LABEL: define void @ext_yes(
; EX: store ptr addrspace(200) %p, ptr addrspace(200) %r{{.*}}!mem.loan [[YES:![0-9]+]]
; EX: load i32, ptr addrspace(200) %p{{.*}}!mem.last_use [[YES]]
; INV-LABEL: define void @ext_yes(
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %r
;
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !3
  %v = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !3
  ret void
}

define void @ext_no(ptr addrspace(200) %p) addrspace(200) {
; EX-LABEL: define void @ext_no(
; EX: store ptr addrspace(200) %p, ptr addrspace(200) %r{{.*}}!mem.loan [[OLD]]
; EX: load i32, ptr addrspace(200) %p{{.*}}!mem.last_use [[NO:![0-9]+]]
; INV-LABEL: define void @ext_no(
; INV-NOT: store volatile
; INV: ret void
;
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %p, ptr addrspace(200) %r, align 16, !mem.loan !2
  %v = load i32, ptr addrspace(200) %p, align 4, !mem.last_use !4
  ret void
}

; EX-DAG: [[P]] = !{i64 4398046511107}
; EX-DAG: [[E]] = !{[[EP:![0-9]+]]}
; EX-DAG: [[EP]] = !{!"mem.loan.ext", i64 3, i64 1}
; EX-DAG: [[OLD]] = !{[[OP:![0-9]+]]}
; EX-DAG: [[OP]] = !{!"mem.loan.ext", i64 3, i64 4}
; EX-DAG: [[YES]] = !{[[YP:![0-9]+]]}
; EX-DAG: [[YP]] = !{!"mem.loan.ext", i64 5, i64 9}
; EX-DAG: [[NO]] = !{[[NP:![0-9]+]]}
; EX-DAG: [[NP]] = !{!"mem.loan.ext", i64 5, i64 1}

!0 = !{i64 3}
!1 = !{i64 4398046511107}
!2 = !{!{!"mem.loan.ext", i64 3, i64 4}}
!3 = !{!{!"mem.loan.ext", i64 5, i64 9}}
!4 = !{!{!"mem.loan.ext", i64 5, i64 1}}
