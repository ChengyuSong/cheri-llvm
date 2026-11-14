; [LLM-generated] M7.2a-w1. A cap-containing heap block being returned
; carries a caller-side fact:
;   call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr base, i64 len) ]
; The late CHERI pass lowers it at the fact site to a call of an outlined
; non-volatile helper that stores a null capability in every 16-byte slot
; wholly in [base, base+len). len==0 is a no-op and must not touch ptr.
; No ra/sp clear, no memcpy hook. -cheri-invalidate-wipe-cap-words=false
; and -cheri-invalidate=none plant no wipe (flag-off / none are
; byte-identical in the caller aside from the fact being stripped).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; A cap-containing buffer (e.g. Vec<&str> / Vec<Rc<_>>) of two cap words.
define void @wipe_buf(ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %p, i64 32) ]
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @wipe_buf(
; CHECK: call {{.*}}@__cheri_wipe_cap_words(ptr addrspace(200) %p, i64 32)
; CHECK: call {{.*}}@free(ptr addrspace(200) %p)
; CHECK-NOT: llvm.cheri.cap.offset.set
; CHECK-NOT: llvm.riscv.cheri
; CHECK: ret void
; FLAGOFF-LABEL: define void @wipe_buf(
; FLAGOFF-NOT: @__cheri_wipe_cap_words
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %p)
; FLAGOFF: ret void
; NONE-LABEL: define void @wipe_buf(
; NONE-NOT: @__cheri_wipe_cap_words
; NONE: call {{.*}}@free(ptr addrspace(200) %p)
; NONE: ret void

; cap==0 / len==0: the helper is still called, but must no-op before using ptr.
define void @wipe_zero(ptr addrspace(200) %dangling) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %dangling, i64 0) ]
  ret void
}
; CHECK-LABEL: define void @wipe_zero(
; CHECK: call {{.*}}@__cheri_wipe_cap_words(ptr addrspace(200) %dangling, i64 0)
; CHECK: ret void

; The outlined helper: non-volatile null stores, early exit on len==0,
; no ra/sp mentions.
; CHECK: define internal void @__cheri_wipe_cap_words
; CHECK: len_is_zero
; CHECK: store ptr addrspace(200) null, ptr addrspace(200) %{{.*}}
; CHECK-NOT: store volatile
; CHECK-NOT: llvm.cheri.cap.offset.set
; CHECK: ret void

; STATS: wipe_cap_words_facts=2
; STATS: wipe_cap_words_calls=2
; STATS-OFF: wipe_cap_words_calls=0
; STATS-OFF-NOT: wipe_cap_words_calls=2
