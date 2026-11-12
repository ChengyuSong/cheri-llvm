; [LLM-generated] M7.1c-2a. A static alloca filled by memcpy, or written by a
; capability store at a variable index, is a capability slot on every aligned
; word. Own-null at lifetime.end covers those words. An alloca larger than
; -cheri-invalidate-wide-bytes (default 512) is skipped. Off leaves the
; fixed-offset slot set, so a memcpy-only temp is not nulled.
;
; RUN: opt -S -passes=cheri-bounds-lowering < %s | FileCheck %s --check-prefix=ON
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate-wide-slots=off < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && opt -S -passes=cheri-bounds-lowering -cheri-invalidate-stats-out=%t.stats < %s -o /dev/null && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.off && opt -S -passes=cheri-bounds-lowering -cheri-invalidate-wide-slots=off -cheri-invalidate-stats-out=%t.off < %s -o /dev/null && FileCheck %s --check-prefix=OFFSTATS < %t.off

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.lifetime.start.p200(ptr addrspace(200))
declare void @llvm.lifetime.end.p200(ptr addrspace(200))
declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @llvm.memmove.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @drop(ptr addrspace(200))
declare void @leaf()
declare void @use(ptr addrspace(200))
declare void @dealloc(ptr addrspace(200))

define void @memcpy_temp(ptr addrspace(200) %v) {
  %t = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 48, i1 false)
  call void @drop(ptr addrspace(200) %t)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; Three words, after the use, before lifetime.end.
; ON-LABEL: define void @memcpy_temp(
; ON: call {{.*}}@drop(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %t, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON-NEXT: call {{.*}}@llvm.lifetime.end.p200
; OFF-LABEL: define void @memcpy_temp(
; OFF-NOT: store volatile ptr addrspace(200) null
; OFF: call {{.*}}@llvm.lifetime.end.p200

define void @memmove_temp(ptr addrspace(200) %v) {
  %t = alloca [32 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memmove.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 32, i1 false)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; ON-LABEL: define void @memmove_temp(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %t, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

define void @var_index(ptr addrspace(200) %x) {
entry:
  %a = alloca [32 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %a)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %n, %loop ]
  %p = getelementptr i8, ptr addrspace(200) %a, i64 %i
  store ptr addrspace(200) %x, ptr addrspace(200) %p, align 16
  %n = add i64 %i, 16
  %c = icmp ult i64 %n, 32
  br i1 %c, label %loop, label %end
end:
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %a)
  ret void
}
; ON-LABEL: define void @var_index(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %a, align 16
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) {{%.*}}, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

define void @too_big(ptr addrspace(200) %v) {
  %b = alloca [1024 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %b)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %b, ptr addrspace(200) %v, i64 1024, i1 false)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %b)
  ret void
}
; ON-LABEL: define void @too_big(
; ON-NOT: store volatile ptr addrspace(200) null
; ON: call {{.*}}@llvm.lifetime.end.p200

; The temp is live across leaf and read by use. If its words were ordinary
; slots, that would be a free-log check after leaf and a range check at the
; free below. Neither is emitted.
define void @wide_across_call(ptr addrspace(200) %v) {
  %t = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 48, i1 false)
  call void @leaf()
  call void @use(ptr addrspace(200) %t)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; ON-LABEL: define void @wide_across_call(
; ON-NOT: __cheri_free_log
; ON-NOT: cheri.flog
; ON-NOT: cheri.inv.cap
; ON-NOT: llvm.cheri.cap.tag.get
; ON: call {{.*}}@use(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %t, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

define void @wide_at_free(ptr addrspace(200) %p, ptr addrspace(200) %v) {
  %t = alloca [48 x i8], align 16, addrspace(200)
  call void @llvm.lifetime.start.p200(ptr addrspace(200) %t)
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %t, ptr addrspace(200) %v, i64 48, i1 false)
  call void @dealloc(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  call void @use(ptr addrspace(200) %t)
  call void @llvm.lifetime.end.p200(ptr addrspace(200) %t)
  ret void
}
; The free may log itself. The widened words are not range-checked and do
; not start a free-log loop.
; ON-LABEL: define void @wide_at_free(
; ON-NOT: cheri.inv.cap
; ON-NOT: cheri.flog.d
; ON-NOT: cheri.flog.nz
; ON: call {{.*}}@use(
; ON: store volatile ptr addrspace(200) null, ptr addrspace(200) %t, align 16
; ON: call {{.*}}@llvm.lifetime.end.p200

; memcpy_temp 3, memmove_temp 2, var_index 2, wide_across_call 3, wide_at_free 3.
; too_big is over 512. No widened word is a range check or a free-log call.
; STATS: range_checks=0
; STATS-SAME: flog_calls=0
; STATS-SAME: flog_loops=0
; STATS-SAME: wide_allocas=5
; STATS-SAME: wide_skipped_large=1
; STATS-SAME: own_nulled_wide=13
; OFFSTATS: wide_allocas=0
; OFFSTATS-SAME: wide_skipped_large=0
; OFFSTATS-SAME: own_nulled_wide=0
