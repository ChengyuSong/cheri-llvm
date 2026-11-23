; [LLM-generated] M7.2m: rustc tags the store_into_slot fact of a byte copy out
; of a pointer-holding value (copy_nonoverlapping::<u8>) with
; !mem.store_into.bytes. The destination of a byte copy may be misaligned, so
; at the free the slot address is checked first: the slot is loaded, compared
; and nulled only when it is capability-aligned. @freed_dst: the destination
; buffer is freed between the copy and the free of the referent, so the fact is
; skipped (the slot load could go through a revoked capability).
; -cheri-invalidate-store-into-bytes=false ignores those facts.
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s | FileCheck %s --check-prefix=IR
; RUN: FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.off.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-store-into-bytes=false -cheri-invalidate-stats-out=%t.off.stats < %s | FileCheck %s --check-prefix=OFFIR
; RUN: FileCheck %s --check-prefix=OFF < %t.off.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare void @llvm.mem.fact()
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)

; IR-LABEL: define void @bytes(
; IR: call addrspace(200) void @llvm.memcpy
; IR: storeinto.bytes:
; IR: %storeinto.got = load ptr addrspace(200), ptr addrspace(200) %storeinto.slot, align 16
; IR: store volatile ptr addrspace(200) null, ptr addrspace(200) %storeinto.slot, align 16
; IR: call addrspace(200) void @free
; OFFIR-LABEL: define void @bytes(
; OFFIR-NOT: storeinto
; OFFIR: call addrspace(200) void @free
define void @bytes(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  %p = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %p, align 16
  %dst = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) align 1 %dst, ptr addrspace(200) align 16 %p, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %dst, i64 0, ptr addrspace(200) %buf) ], !mem.store_into.bytes !0
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

; IR-LABEL: define void @freed_dst(
; IR-NOT: storeinto
; IR: ret void
define void @freed_dst(ptr addrspace(200) %heap, ptr addrspace(200) %buf) {
  %p = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %buf, ptr addrspace(200) %p, align 16
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) align 1 %heap, ptr addrspace(200) align 16 %p, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.store_into_slot"(ptr addrspace(200) %heap, i64 0, ptr addrspace(200) %buf) ], !mem.store_into.bytes !0
  call void @free(ptr addrspace(200) %heap) [ "mem.free"(ptr addrspace(200) %heap) ]
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
}

!0 = !{}

; STATS: cheri-invalidate: {{.*}} store_into_nulls=1
; STATS: cheri-store-into-bytes-nulls: {{.*}} nulls=1{{$}}
; OFF: cheri-invalidate: {{.*}} store_into_nulls=0
; OFF-NOT: cheri-store-into-bytes-nulls
