; [LLM-generated] M5r R0/R1: annotations survive the default O2/O3 pipelines
; (census strict mode fails on any unexplained loss of a check/claim/free).
; RUN: opt -S -mem-annot-census -mem-annot-census-strict \
; RUN:   -passes='default<O2>,mem-annot-census-late' < %s 2>%t.o2 | FileCheck %s
; RUN: FileCheck %s --check-prefix=CENSUS < %t.o2
; RUN: opt -S -mem-annot-census -mem-annot-census-strict \
; RUN:   -passes='default<O3>,mem-annot-census-late' < %s 2>%t.o3 | FileCheck %s
; RUN: FileCheck %s --check-prefix=CENSUS < %t.o3
; Without -mem-annot-census the start census is not in the pipeline.
; RUN: opt -disable-output -passes='default<O2>' -print-pipeline-passes < %s | FileCheck %s --check-prefix=NOCENSUS

target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"

declare void @llvm.mem.fact()
declare void @panic_bounds_check(i64, i64) noreturn cold nounwind
declare void @dealloc(ptr)

define internal i32 @get(ptr "mem.untrusted" dereferenceable(64) %s, i64 %i) {
  %c = icmp ult i64 %i, 16
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr %s, i64 %i, !mem.guard !0
  %v = load i32, ptr %g, !mem.guard !0
  ret i32 %v
fail:
  call void @panic_bounds_check(i64 %i, i64 16) [ "mem.check"(ptr %s, i64 16, i64 4, i64 1, i64 0) ]
  unreachable
}

define i32 @sum(ptr %s, i64 %n) {
entry:
  %e = icmp eq i64 %n, 0
  br i1 %e, label %exit, label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %acc = phi i32 [ 0, %entry ], [ %acc1, %loop ]
  %v = call i32 @get(ptr %s, i64 %i)
  %acc1 = add i32 %acc, %v
  %i1 = add nuw i64 %i, 1
  %c = icmp ult i64 %i1, %n
  br i1 %c, label %loop, label %exit
exit:
  %r = phi i32 [ 0, %entry ], [ %acc1, %loop ]
  call void @dealloc(ptr %s) [ "mem.free"(ptr %s) ]
  ret i32 %r
}

; Constant in-bounds index: the check is proven dead and folds away
; (census: block-deleted, which is the explained "proven dead" case).
define i32 @const(ptr %s) {
  %v = call i32 @get(ptr %s, i64 3)
  ret i32 %v
}

!0 = !{i64 1}

; CHECK-LABEL: define {{.*}}i32 @sum(
; CHECK: [[C:%.*]] = {{.*}}call ptr @llvm.mem.claim.p0(ptr %s, i64 64, i64 265)
; CHECK: load i32, ptr {{%.*}}
; CHECK: call void @panic_bounds_check({{.*}}) {{.*}}[ "mem.check"(ptr [[C]], i64 16, i64 4, i64 1, i64 0) ]
; CHECK: call void @dealloc(ptr %s) [ "mem.free"(ptr %s) ]
; CHECK-LABEL: define {{.*}}i32 @const(
; CHECK-NOT: mem.check
; CHECK: ret i32

; CENSUS: mem-annot-census: {{.*}} start: check=1 guard=2 claim=0 alloc_inbounds=0 inbounds=0 free=1 last_use=0 dropped=0
; CENSUS: mem-annot-census: {{.*}} late: check=1
; CENSUS: lost:
; CENSUS-NOT: unexplained loss

; CHECK-NOT: !mem.annot.id
; CHECK: attributes #{{[0-9]+}} = { {{.*}}memory(argmem: read) }

; NOCENSUS-NOT: mem-annot-census
