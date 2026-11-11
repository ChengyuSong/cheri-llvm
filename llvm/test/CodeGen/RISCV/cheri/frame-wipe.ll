; [LLM-generated] M7.1c. After PEI, each return stores cnull over callee-saved
; save slots except ra, after those registers are restored and before the
; frame is popped. A 16-byte spill is wiped too. -cheri-frame-wipe=off leaves
; the epilogue alone. The pass is riscv-cheri-frame-wipe, after prologepilog.
;
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 < %s | FileCheck %s
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-frame-wipe=off < %s | FileCheck %s --check-prefix=OFF
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -stop-after=riscv-cheri-frame-wipe < %s | FileCheck %s --check-prefix=MIR
; RUN: rm -f %t.stats && llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @g(ptr addrspace(200)) addrspace(200)

define void @csr(ptr addrspace(200) %p) addrspace(200) {
  call void @g(ptr addrspace(200) %p)
  call void @g(ptr addrspace(200) %p)
  ret void
}
; The ra slot is restored and not nulled. s0's slot is nulled after its reload,
; before the frame is popped.
; CHECK-LABEL: csr:
; CHECK: clc ra,
; CHECK-NEXT: clc s0,
; CHECK-NEXT: csc zero,
; CHECK: cincoffset sp, sp,
; CHECK: cret
; OFF-LABEL: csr:
; OFF: clc s0,
; OFF-NOT: csc zero
; OFF: cret
; MIR: name: csr
; MIR: CLC_128
; MIR: CSC_128 $x0_y

define void @two(i1 %c, ptr addrspace(200) %p) addrspace(200) {
  call void @g(ptr addrspace(200) %p)
  br i1 %c, label %a, label %b
a:
  call void @g(ptr addrspace(200) %p)
  ret void
b:
  call void @g(ptr addrspace(200) %p)
  ret void
}
; Both returns fold into one epilogue. ra is restored and not nulled; s0 and
; s1 are nulled after their own reloads.
; CHECK-LABEL: two:
; CHECK: clc ra,
; CHECK-NEXT: clc s0,
; CHECK-NEXT: csc zero,
; CHECK-NEXT: clc s1,
; CHECK-NEXT: csc zero,
; CHECK: cincoffset sp, sp,
; CHECK: cret

; STATS: cheri-frame-wipe: fn=csr slots=1 stores=1
; STATS: cheri-frame-wipe: fn=two slots=2 stores=2
