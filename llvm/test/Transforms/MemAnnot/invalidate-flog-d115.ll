; [LLM-generated] D115: flogCalls emits one checkAndClear template per (call, slot)
; and runs it for K = 0 .. min(D, FLogCheck)-1. D == 0 still skips the bundle.
; D == 1 does not execute a Len=0 probe (no per-K select of 0). Ring wrap is
; the same mask as flogEnt. One shared loop covers every slot at the call.
;
; RUN: opt -S -passes=cheri-bounds-lowering -verify-each -cheri-invalidate=loan+free+flog -cheri-flog-checks=1 -cheri-flog-ring=8 < %s | FileCheck %s --check-prefixes=CHECK,C1
; RUN: opt -S -passes=cheri-bounds-lowering -verify-each -cheri-invalidate=loan+free+flog -cheri-flog-checks=2 -cheri-flog-ring=8 < %s | FileCheck %s --check-prefixes=CHECK,C2
; RUN: opt -S -passes=cheri-bounds-lowering -verify-each -cheri-invalidate=loan+free+flog -cheri-flog-checks=4 -cheri-flog-ring=8 < %s | FileCheck %s --check-prefixes=CHECK,C4
; RUN: opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free+flog -cheri-flog-checks=2 -cheri-flog-ring=8 -cheri-invalidate-stats-out=%t.s2 < %s
; RUN: FileCheck %s --check-prefix=STATS < %t.s2
; RUN: opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free+flog -cheri-flog-checks=4 -cheri-flog-ring=8 -cheri-invalidate-stats-out=%t.s4 < %s
; RUN: FileCheck %s --check-prefix=STATS < %t.s4
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @consume(ptr addrspace(200))

; One (call, slot). The template is inside the loop, so both log entries are
; visited when D = 2 (K = 0 then K = 1) and only the newest when D = 1.
define i64 @one(ptr addrspace(200) %p) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s, align 16
  call void @consume(ptr addrspace(200) %p)
  %q = load volatile ptr addrspace(200), ptr addrspace(200) %s, align 16
  %x = load i64, ptr addrspace(200) %q
  ret i64 %x
}
; CHECK-LABEL: define i64 @one(
; CHECK: load volatile i64, ptr addrspace(200) @__cheri_free_log{{[,)]}}
; CHECK: call {{.*}}void @consume(
; CHECK: %cheri.flog.d = sub i64
; CHECK: %cheri.flog.nz = icmp ne i64 %cheri.flog.d, 0
; CHECK: br i1 %cheri.flog.nz, label %cheri.flog.enter, label %[[SKIP:.*]]
; CHECK: cheri.flog.enter:
; C1: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 1)
; C2: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 2)
; C4: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 4)
; CHECK: %cheri.flog.ptr = getelementptr inbounds { i64, [16 x i64] }, ptr addrspace(200) @__cheri_free_log, i32 0, i32 1, i64 0
; CHECK: br label %cheri.flog.loop
; CHECK: cheri.flog.loop:
; CHECK: %cheri.flog.k = phi i64 [ 0, %cheri.flog.enter ], [ %cheri.flog.knext, %cheri.flog.loop ]
; CHECK: %cheri.flog.knext = add nuw i64 %cheri.flog.k, 1
; CHECK: %cheri.flog.idx = sub i64 {{.*}}, %cheri.flog.knext
; Ring wrap: slot = idx & (FLogN - 1), then the [base, len) pair. FLogN = 8.
; CHECK: %cheri.flog.slot = and i64 %cheri.flog.idx, 7
; CHECK: %cheri.flog.pair = shl nuw i64 %cheri.flog.slot, 1
; CHECK: %cheri.flog.lop = getelementptr inbounds i64, ptr addrspace(200) %cheri.flog.ptr, i64 %cheri.flog.pair
; CHECK: %cheri.flog.lo = load volatile i64, ptr addrspace(200) %cheri.flog.lop
; CHECK: %cheri.flog.len = load volatile i64, ptr addrspace(200) %cheri.flog.lenp
; CHECK-NOT: select {{.*}} i64
; One template. The Len=0 select of the unrolled K copy is gone; the trip
; count is min(D, FLogCheck), so D = 1 never enters a second probe.
; CHECK: %cheri.inv.cap = load ptr addrspace(200), ptr addrspace(200) %s, align 16
; CHECK: @llvm.cheri.cap.tag.clear
; CHECK: store ptr addrspace(200) {{.*}}, ptr addrspace(200) %s, align 16, !pcsections ![[FREE:.*]]
; CHECK-NOT: @llvm.cheri.cap.tag.clear
; CHECK-NOT: %cheri.inv.cap
; CHECK: %cheri.flog.more = icmp ult i64 %cheri.flog.knext, %cheri.flog.bound
; CHECK: br i1 %cheri.flog.more, label %cheri.flog.loop, label %[[SKIP]], !llvm.loop
; CHECK: [[SKIP]]:
; CHECK: ret i64
; CHECK-NOT: icmp ugt i64 %cheri.flog.d

; Two slots at one call share that loop: one bound, one phi, two templates.
define i64 @two(ptr addrspace(200) %p, ptr addrspace(200) %q) {
  %s0 = alloca ptr addrspace(200), align 16, addrspace(200)
  %s1 = alloca ptr addrspace(200), align 16, addrspace(200)
  store volatile ptr addrspace(200) %p, ptr addrspace(200) %s0, align 16
  store volatile ptr addrspace(200) %q, ptr addrspace(200) %s1, align 16
  call void @consume(ptr addrspace(200) %p)
  %a = load volatile ptr addrspace(200), ptr addrspace(200) %s0, align 16
  %b = load volatile ptr addrspace(200), ptr addrspace(200) %s1, align 16
  %x = load i64, ptr addrspace(200) %a
  %y = load i64, ptr addrspace(200) %b
  %z = add i64 %x, %y
  ret i64 %z
}
; CHECK-LABEL: define i64 @two(
; CHECK: %cheri.flog.nz = icmp ne i64 %cheri.flog.d, 0
; CHECK: br i1 %cheri.flog.nz, label %cheri.flog.enter, label %
; C1: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 1)
; C2: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 2)
; C4: call {{.*}}@llvm.umin.i64(i64 %cheri.flog.d, i64 4)
; CHECK-NOT: @llvm.umin.i64
; CHECK: %cheri.flog.k = phi i64 [ 0, %cheri.flog.enter ], [ %cheri.flog.knext, %cheri.flog.loop ]
; CHECK: load ptr addrspace(200), ptr addrspace(200) %s0, align 16
; CHECK: @llvm.cheri.cap.tag.clear
; CHECK: load ptr addrspace(200), ptr addrspace(200) %s1, align 16
; CHECK: @llvm.cheri.cap.tag.clear
; CHECK: %cheri.flog.more = icmp ult i64 %cheri.flog.knext, %cheri.flog.bound
; CHECK-NOT: phi i64
; CHECK-NOT: @llvm.cheri.cap.tag.clear
; CHECK: ret i64

; CHECK: ![[FREE]] = !{!"cheri_inv_free"}
; CHECK: !"llvm.loop.unroll.disable"

; range_checks counts templates, so checks=2 and checks=4 match.
; @one contributes 1, @two contributes 2. One loop per call.
; STATS: range_checks=3
; STATS: flog_calls=2
; STATS: flog_loops=2
