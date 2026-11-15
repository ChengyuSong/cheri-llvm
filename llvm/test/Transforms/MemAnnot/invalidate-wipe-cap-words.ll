; [LLM-generated] M7.2a-w1-opt. A cap-containing heap block being returned
; carries a caller-side fact:
;   call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr base, i64 len) ]
; The late CHERI pass lowers a small constant length (default <=8 cap
; words) to unrolled ready-address non-volatile null stores plus
; llvm.sideeffect (so DSE cannot drop them in front of allockind free).
; A variable or larger constant length becomes a call of an outlined
; helper whose even loop is unrolled by two (~2 insts/word). len==0 is a
; no-op and must not touch ptr. No ra/sp clear, no memcpy hook.
; -cheri-invalidate-wipe-cap-words=false and -cheri-invalidate=none plant
; no wipe (flag-off / none are byte-identical in the caller aside from
; the fact being stripped).
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=none < %s | FileCheck %s --check-prefix=NONE
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false < %s | FileCheck %s --check-prefix=FLAGOFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
; RUN: rm -f %t.stats-off && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan -cheri-invalidate-wipe-cap-words=false -cheri-invalidate-stats-out=%t.stats-off < %s && FileCheck %s --check-prefix=STATS-OFF < %t.stats-off
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @llvm.mem.fact()

; A cap-containing buffer of two cap words (32 B). Default unroll threshold
; is 8, so this is inlined, not an outlined helper call.
define void @wipe_buf(ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %p, i64 32) ]
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @wipe_buf(
; CHECK-NOT: @__cheri_wipe_cap_words
; CHECK: store ptr addrspace(200) null, ptr addrspace(200) %p
; CHECK: store ptr addrspace(200) null, ptr addrspace(200) %{{.*}}
; CHECK: call {{.*}}@llvm.sideeffect()
; CHECK: call {{.*}}@free(ptr addrspace(200) %p)
; CHECK-NOT: llvm.cheri.cap.offset.set
; CHECK-NOT: llvm.riscv.cheri
; CHECK: ret void
; FLAGOFF-LABEL: define void @wipe_buf(
; FLAGOFF-NOT: @__cheri_wipe_cap_words
; FLAGOFF-NOT: store ptr addrspace(200) null
; FLAGOFF: call {{.*}}@free(ptr addrspace(200) %p)
; FLAGOFF: ret void
; NONE-LABEL: define void @wipe_buf(
; NONE-NOT: @__cheri_wipe_cap_words
; NONE-NOT: store ptr addrspace(200) null
; NONE: call {{.*}}@free(ptr addrspace(200) %p)
; NONE: ret void

; cap==0 / len==0: a no-op. Must not touch the (possibly dangling) ptr
; and must not emit a helper call.
define void @wipe_zero(ptr addrspace(200) %dangling) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %dangling, i64 0) ]
  ret void
}
; CHECK-LABEL: define void @wipe_zero(
; CHECK-NOT: @__cheri_wipe_cap_words
; CHECK-NOT: store ptr addrspace(200) null
; CHECK-NOT: load
; CHECK: ret void

; Variable length stays on the outlined helper.
define void @wipe_var(ptr addrspace(200) %p, i64 %n) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %p, i64 %n) ]
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @wipe_var(
; CHECK: call {{.*}}@__cheri_wipe_cap_words(ptr addrspace(200) %p, i64 %n)
; CHECK: call {{.*}}@free(ptr addrspace(200) %p)
; CHECK: ret void

; A constant above the default unroll threshold (16 words, 256 B) stays
; on the helper.
define void @wipe_big(ptr addrspace(200) %p) {
  call void @llvm.mem.fact() [ "mem.wipe_cap_words"(ptr addrspace(200) %p, i64 256) ]
  call void @free(ptr addrspace(200) %p) [ "mem.free"(ptr addrspace(200) %p) ]
  ret void
}
; CHECK-LABEL: define void @wipe_big(
; CHECK: call {{.*}}@__cheri_wipe_cap_words(ptr addrspace(200) %p, i64 256)
; CHECK: call {{.*}}@free(ptr addrspace(200) %p)
; CHECK: ret void

; The outlined helper: non-volatile null stores, early exit on len==0,
; even loop unrolled by two, no ra/sp mentions.
; CHECK: define internal void @__cheri_wipe_cap_words
; CHECK: len_is_zero
; CHECK: peel
; CHECK: store ptr addrspace(200) null, ptr addrspace(200) %{{.*}}
; CHECK-NOT: store volatile
; CHECK-NOT: llvm.cheri.cap.offset.set
; CHECK: ret void

; STATS: wipe_cap_words_facts=4
; STATS: wipe_cap_words_calls=2
; STATS: wipe_cap_words_inlined=2
; STATS-OFF: wipe_cap_words_calls=0
; STATS-OFF-NOT: wipe_cap_words_calls=2
