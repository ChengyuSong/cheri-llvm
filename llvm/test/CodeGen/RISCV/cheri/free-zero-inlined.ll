; [LLM-generated] M7.1c. A global allocator inlined into __rust_dealloc (and
; then into its caller) has no call to __rust_dealloc left. The wipe helper
; is not the end of the free: dead caller-saved caps are cleared after the
; free-list store that follows it.
;
; RUN: opt -S -passes=inline < %s | llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 | FileCheck %s
; RUN: sed 's/^target datalayout = .*/target datalayout = "e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"/' %s | opt -S -passes=inline | llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 | FileCheck %s
; RUN: rm -f %t.stats && opt -S -passes=inline < %s | llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target triple = "riscv64-unknown-unknown"
target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@free_head = external addrspace(200) global ptr addrspace(200)

declare void @wipe(ptr addrspace(200), i64) addrspace(200)

define void @GlobalAlloc_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) addrspace(200) alwaysinline {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %slot = getelementptr i8, ptr addrspace(200) %p, i64 %i
  store i8 0, ptr addrspace(200) %slot
  %inc = add i64 %i, 1
  %cmp = icmp ult i64 %inc, %n
  br i1 %cmp, label %loop, label %link
link:
  call void @wipe(ptr addrspace(200) %p, i64 %n)
  %next = load ptr addrspace(200), ptr addrspace(200) %p
  store ptr addrspace(200) %next, ptr addrspace(200) @free_head
  ret void
}

define void @__rust_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) addrspace(200) alwaysinline {
  call void @GlobalAlloc_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a)
  ret void
}

define void @user(ptr addrspace(200) %p) addrspace(200) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 32, i64 8) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; The helper returns, then the free-list store, then the caller-saved zeros.
; The full clear (t0 first) is not between the helper and that store.
; CHECK-LABEL: user:
; CHECK: ccall wipe
; CHECK-NOT: cmove t0, zero
; CHECK: %got_pcrel_hi(free_head)
; CHECK: csc {{.*}}, 0(
; CHECK-NEXT: cmove t0, zero
; CHECK: cmove a0, zero
; CHECK: cmove a7, zero
; CHECK: cret

; STATS: cheri-free-zero: fn=user sites=1 regs=15
