; [LLM-generated] M5r R0/R1: annotation census at pipeline start and late.
; RUN: opt -mem-annot-census -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=NOP
; RUN: opt -mem-annot-census -mem-annot-census-strict -disable-output \
; RUN:   -passes='mem-annot-census-start,simplifycfg,sroa,instcombine,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=OPT
; RUN: not --crash opt -mem-annot-census -mem-annot-census-strict -mem-annot-census-test-erase -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=STRICT
; RUN: opt -mem-annot-census -mem-annot-census-test-erase -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=LOSS
; No annotations: silent unless verbose.
; RUN: opt -mem-annot-census -disable-output -passes='mem-annot-census-start,mem-annot-census-late' %S/Inputs/none.ll 2>&1 | count 0

declare void @llvm.mem.fact()
declare ptr @llvm.mem.claim.p0(ptr, i64, i64 immarg)
declare void @panic(i64, i64) noreturn cold
declare void @free(ptr)

define i32 @f(ptr %s, i64 %n, i64 %i) {
  %sc = call ptr @llvm.mem.claim.p0(ptr %s, i64 16, i64 0)
  %c = icmp ult i64 %i, %n
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr %sc, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0, !mem.last_use !1
  call void @free(ptr %s) [ "mem.free"(ptr %s) ]
  ret i32 %v
fail:
  call void @panic(i64 %i, i64 %n) [ "mem.check"(ptr %s, i64 %n, i64 4, i64 1, i64 0) ]
  unreachable
}

; Dead check: the block is unreachable and SimplifyCFG deletes it.
define void @dead(ptr %s) {
  br i1 true, label %ok, label %fail
ok:
  ret void
fail:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr %s, i64 0, i64 4, i64 2, i64 0) ]
  unreachable
}

; Unused claim: deleted as trivially dead ("dead", not a loss).
define void @unused(ptr %s) {
  %sc = call ptr @llvm.mem.claim.p0(ptr %s, i64 8, i64 0)
  ret void
}

; Promoted local: the alloc_inbounds fact becomes mem.dropped; the claim on
; the slot is sliced through by SROA and dies with the slot.
define i32 @local() {
  %a = alloca i32
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %a) ]
  %ac = call ptr @llvm.mem.claim.p0(ptr %a, i64 4, i64 0)
  store i32 1, ptr %ac
  %v = load i32, ptr %a
  ret i32 %v
}

!0 = !{i64 1}
!1 = !{i64 9}

; NOP: start: check=2 guard=2 claim=3 alloc_inbounds=1 inbounds=0 free=1 last_use=1 dropped=0
; NOP: late: check=2 guard=2 claim=3 alloc_inbounds=1 inbounds=0 free=1 last_use=1 dropped=0
; NOP: lost: none
; OPT: start: check=2 guard=2 claim=3 alloc_inbounds=1 inbounds=0 free=1 last_use=1 dropped=0
; OPT: late: check=1 guard=2 claim=1 alloc_inbounds=0 inbounds=0 free=1 last_use=1 dropped=1
; OPT: lost: check=1(block-deleted=1) claim=2(dead=2) alloc_inbounds=1(dropped=1)
; OPT-NOT: unexplained
; STRICT: unexplained loss: claim #{{[0-9]+}} in f (folded into a non-claim value: ? -> argument)
; LOSS: lost:{{.*}}claim=1(unexplained=1)
