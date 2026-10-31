; [LLM-generated] M5r R4: a borrow check (Vec Index after inlining) whose
; borrow is only loaded in the Ok block, with no side effect before the load,
; is lowered like an access check (ub, or elide with an exact narrow; an
; elide Dynamic site keeps the cheaper compare). A call in between keeps it.
; RUN: rm -f %t.on %t.off
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-stats-out=%t.on < %s | FileCheck %s
; RUN: FileCheck %s --check-prefix=STATS < %t.on
; RUN: opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-bounds-borrow-deref=false -cheri-bounds-stats-out=%t.off < %s
; RUN: FileCheck %s --check-prefix=OFF < %t.off
; RUN: rm -f %t.el && opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=elide -cheri-bounds-stats-out=%t.el < %s
; RUN: FileCheck %s --check-prefix=ELIDE < %t.el
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()
declare void @llvm.trap()
declare void @side()

; CHECK-LABEL: @deref(
; CHECK: llvm.cheri.cap.bounds.set.exact
; CHECK-NOT: icmp
; CHECK: ok:
; CHECK-NOT: llvm.trap
; CHECK: ret i64
define i64 @deref(ptr addrspace(200) %v, i64 %i) addrspace(200) {
start:
  %p = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %lp = getelementptr inbounds nuw i8, ptr addrspace(200) %v, i64 32
  %len = load i64, ptr addrspace(200) %lp, align 16
  %c = icmp ult i64 %i, %len
  br i1 %c, label %ok, label %panic
ok:
  %g = getelementptr inbounds nuw [8 x i8], ptr addrspace(200) %p, i64 %i, !mem.guard !0
  %x = load i64, ptr addrspace(200) %g, align 8
  ret i64 %x
panic:
  call addrspace(200) void @llvm.trap() [ "mem.check"(ptr addrspace(200) %p, i64 %len, i64 8, i64 7, i64 256) ]
  unreachable
}

; CHECK-LABEL: @side_before(
; CHECK-NOT: llvm.cheri.cap
; CHECK: br i1 %c, label %ok, label %panic
; CHECK: call addrspace(200) void @side()
define i64 @side_before(ptr addrspace(200) %v, i64 %i) addrspace(200) {
start:
  %p = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %lp = getelementptr inbounds nuw i8, ptr addrspace(200) %v, i64 32
  %len = load i64, ptr addrspace(200) %lp, align 16
  %c = icmp ult i64 %i, %len
  br i1 %c, label %ok, label %panic
ok:
  %g = getelementptr inbounds nuw [8 x i8], ptr addrspace(200) %p, i64 %i, !mem.guard !1
  call addrspace(200) void @side()
  %x = load i64, ptr addrspace(200) %g, align 8
  ret i64 %x
panic:
  call addrspace(200) void @llvm.trap() [ "mem.check"(ptr addrspace(200) %p, i64 %len, i64 8, i64 8, i64 256) ]
  unreachable
}

!0 = !{i64 7}
!1 = !{i64 8}

; STATS: borrow=2 {{.*}}borrow_deref=1
; OFF: borrow=2 {{.*}}borrow_deref=0
; ELIDE: borrow=2 {{.*}}borrow_deref=0
