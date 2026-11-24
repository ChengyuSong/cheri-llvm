; [LLM-generated] M7.2o: weak no-op fallbacks for the runtime note hooks.
;   * A module where the pass lowered a call to cheri_note_escape,
;     cheri_note_escape_anywhere or cheri_note_escape_slot gets a weak
;     definition of that hook that only returns, so a program without the
;     cheri_revoke runtime still links. The runtime's strong definition wins
;     when it is linked.
;   * The stub takes the module's target-cpu / target-features.
;   * Switches off (no call lowered): no stub, no new symbol.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots < %s | FileCheck %s --check-prefix=ON
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse < %s | FileCheck %s --check-prefix=NR
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots < %s | FileCheck %s --check-prefix=OFF

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.mem.fact()

; ON-LABEL: define void @slot(
; ON: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %cap, ptr addrspace(200) %dst)
; NR-LABEL: define void @slot(
; NR: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
define void @slot(ptr addrspace(200) %dst, ptr addrspace(200) %cap) #0 {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %cap, ptr addrspace(200) %dst) ]
  ret void
}

; ON-LABEL: define void @block(
; ON: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
define void @block(ptr addrspace(200) %cap) #0 {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %cap) ]
  ret void
}

; ON-LABEL: define void @lost(
; ON: call addrspace(200) void @cheri_note_escape_anywhere()
define void @lost() #0 {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) poison) ]
  ret void
}

; ON: define weak void @cheri_note_escape_slot(ptr addrspace(200) %0, ptr addrspace(200) %1) addrspace(200) #[[S:[0-9]+]] {
; ON-NEXT: entry:
; ON-NEXT: ret void
; ON-NEXT: }
; ON: define weak void @cheri_note_escape(ptr addrspace(200) %0) addrspace(200) #[[S]] {
; ON-NEXT: entry:
; ON-NEXT: ret void
; ON-NEXT: }
; ON: define weak void @cheri_note_escape_anywhere() addrspace(200) #[[S]] {
; ON-NEXT: entry:
; ON-NEXT: ret void
; ON-NEXT: }
; ON-NOT: declare {{.*}}cheri_note
; ON: attributes #[[S]] = { nounwind "target-cpu"="generic-rv64" "target-features"="+xcheri" }

; NR-NOT: cheri_note_escape_slot
; NR: define weak void @cheri_note_escape(ptr addrspace(200) %0)
; NR: define weak void @cheri_note_escape_anywhere()
; NR-NOT: cheri_note_escape_slot

; OFF-NOT: cheri_note
; OFF-NOT: weak

attributes #0 = { "target-cpu"="generic-rv64" "target-features"="+xcheri" }
