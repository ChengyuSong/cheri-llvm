; [LLM-generated] M5r R7 (D54): with line tables, the D46 trap record names the
; innermost inlined frame outside the Rust library (the user's call site), not
; the core::arch::cheri wrapper the narrowing was inlined from.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-narrow-tag-check -cheri-narrow-tag-check-user-frame=false < %s | FileCheck %s --check-prefix=INNER
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200), i64)

define ptr addrspace(200) @user(ptr addrspace(200) %p, i64 %n) !dbg !5 {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n), !dbg !9
  ret ptr addrspace(200) %q
}
; CHECK: [[AUX:![0-9]+]] = !{i32 2091511821, i32 42, i32 13, i32 {{[0-9]+}}, [32 x i8] c"src/main.rs\00
; INNER: !{i32 2091511821, i32 7, i32 5, i32 {{[0-9]+}}, [32 x i8] c"ibrary/core/src/../cheri/mod.rs\00

define ptr addrspace(200) @user2(ptr addrspace(200) %p, i64 %n) !dbg !10 {
  %q = call ptr addrspace(200) @llvm.cheri.cap.bounds.set.exact.i64(ptr addrspace(200) %p, i64 %n), !dbg !13
  ret ptr addrspace(200) %q
}
; R7: core::arch::cheri lives in library/stdarch, named relative to the
; library/core directory (seen on s7b): skipped too.
; CHECK: !{i32 2091511821, i32 50, i32 9, i32 {{[0-9]+}}, [32 x i8] c"src/main.rs\00

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3}
!0 = distinct !DICompileUnit(language: DW_LANG_Rust, file: !1, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "src/main.rs", directory: "/work")
!2 = !DIFile(filename: "/rustc/x/library/core/src/../cheri/mod.rs", directory: "")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !{})
!5 = distinct !DISubprogram(name: "user", scope: !1, file: !1, line: 40, type: !4, spFlags: DISPFlagDefinition, unit: !0)
!6 = distinct !DISubprogram(name: "bounds_set_exact", scope: !2, file: !2, line: 5, type: !4, spFlags: DISPFlagDefinition, unit: !0)
!8 = distinct !DILocation(line: 42, column: 13, scope: !5)
!9 = !DILocation(line: 7, column: 5, scope: !6, inlinedAt: !8)
!11 = !DIFile(filename: "src/../../stdarch/crates/core_arch/src/cheri/mod.rs", directory: "/w/library/core")
!10 = distinct !DISubprogram(name: "user2", scope: !1, file: !1, line: 48, type: !4, spFlags: DISPFlagDefinition, unit: !0)
!12 = distinct !DISubprogram(name: "bounds_set", scope: !11, file: !11, line: 138, type: !4, spFlags: DISPFlagDefinition, unit: !0)
!14 = distinct !DILocation(line: 50, column: 9, scope: !10)
!13 = !DILocation(line: 140, column: 14, scope: !12, inlinedAt: !14)
