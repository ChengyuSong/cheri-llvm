; [LLM-generated] M6.1 D98/D100. The dereferenced pointer is the bounded cap
; hoisted before the loop. It stays live across iterations, so the only
; dead point is the exit edge. D100 does not split that edge.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(i64, ptr addrspace(200))
declare void @llvm.lifetime.end.p200(i64, ptr addrspace(200))
declare i8 @check(ptr addrspace(200)) addrspace(200)

define i8 @bounded_loop(i64 %n) addrspace(200) {
; CHECK-LABEL: bounded_loop:
; CHECK: csetbounds [[B:s[0-9]+]], {{.*}}, 64
; CHECK: cincoffset {{[a-z0-9]+}}, [[B]],
; CHECK: ccall check
; CHECK-NOT: cmove [[B]], zero
start:
  %a = alloca [64 x i8], align 1, addrspace(200)
  %z = icmp eq i64 %n, 0
  br i1 %z, label %exit, label %body
body:
  %s = phi i8 [ 0, %start ], [ %s2, %body ]
  %i = phi i64 [ 0, %start ], [ %i1, %body ]
  call void @llvm.lifetime.start.p200(i64 64, ptr addrspace(200) %a)
  %p = getelementptr inbounds i8, ptr addrspace(200) %a, i64 %i
  %b = call i8 @check(ptr addrspace(200) %p)
  %s2 = add i8 %s, %b
  call void @llvm.lifetime.end.p200(i64 64, ptr addrspace(200) %a)
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %body, label %exit
exit:
  %r = phi i8 [ 0, %start ], [ %s2, %body ]
  ret i8 %r
}
