; [LLM-generated] M7.2i: census line for clears planted from callee store marks.
; When a caller-side fact that came from a "mem.stores_into" mark gets its
; compare-and-null at the free, the stats file gets one extra line
;   cheri-stores-into-mark-nulls: <module> nulls=<n> fns=<f1,f2,...>
; Builds where no mark clear is planted (marks off, or no mark) keep the old
; stats lines only. The IR output itself does not change.
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.off.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stores-into-marks=false -cheri-invalidate-stats-out=%t.off.stats < %s && FileCheck %s --check-prefix=OFF --implicit-check-not=cheri-stores-into-mark-nulls < %t.off.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare void @put(ptr addrspace(200) "mem.stores_into_dst"="1" %r, ptr addrspace(200) "mem.stores_into"="1:16" %p)

define void @direct(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

define void @direct2(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

; No free of the stored pointer: no clear, not listed.
define void @nofree(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  call void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
  ret void
}

; STATS: cheri-invalidate: {{.*}} store_into_nulls=2
; STATS: cheri-stores-into-mark-nulls: {{.*}} nulls=2 fns=direct,direct2{{$}}
; STATS: cheri-stores-into-marks: {{.*}} calls=3 facts=3
; OFF: cheri-invalidate: {{.*}} store_into_nulls=0
