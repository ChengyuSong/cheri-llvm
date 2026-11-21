; [LLM-generated] M7.2e determinism: the salt that re-keys an inlined copy's loan
; ids comes from the caller's name and a per-caller inline count
; (!mem.inline.seq), not from a process-wide counter. So a caller's ids do not
; depend on what was inlined elsewhere before it (in rustc, on other threads):
; @b gets the same ids with or without @a in the module.
;
; RUN: opt -S -passes=inline < %s | FileCheck %s --check-prefixes=CHECK,BOTH
; RUN: llvm-extract -S -func=b -func=inner < %s | opt -S -passes=inline | FileCheck %s --check-prefix=BOTH

declare void @llvm.mem.fact()

define internal void @inner(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !0
  call void @llvm.mem.fact() [ "mem.last_use"(i64 3) ]
  ret void
}

; Two copies in one caller: count 1 and 2, two different ids.
define void @a(ptr %p, ptr %q) {
; CHECK-LABEL: define void @a(
; CHECK-SAME: !mem.inline.seq [[SEQA:![0-9]+]]
; CHECK: "mem.last_use"(i64 [[A1:[0-9]+]])
; CHECK-NOT: "mem.last_use"(i64 [[A1]])
; CHECK: "mem.last_use"(i64 {{[0-9]+}})
  %s1 = alloca ptr, align 8
  %s2 = alloca ptr, align 8
  call void @inner(ptr %s1, ptr %p)
  call void @inner(ptr %s2, ptr %q)
  ret void
}

define void @b(ptr %p) {
; BOTH-LABEL: define void @b(
; BOTH-SAME: !mem.inline.seq [[SEQB:![0-9]+]]
; BOTH: "mem.last_use"(i64 3305096768722567171)
  %s = alloca ptr, align 8
  call void @inner(ptr %s, ptr %p)
  ret void
}

!0 = !{i64 3}
; CHECK-DAG: [[SEQA]] = !{i64 2}
; BOTH-DAG: [[SEQB]] = !{i64 1}
