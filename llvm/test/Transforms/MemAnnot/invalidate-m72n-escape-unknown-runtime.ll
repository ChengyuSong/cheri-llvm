; [LLM-generated] M7.2n: the module that defines the runtime's cheri_note_escape
; is never noted, even with -cheri-invalidate-noreuse: its facts are dropped (its
; indirect calls pass the arena and list heads, which must not become notes).
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s
; RUN: FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()

define void @cheri_note_escape(ptr addrspace(200) %p) {
  ret void
}

; CHECK-LABEL: define void @epoch(
; CHECK-NOT: call {{.*}}@cheri_note_escape
; CHECK-NOT: mem.escape_unknown
; CHECK: call addrspace(200) void %hook(ptr addrspace(200) %arena)
define void @epoch(ptr addrspace(200) %hook, ptr addrspace(200) %arena) {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %arena) ]
  call addrspace(200) void %hook(ptr addrspace(200) %arena)
  ret void
}

; STATS: cheri-noreuse: {{.*}} notes=0 global=0 dropped=1
