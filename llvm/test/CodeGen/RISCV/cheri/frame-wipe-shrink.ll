; [LLM-generated] M7.1c. Shrink-wrapping puts the CSR restore and the frame pop
; in a block that is not the return. Those slots are still wiped, after the
; reload and before the stack adjustment.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -enable-shrink-wrap < %s | FileCheck %s
; RUN: rm -f %t.stats && llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -enable-shrink-wrap -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @g(ptr addrspace(200)) addrspace(200)

define void @sw(i1 %c, ptr addrspace(200) %p) addrspace(200) {
entry:
  br i1 %c, label %cold, label %exit
cold:
  call void @g(ptr addrspace(200) %p)
  call void @g(ptr addrspace(200) %p)
  br label %exit
exit:
  ret void
}
; The hot path falls into the return with no frame. The cold path restores
; s0 and nulls that slot before adjusting sp, then branches to the return.
; CHECK-LABEL: sw:
; CHECK: ccall g
; CHECK: clc s0,
; CHECK-NEXT: csc zero,
; CHECK: cincoffset sp, sp,
; CHECK: cret

; STATS: cheri-frame-wipe: fn=sw slots=1 stores=1
