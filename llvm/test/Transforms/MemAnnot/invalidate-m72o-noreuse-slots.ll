; [LLM-generated] M7.2o: (cap, slot) runtime notes under
; -cheri-invalidate-noreuse-slots.
;   * "mem.escape_unknown"(cap, slot) (an unknown-length byte copy that put cap
;     in slot) becomes cheri_note_escape_slot(cap, slot). Without the switch it
;     is the M7.2n block note cheri_note_escape(cap) (-cheri-invalidate-noreuse)
;     or dropped. A lost slot keeps the block note, a lost cap the global note.
;   * A store_into / store_into_slot fact the free-time planning skipped (no
;     free here, or the slot not ready at the free) becomes
;     cheri_note_escape_slot(cap, slot) at the fact. A planned fact, and a slot
;     in this function's own frame, get no call.
;   * The note reads no address and clears no tag; the planned clear is the
;     same with the switch on or off.
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots -cheri-invalidate-store-into-int=false -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s --check-prefixes=SLOTS,ALL
; RUN: FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.nr.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse -cheri-invalidate-store-into-int=false -cheri-invalidate-stats-out=%t.nr.stats < %s | FileCheck %s --check-prefixes=NR,ALL
; RUN: FileCheck %s --check-prefix=NRSTATS < %t.nr.stats
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-store-into-int=false < %s | FileCheck %s --check-prefixes=OFF,ALL
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-noreuse-slots -cheri-invalidate-store-into-int=false < %s | FileCheck %s --check-prefix=SONLY
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none -cheri-invalidate-noreuse -cheri-invalidate-noreuse-slots < %s | FileCheck %s --check-prefix=NONE

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare void @llvm.mem.fact()
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)

; E1 with a slot.
; ALL-LABEL: define void @dyn_copy_slot(
; SLOTS: call addrspace(200) void @llvm.memcpy
; SLOTS-NEXT: %slot = getelementptr i8, ptr addrspace(200) %dst, i64 32
; SLOTS-NEXT: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %cap, ptr addrspace(200) %slot)
; SLOTS-NOT: @cheri_note_escape(
; NR: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
; NR-NOT: cheri_note_escape_slot
; OFF-NOT: cheri_note_escape
; ALL-NOT: mem.escape_unknown
; ALL: call addrspace(200) void @free(ptr addrspace(200) %cap)
; SONLY-LABEL: define void @dyn_copy_slot(
; SONLY: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %cap, ptr addrspace(200) %slot)
; NONE-LABEL: define void @dyn_copy_slot(
; NONE-NOT: cheri_note
; NONE: ret void
define void @dyn_copy_slot(ptr addrspace(200) %dst, ptr addrspace(200) %src, i64 %n, ptr addrspace(200) %cap) {
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %dst, ptr addrspace(200) %src, i64 %n, i1 false)
  %slot = getelementptr i8, ptr addrspace(200) %dst, i64 32
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %cap, ptr addrspace(200) %slot) ]
  call void @free(ptr addrspace(200) %cap) [ "mem.free"(ptr addrspace(200) %cap) ]
  ret void
}

; E2 (one operand) stays the M7.2n block note; -noreuse-slots alone drops it.
; ALL-LABEL: define void @indirect(
; SLOTS: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %p)
; NR: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %p)
; OFF-NOT: cheri_note_escape
; ALL: call addrspace(200) void %f(ptr addrspace(200) %p)
; SONLY-LABEL: define void @indirect(
; SONLY-NOT: cheri_note_escape
; SONLY: call addrspace(200) void %f
define void @indirect(ptr addrspace(200) %f, ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %p) ]
  call addrspace(200) void %f(ptr addrspace(200) %p)
  ret void
}

