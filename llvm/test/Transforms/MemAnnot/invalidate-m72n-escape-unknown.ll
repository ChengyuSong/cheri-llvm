; [LLM-generated] M7.2n: rustc marks a pointer that left to a place it cannot
; name with llvm.mem.fact ["mem.escape_unknown"(ptr cap)]. With
; -cheri-invalidate-noreuse the late pass lowers it to a call to the runtime's
; cheri_note_escape(cap) (the heap block holding cap is never reused). A lost
; operand (poison, or the ".lost" tag) falls back to the global no-reuse note
; cheri_note_escape_anywhere(). Off (the default) and -cheri-invalidate=none
; drop the facts: no call and no runtime symbol. The note itself reads no
; address and clears no tag.
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s --check-prefix=ON
; RUN: FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.off.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.off.stats < %s | FileCheck %s --check-prefix=OFF
; RUN: FileCheck %s --check-prefix=OFFSTATS < %t.off.stats
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none -cheri-invalidate-noreuse < %s | FileCheck %s --check-prefix=OFF

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)

; ON-LABEL: define void @dyn_copy(
; ON: call addrspace(200) void @llvm.memcpy
; ON-NEXT: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
; ON-NOT: mem.escape_unknown
; ON: call addrspace(200) void @free(ptr addrspace(200) %cap)
; OFF-LABEL: define void @dyn_copy(
; OFF-NOT: cheri_note_escape
; OFF-NOT: mem.escape_unknown
; OFF: ret void
define void @dyn_copy(ptr addrspace(200) %dst, ptr addrspace(200) %src, i64 %n, ptr addrspace(200) %cap) {
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %dst, ptr addrspace(200) %src, i64 %n, i1 false)
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %cap) ]
  call void @free(ptr addrspace(200) %cap) [ "mem.free"(ptr addrspace(200) %cap) ]
  ret void
}

; ON-LABEL: define void @indirect(
; ON: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %p)
; ON-NEXT: call addrspace(200) void %f(ptr addrspace(200) %p)
; OFF-LABEL: define void @indirect(
; OFF-NOT: cheri_note_escape
; OFF: call addrspace(200) void %f(ptr addrspace(200) %p)
define void @indirect(ptr addrspace(200) %f, ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %p) ]
  call addrspace(200) void %f(ptr addrspace(200) %p)
  ret void
}

; ON-LABEL: define void @lost(
; ON: call addrspace(200) void @cheri_note_escape_anywhere()
; ON-NEXT: call addrspace(200) void @cheri_note_escape_anywhere()
; ON-NEXT: ret void
; OFF-LABEL: define void @lost(
; OFF-NOT: cheri_note_escape
; OFF: ret void
define void @lost() {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) poison) ]
  call void @llvm.mem.fact() [ "mem.escape_unknown.lost"(ptr addrspace(200) poison) ]
  ret void
}

; ON: declare void @cheri_note_escape(ptr addrspace(200))
; ON: declare void @cheri_note_escape_anywhere()
; OFF-NOT: declare {{.*}}cheri_note_escape

; STATS: cheri-noreuse: {{.*}} notes=2 global=2 dropped=0
; OFFSTATS: cheri-noreuse: {{.*}} notes=0 global=0 dropped=4
