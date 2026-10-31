; [LLM-generated] M5r R0/R1: the CheriBoundsLowering stub strips every
; annotation (and values kept alive only by them) so codegen is unchanged.
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering %S/Inputs/strip-plain.ll -o %t.plain.ll
; RUN: opt -S -passes=cheri-bounds-lowering < %s | sed -e 's/^source_filename.*//' -e 's/^; ModuleID.*//' > %t.stripped.ll
; RUN: sed -e 's/^source_filename.*//' -e 's/^; ModuleID.*//' %t.plain.ll | diff - %t.stripped.ll

declare void @llvm.mem.fact()
declare ptr @llvm.mem.claim.p0(ptr, i64, i64 immarg)
declare void @free(ptr)
declare void @sink(i64, ptr)
declare void @panic(i64) noreturn cold

define i32 @f(i1 %c, ptr %a, ptr %b, i64 %x, i64 %i) {
  %ac = call ptr @llvm.mem.claim.p0(ptr %a, i64 16, i64 0)
  %gb = getelementptr i8, ptr %b, i64 8
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %gb, ptr %b, i64 16) ]
  call void @llvm.mem.fact() [ "mem.dropped"(ptr poison) ]
  %s = select i1 %c, ptr %a, ptr %b
  %k = select i1 %c, i64 11, i64 12
  call void @sink(i64 %x, ptr %ac) [ "mem.check"(ptr %s, i64 4, i64 4, i64 %k, i64 0) ]
  %g = getelementptr inbounds i32, ptr %ac, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0, !mem.last_use !1
  call void @free(ptr %b) [ "mem.free"(ptr %b) ]
  %ok = icmp ult i64 %i, 4
  br i1 %ok, label %ret, label %fail
ret:
  ret i32 %v
fail:
  call void @panic(i64 %i) [ "mem.check"(ptr %a, i64 4, i64 4, i64 1, i64 0) ]
  unreachable
}

!0 = !{i64 1}
!1 = !{i64 3}

; CHECK-NOT: mem.fact
; CHECK-NOT: "mem.
; CHECK-NOT: !mem.guard
; CHECK-NOT: !mem.last_use
; CHECK-NOT: mem.claim
; CHECK-NOT: select
; CHECK-NOT: %gb
