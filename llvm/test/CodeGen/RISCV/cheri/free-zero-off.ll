; [LLM-generated] M7.1c. -cheri-free-zero-regs=off plants no end marker, adds no
; "cheri-free-inner" attribute, and does not demote a tail call into a free.
;
; rustc riscv64 purecap datalayout:
; RUN: opt -S -passes=inline -cheri-free-zero-regs=off < %s | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-free-zero-regs=off -cheri-frame-wipe=off -cheri-invalidate=loan+free+slite+aflog -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=LATE
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-free-zero-regs=off -cheri-frame-wipe=off -cheri-invalidate=loan+free+slite+aflog < %s | FileCheck %s --check-prefix=ASM

target triple = "riscv64-unknown-unknown"
target datalayout = "e-m:e-p:64:64-pfe200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @wipe(ptr addrspace(200), i64) addrspace(200)
declare void @drop_vec(ptr addrspace(200)) addrspace(200)

define void @__rust_dealloc(ptr addrspace(200) %p, i64 %n, i64 %a) addrspace(200) alwaysinline {
  call void @wipe(ptr addrspace(200) %p, i64 %n)
  ret void
}

define void @user(ptr addrspace(200) %p) addrspace(200) {
  call void @__rust_dealloc(ptr addrspace(200) %p, i64 32, i64 8) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}

define void @drop_string(ptr addrspace(200) %p) addrspace(200) {
  tail call void @drop_vec(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}

; IR-LABEL: define void @user(
; IR: call {{.*}}@wipe(
; IR-NOT: cheri-free-inner
; IR-NOT: llvm.riscv.cheri.free.zero
; IR: tail call {{.*}}@drop_vec(

; The tail marker is still there after the late IR pass, and the call did
; not grow cheri-free-regs. The pre-existing free clear may sit after it.
; LATE: tail call {{.*}}@drop_vec
; LATE-NOT: cheri-free-regs
; LATE-NOT: llvm.riscv.cheri.free.zero

; No free-zero cmove sequence. A single capreg clear is not that sequence.
; ASM-LABEL: drop_string:
; ASM-NOT: cmove t0, zero
