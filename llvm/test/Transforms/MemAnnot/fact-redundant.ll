; [LLM-generated] M5r R1: InstCombine erases "mem.alloc_inbounds" facts that the
; allocation implies (stack/global object or constant in-range offset) and
; duplicates of an earlier identical fact in the block; the census reports
; them as "redundant". Facts on other pointers stay.
; RUN: opt -S -passes=instcombine < %s | FileCheck %s
; RUN: opt -mem-annot-census -mem-annot-census-strict -disable-output \
; RUN:   -passes='mem-annot-census-start,instcombine,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=CENSUS

@g = private unnamed_addr constant [4 x i8] c"0123", align 1
declare void @llvm.mem.fact()
declare void @use(ptr)

; CHECK-LABEL: @f(
; CHECK-NEXT: call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
; CHECK-NEXT: call void @use(ptr %p)
; CHECK-NEXT: call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr getelementptr inbounds nuw (i8, ptr @g, i64 8)) ]
; CHECK-NEXT: ret void
define void @f(ptr %p) {
  %a = alloca [16 x i8]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr @g) ]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr getelementptr inbounds (i8, ptr @g, i64 2)) ]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %a) ]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
  call void @use(ptr %p)
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr getelementptr inbounds (i8, ptr @g, i64 8)) ]
  ret void
}

; CENSUS: start: {{.*}} alloc_inbounds=6
; CENSUS: late: {{.*}} alloc_inbounds=2
; CENSUS: lost: alloc_inbounds=4(redundant=4)
