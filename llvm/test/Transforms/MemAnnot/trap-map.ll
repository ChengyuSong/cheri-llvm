; [LLM-generated] M5r R5 (D38): trap -> panic. When the late pass removes a
; software check (ub here; elide's fast path likewise), the accesses of its
; guards get !pcsections "cheri_trap_map" with the panic location of the
; removed check (line, col, kind|seq<<8, 32-byte file tail) after a MAGIC word,
; so a CHERI fault on them can be reported as that panic. Kept checks and
; -cheri-trap-map=false leave no record.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub < %s | FileCheck %s --check-prefix=UB
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=ub -cheri-trap-map=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=OFF
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@file = private unnamed_addr addrspace(200) constant [11 x i8] c"src/main.rs", align 1
@loc = private unnamed_addr addrspace(200) constant <{ ptr addrspace(200), [8 x i8], [8 x i8], [8 x i8], [8 x i8] }> <{ ptr addrspace(200) @file, [8 x i8] c"\0B\00\00\00\00\00\00\00", [8 x i8] undef, [8 x i8] c"!\00\00\008\00\00\00", [8 x i8] undef }>, align 16

declare void @panic_bounds_check(i64, i64, ptr addrspace(200)) noreturn cold

define i64 @slice(ptr addrspace(200) %a, i64 %n, i64 %i) {
  %c = icmp ult i64 %i, %n
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i64, ptr addrspace(200) %a, i64 %i, !mem.guard !0
  %v = load i64, ptr addrspace(200) %g
  %g2 = getelementptr inbounds i8, ptr addrspace(200) %g, i64 0
  store i64 1, ptr addrspace(200) %g2
  ret i64 %v
fail:
  call void @panic_bounds_check(i64 %i, i64 %n, ptr addrspace(200) @loc) [ "mem.check"(ptr addrspace(200) %a, i64 %n, i64 8, i64 3, i64 0) ]
  unreachable
}
; UB-LABEL: define i64 @slice(
; UB-NOT: icmp ult
; UB: %v = load i64, ptr addrspace(200) %g{{.*}}, !pcsections [[R:![0-9]+]]
; UB: store i64 1, ptr addrspace(200) %g2{{.*}}, !pcsections [[R]]
; UB: [[R]] = !{!"cheri_trap_map", [[AUX:![0-9]+]]}
; UB: [[AUX]] = !{i32 2091511821, i32 33, i32 56, i32 256, [32 x i8] c"src/main.rs\00
; OFF-NOT: !pcsections

!0 = !{i64 3}
