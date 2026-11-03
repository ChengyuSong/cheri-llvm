; RUN: llc --filetype=asm --mcpu=cheriot --mtriple=riscv32-unknown-cheriotrtos -target-abi cheriot -mattr=+xcheri,+xcheripurecap,+xcheriot < %s | FileCheck %s
; ptrtoaddr on a CHERIoT capability must select to an address read, not crash
; in ISel with "Cannot select: i32 = truncate c64".
target datalayout = "e-m:e-p:32:32-pfe200:64:64:64:32-i64:64-n32-S128-A200-P200-G200"
target triple = "riscv32-unknown-cheriotrtos"

; CHECK-LABEL: via_ptrtoaddr:
; CHECK-NOT: ct.
; CHECK: ct.cret
define i32 @via_ptrtoaddr(ptr addrspace(200) %p) addrspace(200) {
  %a = ptrtoaddr ptr addrspace(200) %p to i32
  ret i32 %a
}

; CHECK-LABEL: diff_ptrtoaddr:
; CHECK: sub a0, a0, a1
define i32 @diff_ptrtoaddr(ptr addrspace(200) %p, ptr addrspace(200) %q) addrspace(200) {
  %a = ptrtoaddr ptr addrspace(200) %p to i32
  %b = ptrtoaddr ptr addrspace(200) %q to i32
  %d = sub i32 %a, %b
  ret i32 %d
}

; CHECK-LABEL: aligned16:
; CHECK: andi a0, a0, 15
define i1 @aligned16(ptr addrspace(200) %p) addrspace(200) {
  %a = ptrtoaddr ptr addrspace(200) %p to i32
  %m = and i32 %a, 15
  %c = icmp eq i32 %m, 0
  ret i1 %c
}
