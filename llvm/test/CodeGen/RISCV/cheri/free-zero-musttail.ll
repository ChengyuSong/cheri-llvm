; [LLM-generated] M7.1c. A musttail free site stays a tail call. Lowering rejects
; a musttail that is not a tail call, and nothing can be placed after it, so
; there is no demotion and no register zero.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s
; RUN: rm -f %t.stats && llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target triple = "riscv64-unknown-unknown"
target datalayout = "e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @drop_vec(ptr addrspace(200)) addrspace(200)

define void @drop_must(ptr addrspace(200) %p) addrspace(200) {
  musttail call void @drop_vec(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: drop_must:
; CHECK: ctail drop_vec
; CHECK-NOT: cmove
; CHECK-NOT: ccall drop_vec

; STATS-NOT: cheri-free-zero:
