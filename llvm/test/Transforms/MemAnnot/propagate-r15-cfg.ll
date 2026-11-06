; [LLM-generated] M5r R15: last-use anchors must not leave a block without a
; terminator. SimplifyCFG's removeUnreachableBlocks calls getTerminator()
; after deleting a nounwind invoke. The replacement branch is inserted first;
; an anchor between that branch and the invoke used to become the end of the
; block.
;
; RUN: opt -disable-output -passes=simplifycfg -verify-each < %s
; RUN: opt -S -passes=simplifycfg < %s | FileCheck %s --check-prefix=SC
; RUN: opt -disable-output -passes='default<O1>' -verify-each < %s
; RUN: opt -disable-output -passes='default<O2>' -verify-each < %s
; RUN: opt -disable-output -passes='default<O3>' -verify-each < %s
; RUN: opt -S -passes='default<O2>' < %s | FileCheck %s --check-prefix=O2

declare i32 @pure() nounwind readnone willreturn
declare i32 @__gxx_personality_v0(...)

define void @invoke_lu() personality ptr @__gxx_personality_v0 {
; SC-LABEL: define void @invoke_lu(
; SC-NOT: invoke
; SC: call {{.*}}@llvm.mem.fact() [ "mem.last_use"(i64 7) ]
; SC-NEXT: ret void
; O2-LABEL: define {{.*}}@invoke_lu(
; O2: call {{.*}}@llvm.mem.fact() [ "mem.last_use"(i64 7) ]
; O2: ret void
;
  %v = invoke i32 @pure() to label %ok unwind label %lpad, !mem.last_use !0
ok:
  ret void
lpad:
  %lp = landingpad { ptr, i32 } cleanup
  ret void
}

; Unreachable block. Deleting it must not leave a non-terminator at the end.
; The loan end is dead with the block, so no anchor is required here.
define i32 @dead_block(ptr %p) {
; SC-LABEL: define i32 @dead_block(
; SC-NOT: mem.last_use
; SC: ret i32 0
;
  ret i32 0
dead:
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  ret i32 %v
}

define void @dead_invoke() personality ptr @__gxx_personality_v0 {
; SC-LABEL: define void @dead_invoke(
; SC-NOT: invoke
; SC: ret void
;
  ret void
dead:
  %v = invoke i32 @pure() to label %ok unwind label %lpad, !mem.last_use !0
ok:
  ret void
lpad:
  %lp = landingpad { ptr, i32 } cleanup
  ret void
}

!0 = !{i64 7}
