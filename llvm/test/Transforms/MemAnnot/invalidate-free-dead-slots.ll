; [LLM-generated] M7.1c-2b. At mem.free, a live capability slot that is not read
; again is cleared. A slot that does not escape is a plain null. One that
; escapes is a range check against the freed region. A later read, including
; a read reached by a loop back edge, is left alone. Off adds nothing.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=ON
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-free-dead-slots=off < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-free-dead-calls=off < %s | FileCheck %s --check-prefix=CALLSOFF
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @llvm.mem.fact()
declare void @drop_glue(ptr addrspace(200))
declare void @dealloc(ptr addrspace(200))
declare void @drop_in_place(ptr addrspace(200))
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

; r1: the loan slot holds &v[1]. The free is inside drop_in_place, not here.
define void @r1(ptr addrspace(200) %v) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %s)
  %d = getelementptr i8, ptr addrspace(200) %v, i64 16
  store ptr addrspace(200) %d, ptr addrspace(200) %s, align 16
  call void @drop_in_place(ptr addrspace(200) %v)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %s)
  ret void
}
; ON-LABEL: define void @r1(
; ON: call {{.*}}@drop_in_place(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %s, align 16, !pcsections [[DEAD]]
; ON-NOT: cheri.inv.cap
; ON: call {{.*}}@llvm.lifetime.end.p200
; CALLSOFF-LABEL: define void @r1(
; CALLSOFF: call {{.*}}@drop_in_place(
; CALLSOFF-NOT: cheri_inv_free_dead
; CALLSOFF: call {{.*}}@llvm.lifetime.end.p200

; s1: two temps, one of them black_box'd, both derived from the dropped owner.
define void @s1(ptr addrspace(200) %v) {
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %b)
  %d = getelementptr i8, ptr addrspace(200) %v, i64 16
  %bb = call ptr addrspace(200) asm sideeffect "", "=r,r"(ptr addrspace(200) %d)
  store ptr addrspace(200) %d, ptr addrspace(200) %a, align 16
  store ptr addrspace(200) %bb, ptr addrspace(200) %b, align 16
  call void @drop_in_place(ptr addrspace(200) %v)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %b)
  ret void
}
; ON-LABEL: define void @s1(
; ON: call {{.*}}@drop_in_place(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %a, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %b, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

; A slot holding some other object is not the dropped owner.
define void @other_owner(ptr addrspace(200) %v, ptr addrspace(200) %w) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %w, ptr addrspace(200) %s, align 16
  call void @drop_in_place(ptr addrspace(200) %v)
  ret void
}
; ON-LABEL: define void @other_owner(
; ON: call {{.*}}@drop_in_place(
; ON-NOT: store volatile
; ON: ret void

define void @drop_read_after(ptr addrspace(200) %v) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  %d = getelementptr i8, ptr addrspace(200) %v, i64 16
  store ptr addrspace(200) %d, ptr addrspace(200) %s, align 16
  call void @drop_in_place(ptr addrspace(200) %v)
  %x = load ptr addrspace(200), ptr addrspace(200) %s, align 16
  call void @use(ptr addrspace(200) %x)
  ret void
}
; ON-LABEL: define void @drop_read_after(
; ON: call {{.*}}@drop_in_place(
; ON-NOT: store volatile
; ON: load ptr addrspace(200), ptr addrspace(200) %s

define void @drop_escaped(ptr addrspace(200) %v) {
  %s = alloca ptr addrspace(200), align 16, addrspace(200)
  %d = getelementptr i8, ptr addrspace(200) %v, i64 16
  store ptr addrspace(200) %d, ptr addrspace(200) %s, align 16
  call void @opaque(ptr addrspace(200) %s)
  call void @drop_in_place(ptr addrspace(200) %v)
  ret void
}
; ON-LABEL: define void @drop_escaped(
; ON: call {{.*}}@drop_in_place(
; ON: cheri.inv.cap
; ON: ret void

; Real O2 shape: memcpy into the drop temp, mem.move of the source, drop_glue
; of the temp. The slot holds gep(load %v), the heap buffer, not the temp.
define void @r1_o2(ptr addrspace(200) %v) {
  %tmp = alloca [16 x i8], align 16, addrspace(200)
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  %buf = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %elem = getelementptr i8, ptr addrspace(200) %buf, i64 8
  store ptr addrspace(200) %elem, ptr addrspace(200) %r, align 16
  call void asm sideeffect "", "r,~{memory}"(ptr addrspace(200) %r)
  call void @drop_glue(ptr addrspace(200) %tmp)
  ret void
}
; ON-LABEL: define void @r1_o2(
; ON: call {{.*}}@drop_glue(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %r, align 16
; ON-NOT: cheri.inv.cap
; ON: ret void
; OFF-LABEL: define void @r1_o2(
; OFF: call {{.*}}@drop_glue(
; OFF-NOT: store volatile
; OFF: ret void
; CALLSOFF-LABEL: define void @r1_o2(
; CALLSOFF: call {{.*}}@drop_glue(
; CALLSOFF-NOT: store volatile
; CALLSOFF: ret void

define void @s1_o2(ptr addrspace(200) %v) {
  %tmp = alloca [16 x i8], align 16, addrspace(200)
  %a = alloca ptr addrspace(200), align 16, addrspace(200)
  %b = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  %buf = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %elem = getelementptr i8, ptr addrspace(200) %buf, i64 8
  %bb = call ptr addrspace(200) asm sideeffect "", "=r,r"(ptr addrspace(200) %elem)
  store ptr addrspace(200) %elem, ptr addrspace(200) %a, align 16
  store ptr addrspace(200) %bb, ptr addrspace(200) %b, align 16
  call void @drop_glue(ptr addrspace(200) %tmp)
  ret void
}
; ON-LABEL: define void @s1_o2(
; ON: call {{.*}}@drop_glue(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %a, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %b, align 16
; ON: ret void

define void @r1_escaped(ptr addrspace(200) %v) {
  %tmp = alloca [16 x i8], align 16, addrspace(200)
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 16, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  %buf = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  %elem = getelementptr i8, ptr addrspace(200) %buf, i64 8
  store ptr addrspace(200) %elem, ptr addrspace(200) %r, align 16
  call void @opaque(ptr addrspace(200) %r)
  call void @drop_glue(ptr addrspace(200) %tmp)
  ret void
}
; Bounds are the loaded heap buffer, not the Vec temporary passed to drop.
; ON-LABEL: define void @r1_escaped(
; ON: call {{.*}}@llvm.cheri.cap.base.get.i64(ptr addrspace(200) %buf)
; ON: call {{.*}}@drop_glue(
; ON: cheri.inv.cap
; ON-NOT: llvm.cheri.cap.base.get.i64(ptr addrspace(200) %tmp)

define void @partial_copy(ptr addrspace(200) %v) {
  %tmp = alloca [16 x i8], align 16, addrspace(200)
  %r = alloca ptr addrspace(200), align 16, addrspace(200)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 1, i1 false)
  %buf = load ptr addrspace(200), ptr addrspace(200) %v, align 16
  store ptr addrspace(200) %buf, ptr addrspace(200) %r, align 16
  call void @drop_glue(ptr addrspace(200) %tmp)
  ret void
}
; ON-LABEL: define void @partial_copy(
; ON: call {{.*}}@drop_glue(
; ON-NOT: store volatile
; ON: ret void

; ON: [[DEAD]] = !{!"cheri_inv_free_dead"}

; Inline frees: plain 1 + wide 3, escaped wide 3 checks.
; Drop calls: r1 1 + s1 2 + r1_o2 1 + s1_o2 2 plain, drop_escaped 1 + r1_escaped 1 check.
; STATS: range_checks=5
; STATS-SAME: flog_calls=0
; STATS-SAME: flog_loops=0
; STATS-SAME: free_dead_plain=4
; STATS-SAME: free_dead_checked=3
; STATS-SAME: free_dead_call_plain=6
; STATS-SAME: free_dead_call_checked=2
