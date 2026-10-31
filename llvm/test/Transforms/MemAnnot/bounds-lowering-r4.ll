; [LLM-generated] M5r R4: one tag test for two-version sites (D22), split of a
; panic block shared by several checks (D26), adoption of a guard whose own
; check was proved away against another site's compare (D26).
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=elide < %s | FileCheck %s --check-prefix=ELIDE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub < %s | FileCheck %s --check-prefix=UB
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-split-merged=false -cheri-bounds-adopt=false < %s | FileCheck %s --check-prefix=LEGACY
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @panic(i64, i64) noreturn cold

; Two checks of one slice share a panic block (operands are PHIs). Split, both
; are removed under ub and the panic block disappears.
define i32 @shared_panic(ptr addrspace(200) %a, i64 %n, i64 %i, i64 %j) {
entry:
  %c1 = icmp ult i64 %i, %n
  br i1 %c1, label %ok1, label %fail
ok1:
  %g1 = getelementptr inbounds i32, ptr addrspace(200) %a, i64 %i, !mem.guard !0
  %v1 = load i32, ptr addrspace(200) %g1, align 4
  %c2 = icmp ult i64 %j, %n
  br i1 %c2, label %ok2, label %fail
ok2:
  %g2 = getelementptr inbounds i32, ptr addrspace(200) %a, i64 %j, !mem.guard !1
  %v2 = load i32, ptr addrspace(200) %g2, align 4
  %r = add i32 %v1, %v2
  ret i32 %r
fail:
  %idx = phi i64 [ %i, %entry ], [ %j, %ok1 ]
  %site = phi i64 [ 1, %entry ], [ 2, %ok1 ]
  call addrspace(200) void @panic(i64 %idx, i64 %n) [ "mem.check"(ptr addrspace(200) %a, i64 %n, i64 4, i64 %site, i64 0) ]
  unreachable
}
; UB-LABEL: define i32 @shared_panic(
; UB-NOT:     icmp
; UB:         call addrspace(200) ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %a,
; UB-NOT:     @panic
; UB:         ret i32
; LEGACY-LABEL: define i32 @shared_panic(
; LEGACY:       icmp ult i64 %i, %n
; LEGACY:       icmp ult i64 %j, %n
; LEGACY:       call addrspace(200) void @panic(
; ELIDE-LABEL: define i32 @shared_panic(
; ELIDE:         cheri.cap.tag.get
; ELIDE-NOT:     select
; ELIDE:         cheri.cap.tag.get
; ELIDE:         cheri.slowcheck:
; ELIDE:         call addrspace(200) void @panic(

; GVN made a[i^1]'s compare stand for a[i] too and deleted a[i]'s marker; the
; a[i] guard (site 8) is adopted by site 7's marker (index %i, esz 8).
define i64 @local_array(i64 %i, i64 %x) {
start:
  %a = alloca [64 x i8], align 8, addrspace(200)
  store i64 %x, ptr addrspace(200) %a, align 8
  %c = icmp ult i64 %i, 8
  br i1 %c, label %bb1, label %panic
bb1:
  %g = getelementptr inbounds nuw [8 x i8], ptr addrspace(200) %a, i64 %i, !mem.guard !3
  %v = load i64, ptr addrspace(200) %g, align 8
  ret i64 %v
panic:
  %k = xor i64 %i, 1
  call addrspace(200) void @panic(i64 %k, i64 8) [ "mem.check"(ptr addrspace(200) %a, i64 8, i64 8, i64 7, i64 0) ]
  unreachable
}
; ELIDE-LABEL: define i64 @local_array(
; ELIDE-NOT:     icmp
; ELIDE:         [[N:%.*]] = call addrspace(200) ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %a, i64 64)
; ELIDE:         getelementptr [8 x i8], ptr addrspace(200) [[N]], i64 %i
; ELIDE-NOT:     @panic
; ELIDE:         ret i64
; LEGACY-LABEL: define i64 @local_array(
; LEGACY:       icmp ult i64 %i, 8
; LEGACY:       call addrspace(200) void @panic(

; STATS: split=2 adopted=1

!0 = !{i64 1}
!1 = !{i64 2}
!3 = !{i64 8}
