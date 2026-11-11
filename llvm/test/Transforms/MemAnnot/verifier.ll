; [LLM-generated] M5r R0/R1: verifier rules for the memory-annotation vocabulary.
; RUN: split-file %s %t
; RUN: opt -passes=verify -disable-output %t/good.ll
; RUN: not opt -passes=verify -disable-output %t/bad.ll 2>&1 | FileCheck %s

;--- good.ll
declare void @llvm.mem.fact()
declare ptr @llvm.mem.claim.p0(ptr, i64, i64 immarg)
declare void @panic(i64, i64)
declare void @free(ptr)
declare void @use(ptr)

define void @good(ptr %p, ptr %q, i64 %n, i64 %i) {
  %c = call ptr @llvm.mem.claim.p0(ptr %p, i64 16, i64 257)
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %q, ptr %p, i64 %n) ]
  call void @llvm.mem.fact() [ "mem.dropped"(ptr poison) ]
  %g = getelementptr inbounds i32, ptr %c, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0, !mem.last_use !1
  store i32 %v, ptr %q, !mem.last_use !2
  call void @use(ptr %q), !mem.last_use !1
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %p, i64 %n, i64 4, i64 7, i64 0) ]
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %q, i64 %n, i64 4, i64 8, i64 1, ptr %p, i64 %n) ]
  call void @free(ptr %p) [ "mem.free"(ptr %p) ]
  ; R9 (D67): an inlined deallocator's free is kept on llvm.mem.fact.
  call void @llvm.mem.fact() [ "mem.free"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.move"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr %p, ptr %q, i64 3) ]
  call void @llvm.mem.fact() [ "mem.loan_into.promoted"(ptr poison, ptr %q, i64 3) ]
  ret void
}
!0 = !{i64 7}
!1 = !{i64 3}
!2 = !{i64 4, i64 5}

;--- bad.ll
declare void @llvm.mem.fact()
declare void @panic(i64, i64)
declare void @free(ptr)

define void @bad(ptr %p, i64 %n, i64 %i) {
; CHECK: llvm.mem.fact must carry exactly one fact bundle
  call void @llvm.mem.fact()
; CHECK: "mem.claim" is not a fact bundle; use the value-returning llvm.mem.claim intrinsic
  call void @llvm.mem.fact() [ "mem.claim"(ptr %p, i64 16, i64 0) ]
; CHECK: "mem.alloc_inbounds" must be (ptr)
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(i64 %n) ]
; CHECK: "mem.inbounds" must be (ptr, ptr base, iN bytes)
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %p, i64 %n) ]
; CHECK: unknown "mem." bundle tag
  call void @llvm.mem.fact() [ "mem.invalidate"(ptr %p, i64 0) ]
; CHECK: unknown "mem." bundle tag
  call void @llvm.mem.fact() [ "mem.bogus"(ptr %p) ]
; CHECK: llvm.mem.fact may only carry "mem." bundles
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p), "deopt"() ]
; CHECK: "mem.check" belongs on a check's failure call, not on llvm.mem.fact
  call void @llvm.mem.fact() [ "mem.check"(ptr %p, i64 %n, i64 4, i64 1, i64 0) ]
; CHECK: "mem." fact bundles may only appear on llvm.mem.fact
  call void @panic(i64 %i, i64 %n) [ "mem.alloc_inbounds"(ptr %p) ]
; CHECK: "mem.free" bundle must be (ptr base)
  call void @free(ptr %p) [ "mem.free"(ptr %p, ptr null) ]
; CHECK: "mem.check" bundle must be (ptr base, iN len, iN elemsize, i64 site, i64 kind [, ptr parent, iN parentlen])
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %p, i64 %n, i64 4) ]
; CHECK: !mem.guard only on getelementptr, load, store or mem intrinsics
  %a = add i64 %i, 1, !mem.guard !0
; CHECK: !mem.guard must be !{i64 site}
  %g = getelementptr i8, ptr %p, i64 %i, !mem.guard !1
; CHECK: !mem.last_use only on load, store, atomic or call instructions
  %b = add i64 %i, 2, !mem.last_use !0
; CHECK: !mem.last_use must be a non-empty list of packed i64 loan ids or !{!"mem.loan.ext", i64 orig, i64 disambiguator} copies
  %v = load i8, ptr %p, !mem.last_use !1
; CHECK: !mem.last_use must be a non-empty list of packed i64 loan ids or !{!"mem.loan.ext", i64 orig, i64 disambiguator} copies
  %w = load i8, ptr %p, !mem.last_use !2
; CHECK: "mem.move" bundle must be (ptr slot) on llvm.mem.fact
  call void @llvm.mem.fact() [ "mem.move"(i64 %n) ]
; CHECK: "mem.move" bundle must be (ptr slot) on llvm.mem.fact
  call void @free(ptr %p) [ "mem.move"(ptr %p) ]
; CHECK: "mem.loan_into" bundle must be (ptr slot, ptr loan, i64 id) on llvm.mem.fact
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr %p, ptr %p) ]
; CHECK: "mem.loan_into" bundle must be (ptr slot, ptr loan, i64 id) on llvm.mem.fact
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr %p, i64 %n, i64 1) ]
; CHECK: "mem.loan_into" bundle must be (ptr slot, ptr loan, i64 id) on llvm.mem.fact
  call void @free(ptr %p) [ "mem.loan_into"(ptr %p, ptr %p, i64 1) ]
  ret void
}
!0 = !{i64 7}
!1 = !{!"x"}
!2 = !{}