; Lost slot: block note. Lost cap: global note.
; ALL-LABEL: define void @lost_slot(
; SLOTS: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
; SLOTS-NEXT: call addrspace(200) void @cheri_note_escape(ptr addrspace(200) %cap)
; SLOTS-NEXT: call addrspace(200) void @cheri_note_escape_anywhere()
; SLOTS-NEXT: ret void
define void @lost_slot(ptr addrspace(200) %cap) {
  call void @llvm.mem.fact() [ "mem.escape_unknown"(ptr addrspace(200) %cap, ptr addrspace(200) poison) ]
  call void @llvm.mem.fact() [ "mem.escape_unknown.lost"(ptr addrspace(200) %cap, ptr addrspace(200) poison) ]
  call void @llvm.mem.fact() [ "mem.escape_unknown.lost"(ptr addrspace(200) poison, ptr addrspace(200) %cap) ]
  ret void
}

; Store fact, no free in this function: slot note at the fact.
; ALL-LABEL: define void @store_nofree(
; SLOTS: store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
; SLOTS-NEXT: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %buf, ptr addrspace(200) %slot)
; NR-NOT: cheri_note_escape_slot
; OFF-NOT: cheri_note_escape_slot
; ALL: ret void
define void @store_nofree(ptr addrspace(200) %buf, ptr addrspace(200) %heap) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  ret void
}

; store_into_slot, no free: slot = GEP(i8, base, off) at the fact.
; ALL-LABEL: define void @slot_nofree(
; SLOTS: %[[S:[^ ]+]] = getelementptr i8, ptr addrspace(200) %heap, i64 %i
; SLOTS-NEXT: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %buf, ptr addrspace(200) %[[S]])
; ALL: ret void
define void @slot_nofree(ptr addrspace(200) %buf, ptr addrspace(200) %heap, i64 %i) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 %i
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 %i, ptr addrspace(200) %buf) ]
  ret void
}

; Planned (heap dest ready at the free): the clear, and no note.
; ALL-LABEL: define void @store_planned(
; SLOTS-NOT: cheri_note_escape_slot
; ALL: store volatile ptr addrspace(200) null
; ALL: call {{.*}}@free(ptr addrspace(200) %buf)
define void @store_planned(ptr addrspace(200) %buf, ptr addrspace(200) %heap) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

; Unready at the free (the slot pointer is loaded after the free's block):
; skipped by the planning, so a slot note.
; ALL-LABEL: define void @store_unready(
; SLOTS: call addrspace(200) void @cheri_note_escape_slot(ptr addrspace(200) %buf, ptr addrspace(200) %slot)
; SLOTS: call {{.*}}@free(ptr addrspace(200) %buf)
; NR-NOT: cheri_note_escape_slot
define void @store_unready(ptr addrspace(200) %buf, ptr addrspace(200) %pp, i1 %c) {
entry:
  br i1 %c, label %a, label %b
a:
  %slot = load ptr addrspace(200), ptr addrspace(200) %pp, align 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  br label %b
b:
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

; A slot in this function's own frame: no note.
; ALL-LABEL: define void @store_frame(
; ALL-NOT: cheri_note_escape_slot
; ALL: ret void
define void @store_frame(ptr addrspace(200) %buf) {
  %a = alloca [2 x ptr addrspace(200)], align 16, addrspace(200)
  %slot = getelementptr inbounds i8, ptr addrspace(200) %a, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into"(ptr addrspace(200) %slot, ptr addrspace(200) %buf) ]
  call void @use(ptr addrspace(200) %a)
  ret void
}

; [LLM-generated] M7.2o: weak no-op fallback for the lowered hook.
; SLOTS: define weak void @cheri_note_escape_slot(ptr addrspace(200) %0, ptr addrspace(200) %1){{.*}} {
; SLOTS-NEXT: entry:
; SLOTS-NEXT: ret void
; OFF-NOT: declare {{.*}}cheri_note_escape
; NONE-NOT: cheri_note

; STATS: cheri-noreuse: {{.*}} notes=3 global=1 dropped=0
; STATS: cheri-noreuse-slots: {{.*}} escape_slot_notes=1 store_notes=3 store_frame=1 store_planned=1 store_lost=0
; NRSTATS: cheri-noreuse: {{.*}} notes=4 global=1 dropped=0
; NRSTATS-NOT: cheri-noreuse-slots
