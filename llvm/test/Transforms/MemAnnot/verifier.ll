; [LLM-generated] M5r R0: verifier rules for the memory-annotation vocabulary.
; RUN: split-file %s %t
; RUN: opt -passes=verify -disable-output %t/good.ll
; RUN: not opt -passes=verify -disable-output %t/bad.ll 2>&1 | FileCheck %s

;--- good.ll
declare void @llvm.mem.fact()
declare void @panic(i64, i64)

define void @good(ptr %p, ptr %q, i64 %n, i64 %i) {
  call void @llvm.mem.fact() [ "mem.claim"(ptr %p, i64 16, i64 257) ]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %q, ptr %p, i64 %n) ]
  call void @llvm.mem.fact() [ "mem.free"(ptr %p, ptr null) ]
  call void @llvm.mem.fact() [ "mem.invalidate"(ptr %q, i64 0) ]
  call void @llvm.mem.fact() [ "mem.dropped"(ptr poison) ]
  %g = getelementptr inbounds i32, ptr %p, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %p, i64 %n, i64 4, i64 7, i64 0) ]
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %q, i64 %n, i64 4, i64 8, i64 1, ptr %p, i64 %n) ]
  ret void
}
!0 = !{i64 7}

;--- bad.ll
declare void @llvm.mem.fact()
declare void @panic(i64, i64)

define void @bad(ptr %p, i64 %n, i64 %i) {
; CHECK: llvm.mem.fact must carry exactly one fact bundle
  call void @llvm.mem.fact()
; CHECK: "mem.claim" must be (ptr, iN bytes, i64 flags)
  call void @llvm.mem.fact() [ "mem.claim"(ptr %p, i64 16) ]
; CHECK: "mem.claim" must be (ptr, iN bytes, i64 flags)
  call void @llvm.mem.fact() [ "mem.claim"(ptr %p, i64 16, i64 %n) ]
; CHECK: "mem.alloc_inbounds" must be (ptr)
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(i64 %n) ]
; CHECK: "mem.inbounds" must be (ptr, ptr base, iN bytes)
  call void @llvm.mem.fact() [ "mem.inbounds"(ptr %p, i64 %n) ]
; CHECK: "mem.free" must be (ptr, ptr ownerslot-or-null)
  call void @llvm.mem.fact() [ "mem.free"(ptr %p) ]
; CHECK: "mem.invalidate" must be (ptr, i64 kind)
  call void @llvm.mem.fact() [ "mem.invalidate"(ptr %p, i64 %n) ]
; CHECK: unknown "mem." bundle tag
  call void @llvm.mem.fact() [ "mem.bogus"(ptr %p) ]
; CHECK: llvm.mem.fact may only carry "mem." bundles
  call void @llvm.mem.fact() [ "mem.claim"(ptr %p, i64 1, i64 0), "deopt"() ]
; CHECK: "mem.check" belongs on a check's failure call, not on llvm.mem.fact
  call void @llvm.mem.fact() [ "mem.check"(ptr %p, i64 %n, i64 4, i64 1, i64 0) ]
; CHECK: "mem." fact bundles may only appear on llvm.mem.fact
  call void @panic(i64 %i, i64 %n) [ "mem.claim"(ptr %p, i64 1, i64 0) ]
; CHECK: "mem.check" bundle must be (ptr base, iN len, iN elemsize, i64 site, i64 kind [, ptr parent, iN parentlen])
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %p, i64 %n, i64 4) ]
; CHECK: !mem.guard only on getelementptr, load, store or mem intrinsics
  %a = add i64 %i, 1, !mem.guard !0
; CHECK: !mem.guard must be !{i64 site}
  %g = getelementptr i8, ptr %p, i64 %i, !mem.guard !1
  ret void
}
!0 = !{i64 7}
!1 = !{!"x"}
