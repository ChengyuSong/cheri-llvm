; [LLM-generated] M6.2 D113. recoverConst already rewrites a const-index access
; that still sits in the check's immediate success block. The is_less shape
; leaves that load in a later block the success edge still dominates: Ok is
; only `icmp eq %lena, %lenb` / `br`, and `load i8, %base` is on the
; equal-length successor. Find that access, invent cheri.recovered, and keep
; the compare. Never narrow to the folded constant 0.
;
; The walk is the dominator subtree of Ok, and only blocks the success edge
; dominates (DominatorTree::dominates(Edge, BB)). Depth is the dominator-tree
; distance from Ok. It stops at depth 4 and after 8 blocks
; (RecovDomDepth / RecovDomBlocks in CheriBoundsLowering.cpp).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=narrow < %s | FileCheck %s
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=narrow -cheri-bounds-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @panic(i64, i64) noreturn cold

; (1) The load is two blocks below Ok. Both blocks are dominated by the
; success edge, so the access is recovered and the compare stays.
define i8 @two_below(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  br label %mid
mid:
  br label %acc
acc:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 1, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@two_below(
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %ptr, i64 0)
; CHECK: icmp eq i64 %len, 0
; CHECK: [[N2:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %ptr, i64 %len)
; CHECK: %cheri.recovered = getelementptr i8, ptr addrspace(200) [[N2]], i64 0
; CHECK: load i8, ptr addrspace(200) %cheri.recovered
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %ptr, i64 0)

; (2) The load is reachable from Ok, but the block is also reached from a
; path that never takes the success edge. The success edge does not dominate
; it, so it is not recovered and the folded 0 is not a narrow length.
define i8 @not_dominated(ptr addrspace(200) %ptr, i64 %len, i1 %fromside) {
entry:
  br i1 %fromside, label %side, label %check
check:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  br label %merge
side:
  br label %merge
merge:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 2, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@not_dominated(
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set
; CHECK: icmp eq i64 %len, 0
; CHECK: load i8, ptr addrspace(200) %ptr
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set

; (3) is_less pair, both lengths folded to 0. The first v[0] load is in that
; check's Ok (D112). The second Ok is only the length compare; its load is
; on the equal-length successor, dominated by the success edge. Both recover.
define i1 @is_less_pair(ptr addrspace(200) %a, ptr addrspace(200) %b, i64 %lena, i64 %lenb) {
entry:
  %eqa = icmp eq i64 %lena, 0
  br i1 %eqa, label %panica, label %oka
oka:
  %ba = load i8, ptr addrspace(200) %a, align 1
  %eqb = icmp eq i64 %lenb, 0
  br i1 %eqb, label %panicb, label %okb
okb:
  %same = icmp eq i64 %lena, %lenb
  br i1 %same, label %eqlen, label %neglen
eqlen:
  %bb = load i8, ptr addrspace(200) %b, align 1
  %cmp = icmp ult i8 %ba, %bb
  ret i1 %cmp
neglen:
  %lt = icmp ult i64 %lena, %lenb
  ret i1 %lt
panica:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %a, i64 0, i64 1, i64 3, i64 256) ]
  unreachable
panicb:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %b, i64 0, i64 1, i64 4, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@is_less_pair(
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %a, i64 0)
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %b, i64 0)
; CHECK: icmp eq i64 %lena, 0
; CHECK: [[NA:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %a, i64 %lena)
; CHECK: %cheri.recovered = getelementptr i8, ptr addrspace(200) [[NA]], i64 0
; CHECK: load i8, ptr addrspace(200) %cheri.recovered
; CHECK: icmp eq i64 %lenb, 0
; CHECK: icmp eq i64 %lena, %lenb
; CHECK: [[NB:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %b, i64 %lenb)
; CHECK: %cheri.recovered{{[0-9]*}} = getelementptr i8, ptr addrspace(200) [[NB]], i64 0
; CHECK: load i8, ptr addrspace(200) %cheri.recovered{{[0-9]*}}
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %a, i64 0)
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %b, i64 0)

; (4) The load is five dominator-tree steps below Ok, past RecovDomDepth (4).
; The walk stops before it, so there is no recovered guard and no narrow.
define i8 @past_budget(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  br label %d1
d1:
  br label %d2
d2:
  br label %d3
d3:
  br label %d4
d4:
  br label %d5
d5:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 5, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@past_budget(
; CHECK-NOT: cheri.recovered
; CHECK-NOT: call {{.*}}@llvm.cheri.cap.bounds.set
; CHECK: icmp eq i64 %len, 0
; CHECK: load i8, ptr addrspace(200) %ptr
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: cheri.recovered
; CHECK-NOT: call {{.*}}@llvm.cheri.cap.bounds.set

; STATS: markers=5 {{.*}}borrow=5 unlinked=2 guards=3 narrowed=3 {{.*}}twoversion=0 {{.*}}kept=3 {{.*}}recovered=3 recovered_markers=3
