; [LLM-generated] M7.1c. A tail call into a free never returns, so a zero after
; the call would not run. The free site is turned back into a normal call
; and the caller-saved caps are cleared before the return. musttail is left
; alone: lowering rejects a musttail that is not actually a tail call.
;
; rustc riscv64 purecap datalayout:
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s
; RUN: rm -f %t.stats && llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target triple = "riscv64-unknown-unknown"
target datalayout = "e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @drop_vec(ptr addrspace(200)) addrspace(200)
declare void @rawvec_dealloc(ptr addrspace(200)) addrspace(200)

define void @drop_string(ptr addrspace(200) %p) addrspace(200) {
  tail call void @drop_vec(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: drop_string:
; CHECK: ccall drop_vec
; CHECK-NEXT: cmove t0, zero
; CHECK: cmove a0, zero
; CHECK: cmove a7, zero
; CHECK: cret
; CHECK-NOT: tail drop_vec

define void @drop_string_raw(ptr addrspace(200) %p) addrspace(200) {
  tail call void @rawvec_dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: drop_string_raw:
; CHECK: ccall rawvec_dealloc
; CHECK-NEXT: cmove t0, zero
; CHECK: cret

; STATS: cheri-free-zero: fn=drop_string sites=1 regs=15
; STATS: cheri-free-zero: fn=drop_string_raw sites=1 regs=15
