; [LLM-generated] M5r R0: the CheriBoundsLowering stub strips every
; annotation (and values kept alive only by them) so codegen is unchanged.
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering %S/Inputs/strip-plain.ll -o %t.plain.ll
; RUN: opt -S -passes=cheri-bounds-lowering < %s | sed -e 's/^source_filename.*//' -e 's/^; ModuleID.*//' > %t.stripped.ll
; RUN: sed -e 's/^source_filename.*//' -e 's/^; ModuleID.*//' %t.plain.ll | diff - %t.stripped.ll

declare void @llvm.mem.fact()
declare void @sink(i64, ptr)
declare void @panic(i64) noreturn cold

define i32 @f(i1 %c, ptr %a, ptr %b, i64 %x, i64 %i) {
  call void @llvm.mem.fact() [ "mem.claim"(ptr %a, i64 16, i64 0) ]
  call void @llvm.mem.fact() [ "mem.free"(ptr %a, ptr %b) ]
  %gb = getelementptr i8, ptr %b, i64 8
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %gb, ptr %b, i64 16) ]
  call void @llvm.mem.fact() [ "mem.dropped"(ptr poison) ]
  %s = select i1 %c, ptr %a, ptr %b
  %k = select i1 %c, i64 11, i64 12
  call void @sink(i64 %x, ptr %a) [ "mem.check"(ptr %s, i64 4, i64 4, i64 %k, i64 0) ]
  %g = getelementptr inbounds i32, ptr %a, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0
  %ok = icmp ult i64 %i, 4
  br i1 %ok, label %ret, label %fail
ret:
  ret i32 %v
fail:
  call void @panic(i64 %i) [ "mem.check"(ptr %a, i64 4, i64 4, i64 1, i64 0) ]
  unreachable
}

!0 = !{i64 1}

; CHECK-NOT: mem.fact
; CHECK-NOT: "mem.
; CHECK-NOT: !mem.guard
; CHECK-NOT: select
; CHECK-NOT: %gb
