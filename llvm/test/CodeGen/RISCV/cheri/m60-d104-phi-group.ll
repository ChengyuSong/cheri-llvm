; [LLM-generated] M6.1 D104. The last use of a local stack cap may be a PHI
; in the middle of the PHI group. The invalidate goes after every PHI, and
; a second lifetime.end of the same value does not emit another one.
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))
declare void @later() addrspace(200)

define i64 @phi_group(i1 %c) addrspace(200) {
; CHECK-LABEL: define i64 @phi_group(
; CHECK: phi ptr addrspace(200)
; CHECK: phi i64
; CHECK: phi i64
; CHECK-NOT: phi
; CHECK: call {{.*}}@llvm.cheri.cap.invalidate(ptr addrspace(200) %a, i32 2)
; CHECK-NOT: @llvm.cheri.cap.invalidate
; CHECK: call {{.*}}@llvm.lifetime.end
entry:
  %a = alloca i8, align 16, addrspace(200)
  br i1 %c, label %left, label %join
left:
  br label %join
join:
  %p = phi ptr addrspace(200) [ %a, %entry ], [ %a, %left ]
  %n = phi i64 [ 0, %entry ], [ 1, %left ]
  %m = phi i64 [ 2, %entry ], [ 3, %left ]
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @llvm.lifetime.end.p200(i64 1, ptr addrspace(200) %a)
  call void @later()
  ret i64 %m
}
