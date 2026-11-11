; [LLM-generated] M7.1c. After a "mem.free" call, dead caller-saved capability
; registers (ct0-ct6, ca0-ca7) are set to cnull. A returned pointer stays in
; ca0. -cheri-free-zero-regs=off emits no such cmoves.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-free-zero-regs=off < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @__rust_dealloc(ptr addrspace(200), i64) addrspace(200)
declare ptr addrspace(200) @__rust_realloc(ptr addrspace(200), i64, i64, i64) addrspace(200)

define void @drop(ptr addrspace(200) %p) addrspace(200) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 16) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: drop:
; CHECK: ccall __rust_dealloc
; CHECK-NEXT: cmove t0, zero
; CHECK: cmove a0, zero
; CHECK: cmove a7, zero
; CHECK: cret
; OFF-LABEL: drop:
; OFF: ccall __rust_dealloc
; OFF-NOT: cmove t0, zero
; OFF: cret

define ptr addrspace(200) @grow(ptr addrspace(200) %p, i64 %n) addrspace(200) {
  %q = call ptr addrspace(200) @__rust_realloc(ptr addrspace(200) %p, i64 %n, i64 1, i64 32) [ "mem.free"(ptr addrspace(200) %p) ]
  ret ptr addrspace(200) %q
}
; The result stays in ca0. The other caller-saved caps are cleared.
; CHECK-LABEL: grow:
; CHECK: ccall __rust_realloc
; CHECK-NEXT: cmove t0, zero
; CHECK: cmove a1, zero
; CHECK-NOT: cmove a0, zero
; CHECK: cret

; STATS: cheri-free-zero: fn=drop sites=1 regs=15
; STATS: cheri-free-zero: fn=grow sites=1 regs=14
