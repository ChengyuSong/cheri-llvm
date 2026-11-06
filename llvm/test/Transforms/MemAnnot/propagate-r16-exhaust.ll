; [LLM-generated] M5r R16: when the packed field and the test disambiguator
; space are both full, compilation stops. The copy is not given disambiguator
; 1, which the caller already uses.
;
; RUN: not opt -S -passes=inline -mem-inline-loan-salt=1 -mem-inline-loan-high-bits=1 -mem-inline-loan-disambig-max=1 %s 2>&1 | FileCheck %s

; CHECK: LLVM ERROR: mem-inline-loan: no free copy id for census key 3
; CHECK-NOT: define void @full(

define internal void @one(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !0
  %v = load i32, ptr %cap, align 4, !mem.last_use !0
  ret void
}

define void @full(ptr %slot, ptr %cap, ptr %other, ptr %ocap, ptr %held, ptr %hcap) {
  ; 3 | (1 << 42). The only packed key at -mem-inline-loan-high-bits=1.
  store ptr %hcap, ptr %held, align 8, !mem.loan !1
  ; The only disambiguator allowed by -mem-inline-loan-disambig-max=1.
  store ptr %hcap, ptr %slot, align 8, !mem.loan !2
  call void @one(ptr %other, ptr %ocap)
  ret void
}

!0 = !{i64 3}
!1 = !{i64 4398046511107}
!2 = !{!{!"mem.loan.ext", i64 3, i64 1}}
