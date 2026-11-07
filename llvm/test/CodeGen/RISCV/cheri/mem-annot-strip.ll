; [LLM-generated] M5r R0/R1: the CheriBoundsLowering stub (before
; CheriBoundAllocas and LSR) strips
; every M5r annotation, so annotated IR and plain IR give identical code
; (also through CheriBoundAllocas, which now runs after the stub).
; The identity diffs pass -cheri-invalidate=none. Default mode includes
; aflog (D83), which emits a free log the plain file does not have, so
; those diffs check the strip itself.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -cheri-invalidate=none -O2 < %s > %t.annot.s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -cheri-invalidate=none -O2 < %S/Inputs/mem-annot-plain.ll > %t.plain.s
; RUN: diff %t.plain.s %t.annot.s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -cheri-invalidate=none -O0 < %s > %t.annot0.s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -cheri-invalidate=none -O0 < %S/Inputs/mem-annot-plain.ll > %t.plain0.s
; RUN: diff %t.plain0.s %t.annot0.s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s
; CHECK-NOT: mem.fact
; CHECK-NOT: "mem.
; CHECK-NOT: !mem.guard
; CHECK-NOT: !mem.last_use
; CHECK-NOT: mem.claim

source_filename = "mem-annot"
target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()
declare void @use(ptr addrspace(200))
declare ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200), i64, i64 immarg)
declare void @free(ptr addrspace(200))
declare void @panic(i64) noreturn cold

define i32 @f(ptr addrspace(200) %s, i64 %n) addrspace(200) {
entry:
  %buf = alloca [4 x i32], align 4, addrspace(200)
  %sc = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %s, i64 64, i64 0)
  %bc = call ptr addrspace(200) @llvm.mem.claim.p200(ptr addrspace(200) %buf, i64 16, i64 0)
  store i32 1, ptr addrspace(200) %bc, align 4, !mem.guard !0
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %ok ]
  %acc = phi i32 [ 0, %entry ], [ %acc1, %ok ]
  %c = icmp ult i64 %i, 16
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr addrspace(200) %sc, i64 %i, !mem.guard !0
  %v = load i32, ptr addrspace(200) %g, align 4, !mem.guard !0
  %acc1 = add i32 %acc, %v
  %i1 = add nuw i64 %i, 1
  %e = icmp ult i64 %i1, %n
  br i1 %e, label %loop, label %exit
exit:
  %b = load i32, ptr addrspace(200) %buf, align 4, !mem.last_use !1
  %r = add i32 %acc1, %b
  call void @free(ptr addrspace(200) %s) [ "mem.free"(ptr addrspace(200) %s) ]
  ret i32 %r
fail:
  call void @panic(i64 %i) [ "mem.check"(ptr addrspace(200) %buf, i64 16, i64 4, i64 1, i64 0) ]
  unreachable
}

!0 = !{i64 1}
!1 = !{i64 2}
