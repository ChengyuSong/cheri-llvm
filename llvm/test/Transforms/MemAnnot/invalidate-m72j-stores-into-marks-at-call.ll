; [LLM-generated] M7.2j: rustc emits the caller-side fact of a callee store mark
; itself, right after the call, tagged !mem.stores_into.at_call. Here @inlined
; stands for a call whose callee was inlined before the late pass: only the
; at-call fact is left, and it is planned like any caller-side fact (compare and
; null at the free). At a call that survives (@kept), lowerStoresIntoMarks sees
; the at-call fact for the same mark and adds no second one (deduped=1).
; -cheri-invalidate-stores-into-marks-at-call=false erases the at-call facts
; first: @inlined gets no clear, @kept gets the M7.2g fact back.
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s --check-prefix=IR
; RUN: FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.off.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stores-into-marks-at-call=false -cheri-invalidate-stats-out=%t.off.stats < %s | FileCheck %s --check-prefix=OFFIR
; RUN: FileCheck %s --check-prefix=OFF < %t.off.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare void @put(ptr addrspace(200) "mem.stores_into_dst"="1" %r, ptr addrspace(200) "mem.stores_into"="1:16" %p)
declare void @llvm.mem.fact()

; IR-LABEL: define void @inlined(
; IR: store volatile ptr addrspace(200) null
; IR: call addrspace(200) void @free
; OFFIR-LABEL: define void @inlined(
; OFFIR-NOT: store volatile ptr addrspace(200) null
; OFFIR: call addrspace(200) void @free
define void @inlined(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  %slot = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %slot, align 16
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 16, ptr addrspace(200) %buf) ], !mem.stores_into.mark !0, !mem.stores_into.at_call !0
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

; One clear for the mark, not two.
; IR-LABEL: define void @kept(
; IR: call addrspace(200) void @put(
; IR: store volatile ptr addrspace(200) null
; IR-NOT: store volatile ptr addrspace(200) null
; IR: call addrspace(200) void @free
; OFFIR-LABEL: define void @kept(
; OFFIR: call addrspace(200) void @put(
; OFFIR: store volatile ptr addrspace(200) null
; OFFIR-NOT: store volatile ptr addrspace(200) null
; OFFIR: call addrspace(200) void @free
define void @kept(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 16, ptr addrspace(200) %buf) ], !mem.stores_into.mark !0, !mem.stores_into.at_call !0
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

!0 = !{}

; STATS: cheri-invalidate: {{.*}} store_into_nulls=2
; STATS: cheri-stores-into-mark-nulls: {{.*}} nulls=2 fns=inlined,kept{{$}}
; STATS: cheri-stores-into-marks-at-call: {{.*}} facts=2 dropped=0 deduped=1
; OFF: cheri-invalidate: {{.*}} store_into_nulls=1
; OFF: cheri-stores-into-mark-nulls: {{.*}} nulls=1 fns=kept{{$}}
; OFF: cheri-stores-into-marks: {{.*}} calls=1 facts=1
; OFF: cheri-stores-into-marks-at-call: {{.*}} facts=0 dropped=2 deduped=0
