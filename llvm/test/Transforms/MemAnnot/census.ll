; [LLM-generated] M5r R0: annotation census at pipeline start and late.
; RUN: opt -mem-annot-census -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=NOP
; RUN: opt -mem-annot-census -mem-annot-census-strict -disable-output \
; RUN:   -passes='mem-annot-census-start,simplifycfg,sroa,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=OPT
; RUN: not --crash opt -mem-annot-census -mem-annot-census-strict -mem-annot-census-test-erase -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=STRICT
; RUN: opt -mem-annot-census -mem-annot-census-test-erase -disable-output \
; RUN:   -passes='mem-annot-census-start,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=LOSS
; No annotations: silent unless verbose.
; RUN: opt -mem-annot-census -disable-output -passes='mem-annot-census-start,mem-annot-census-late' %S/Inputs/none.ll 2>&1 | count 0

declare void @llvm.mem.fact()
declare void @panic(i64, i64) noreturn cold

define i32 @f(ptr %s, i64 %n, i64 %i) {
  call void @llvm.mem.fact() [ "mem.claim"(ptr %s, i64 16, i64 0) ]
  call void @llvm.mem.fact() [ "mem.free"(ptr %s, ptr %s) ]
  %c = icmp ult i64 %i, %n
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr %s, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0
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

; Promoted local: the invalidate fact becomes mem.dropped.
define i32 @local() {
  %a = alloca i32
  store i32 1, ptr %a
  call void @llvm.mem.fact() [ "mem.invalidate"(ptr %a, i64 0) ]
  %v = load i32, ptr %a
  ret i32 %v
}

!0 = !{i64 1}

; NOP: start: check=2 guard=2 claim=1 alloc_inbounds=0 inbounds=0 free=1 invalidate=1
; NOP: late: check=2 guard=2 claim=1 alloc_inbounds=0 inbounds=0 free=1 invalidate=1
; NOP: lost: none
; OPT: start: check=2
; OPT: late: check=1
; OPT: lost:{{.*}}check{{.*}}block-deleted=1
; OPT-NOT: unexplained={{[1-9]}}
; STRICT: unexplained loss
; LOSS: lost:{{.*}}claim{{.*}}unexplained=1
