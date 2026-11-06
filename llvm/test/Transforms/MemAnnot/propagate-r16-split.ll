; [LLM-generated] M5r R16: one last-use fact that remaps to both a packed id and
; an extended id becomes two fact calls. Each id still clears only its slot.
; A flat !{i64, i64} and a tagged extended operand stay distinct in the census.
;
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 -verify-each < %s | FileCheck %s --check-prefix=SPLIT
; RUN: opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 < %s | opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -verify-each | FileCheck %s --check-prefix=INV
; RUN: opt -mem-annot-census -disable-output -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 -passes='mem-annot-census-start,inline,mem-annot-census-late' < %s 2>&1 | FileCheck %s --check-prefix=CENSUS
; RUN: opt -S -passes=dce -verify-each < %s | FileCheck %s --check-prefix=DCE

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"
target triple = "x86_64-unknown-linux-gnu"

declare void @llvm.mem.fact()

; Census keys before and after inlining. 3 and 5 are the flat list. 7 is
; packed and 8 is the orig of the tagged operand. The disambiguator 1 is not
; a key. Inlining this module does not add or drop those keys.
; CENSUS: start: {{.*}} last_use=4
; CENSUS: late: {{.*}} last_use=4

define void @keys(ptr %p) {
  %a = load i32, ptr %p, align 4, !mem.last_use !10
  %b = load i32, ptr %p, align 4, !mem.last_use !11
  ret void
}

define internal void @both(ptr addrspace(200) %sa, ptr addrspace(200) %sb, ptr addrspace(200) %pa, ptr addrspace(200) %pb) alwaysinline {
  store ptr addrspace(200) %pa, ptr addrspace(200) %sa, align 16, !mem.loan !0
  store ptr addrspace(200) %pb, ptr addrspace(200) %sb, align 16, !mem.loan !1
  call void @llvm.mem.fact() [ "mem.last_use"(i64 3, i64 5) ]
  ret void
}

; Caller holds 5 | (1 << 42), the only packed key for loan 5 when the field
; is one bit wide. Loan 3 still fits in that field. The one fact splits.
define void @split(ptr addrspace(200) %pa, ptr addrspace(200) %pb, ptr addrspace(200) %hc) addrspace(200) {
; SPLIT-LABEL: define void @split(
; SPLIT: store ptr addrspace(200) %hc, ptr addrspace(200) %hold{{.*}}!mem.loan [[HOLD:![0-9]+]]
; SPLIT: store ptr addrspace(200) %pa, ptr addrspace(200) %sa{{.*}}!mem.loan [[P:![0-9]+]]
; SPLIT: store ptr addrspace(200) %pb, ptr addrspace(200) %sb{{.*}}!mem.loan [[E:![0-9]+]]
; SPLIT: [ "mem.last_use"(i64 4398046511107) ]
; SPLIT: [ "mem.last_use.ext"(i64 5, i64 1) ]
; INV-LABEL: define void @split(
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %hold
; INV: store volatile ptr addrspace(200) null, ptr addrspace(200) %sb
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %sa
; INV-NOT: store volatile ptr addrspace(200) null, ptr addrspace(200) %hold
; INV: ret void
;
  %hold = alloca ptr addrspace(200), align 16, addrspace(200)
  %sa = alloca ptr addrspace(200), align 16, addrspace(200)
  %sb = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %hc, ptr addrspace(200) %hold, align 16, !mem.loan !2
  call void @both(ptr addrspace(200) %sa, ptr addrspace(200) %sb, ptr addrspace(200) %pa, ptr addrspace(200) %pb)
  ret void
}

; The load is dead. Its mixed list becomes one packed fact and one extended
; fact. The two ids are not folded into one bundle.
define i32 @dead_mixed(ptr %p) {
; DCE-LABEL: define {{.*}}@dead_mixed(
; DCE: [ "mem.last_use"(i64 7) ]
; DCE: [ "mem.last_use.ext"(i64 8, i64 1) ]
; DCE: ret i32 1
;
  %v = load i32, ptr %p, align 4, !mem.last_use !12
  ret i32 1
}

; SPLIT: [[HOLD]] = !{i64 4398046511109}
; SPLIT: [[P]] = !{i64 4398046511107}
; SPLIT: [[E]] = !{[[EP:![0-9]+]]}
; SPLIT: [[EP]] = !{!"mem.loan.ext", i64 5, i64 1}

!0 = !{i64 3}
!1 = !{i64 5}
!2 = !{i64 4398046511109}
!10 = !{i64 3, i64 5}
!11 = !{i64 7, !{!"mem.loan.ext", i64 8, i64 1}}
!12 = !{i64 7, !{!"mem.loan.ext", i64 8, i64 1}}
