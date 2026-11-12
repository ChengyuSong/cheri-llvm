; [LLM-generated] M7.1c. rustc's riscv64 purecap datalayout uses pfe200, and
; DeadArgumentElimination rewrites the wipe call. The "not the free end"
; marker is a call-site attribute, so the helper stays out of the free-zero
; set and llvm.riscv.cheri.free.zero is still planted after the free-list
; store. default<O2> must keep both.
;
; rustc riscv64 purecap:
;   e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200
; The new PM parses "inline,deadargelim" as one cgscc pipeline and rejects
; deadargelim there. cgscc(inline) then the module pass is that pipeline.
; RUN: opt -S -passes='cgscc(inline),deadargelim' < %s | FileCheck %s --check-prefix=DAE
; RUN: opt -S -passes='default<O2>' < %s | FileCheck %s --check-prefix=O2
; RUN: opt -S -passes='default<O2>' < %s | llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 | FileCheck %s --check-prefix=ASM
; RUN: rm -f %t.stats && opt -S -passes='default<O2>' < %s | llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target triple = "riscv64-unknown-unknown"
target datalayout = "e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@free_head = external addrspace(200) global ptr addrspace(200)

; %unused is dead, so DeadArgumentElimination rewrites every call. The store
; keeps the call alive through O2, and noinline keeps it out of line.
define internal void @wipe(ptr addrspace(200) %p, i64 %n, i64 %unused) addrspace(200) noinline {
  store volatile i8 1, ptr addrspace(200) %p
  ret void
}

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
  call void @wipe(ptr addrspace(200) %p, i64 %n, i64 %a)
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

; DAE rewrote the call (the dead i64 is gone) and kept the attribute.
; DAE-LABEL: define void @user(
; DAE: call {{.*}}@wipe(ptr addrspace(200) %p) #[[INNER:[0-9]+]] [ "mem.free"(ptr addrspace(200) %p) ]
; DAE: store ptr addrspace(200) %next.i.i, ptr addrspace(200) @free_head
; DAE-NEXT: call {{.*}}@llvm.riscv.cheri.free.zero()
; DAE: attributes #[[INNER]] = { "cheri-free-inner" }
; DAE-NOT: !cheri.free.inner

; O2-LABEL: define void @user(
; O2: call {{.*}}@wipe({{.*}}) #[[O2INNER:[0-9]+]] [ "mem.free"(ptr addrspace(200) %p) ]
; O2: call {{.*}}@llvm.riscv.cheri.free.zero()
; O2: attributes #[[O2INNER]] = { "cheri-free-inner" }

; The full clear is after the free-list store, not after the helper.
; ASM-LABEL: user:
; ASM: ccall wipe
; ASM-NOT: cmove t0, zero
; ASM: %got_pcrel_hi(free_head)
; ASM: csc {{.*}}, 0(
; ASM-NEXT: cmove t0, zero
; ASM: cmove a7, zero
; ASM: cret

; STATS: cheri-free-zero: fn=user sites=1 regs=15
