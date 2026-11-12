; [LLM-generated] M7.1c-2b. At mem.free, a live capability slot that is not read
; again is cleared. A slot that does not escape is a plain null. One that
; escapes is a range check against the freed region. A later read, including
; a read reached by a loop back edge, is left alone. Off adds nothing.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=ON
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-free-dead-slots=off < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @dealloc(ptr addrspace(200))
declare void @opaque(ptr addrspace(200))
declare void @use(ptr addrspace(200))

define void @plain(ptr addrspace(200) %p, ptr addrspace(200) %v) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  store ptr addrspace(200) %v, ptr addrspace(200) %s, align 16
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @plain(
; ON: call {{.*}}@dealloc(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16, !pcsections [[DEAD:![0-9]+]]
; ON-NOT: cheri.inv.cap
; ON: call {{.*}}@llvm.lifetime.end.p200
; OFF-LABEL: define void @plain(
; OFF-NOT: cheri_inv_free_dead
; OFF: call {{.*}}@llvm.lifetime.end.p200

define void @plain_wide(ptr addrspace(200) %p, ptr addrspace(200) %v) {
  %t = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 48, i1 false)
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; ON-LABEL: define void @plain_wide(
; ON: call {{.*}}@dealloc(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %t, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

define void @escaped(ptr addrspace(200) %p, ptr addrspace(200) %v) {
  %t = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 48, i1 false)
  call void @opaque(ptr addrspace(200) %t)
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; ON-LABEL: define void @escaped(
; ON: call {{.*}}@dealloc(
; ON: cheri.inv.cap
; ON: cheri.inv.cap
; ON: cheri.inv.cap
; ON: call {{.*}}@llvm.lifetime.end.p200

define void @read_after(ptr addrspace(200) %p) {
  %obj = alloca i8, align 16, addrspace(200)
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  store ptr addrspace(200) %obj, ptr addrspace(200) %s, align 16
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  %x = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %x)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @read_after(
; ON: call {{.*}}@dealloc(
; ON-NOT: store volatile
; ON: load ptr addrspace(200), ptr addrspace(200) %s

define void @loop_read(ptr addrspace(200) %p) {
entry:
  %obj = alloca i8, align 16, addrspace(200)
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  store ptr addrspace(200) %obj, ptr addrspace(200) %s, align 16
  br label %loop
loop:
  %x = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %x)
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  br label %loop
}
; ON-LABEL: define void @loop_read(
; ON: call {{.*}}@dealloc(
; ON-NOT: store volatile
; ON: br label %loop

; ON: [[DEAD]] = !{!"cheri_inv_free_dead"}

; plain 1 word, plain_wide 3 words, escaped 3 range checks.
; STATS: free_dead_plain=4
; STATS-SAME: free_dead_checked=3
