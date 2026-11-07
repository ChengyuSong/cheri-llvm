; [LLM-generated] M6.0 D85. Under -cheri-bounds-policy=narrow a mem.check plus
; !mem.guard becomes llvm.cheri.cap.bounds.set before LSR. Loop-reduce and
; CodeGenPrepare rewrite the GEP, and the narrowed pointer still feeds the
; access.
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-bounds-policy=narrow -stop-after=riscv-cheri-bounds-lowering < %s | FileCheck %s --check-prefix=PRE
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-bounds-policy=narrow -stop-after=loop-reduce < %s | FileCheck %s --check-prefix=LSR
; RUN: llc -mtriple=riscv64 -target-abi l64pc128d -mattr=+m,+a,+f,+d,+c,+xcheri,+xcheripurecap -O2 -cheri-bounds-policy=narrow -stop-after=codegenprepare < %s | FileCheck %s --check-prefix=CGP

target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @panic(i64) noreturn cold

define void @loop(ptr addrspace(200) %a, i64 %n) addrspace(200) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %ok ]
  %c = icmp ult i64 %i, 8
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr addrspace(200) %a, i64 %i, !mem.guard !0
  store i32 1, ptr addrspace(200) %g, align 4
  %i1 = add i64 %i, 1
  %e = icmp ult i64 %i1, %n
  br i1 %e, label %loop, label %exit
fail:
  call void @panic(i64 %i) [ "mem.check"(ptr addrspace(200) %a, i64 8, i64 4, i64 1, i64 0) ]
  unreachable
exit:
  ret void
}

; PRE: call {{.*}}@llvm.cheri.cap.bounds.set.exact{{.*}}ptr addrspace(200) %a, i64 32
; PRE: getelementptr {{.*}}ptr addrspace(200) %
; PRE: store i32 1
; PRE-NOT: "mem.check"

; LSR: call {{.*}}@llvm.cheri.cap.bounds.set.exact{{.*}}i64 32
; LSR: phi ptr addrspace(200) [ %scevgep, {{.*}} ], [ %0, %entry ]
; LSR: store i32 1, ptr addrspace(200) %lsr.iv
; LSR-NOT: "mem.check"

; CGP: call {{.*}}@llvm.cheri.cap.bounds.set.exact{{.*}}i64 32
; CGP: phi ptr addrspace(200) [ %scevgep, {{.*}} ], [ %0, %entry ]
; CGP: store i32 1, ptr addrspace(200) %lsr.iv
; CGP-NOT: "mem.check"

!0 = !{i64 1}
