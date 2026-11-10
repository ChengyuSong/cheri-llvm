; [LLM-generated] M6.2 D112. A panic-edge fold rewrote the mem.check length to a
; constant (here 0) while the predecessor icmp still names the runtime length.
; Recover that length and let recoverConst invent a cheri.recovered GEP,
; including K=0 where the success access is the base. Narrow policy keeps the
; compare and narrows the runtime length (rounded). The folded 0 is not a
; bounds.set length.
;
; A GEP whose pointer is a PHI that carries the marker base on the success
; edge is linked the same way: only that incoming is narrowed.
;
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-bounds-policy=narrow < %s | FileCheck %s
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-bounds-policy=narrow -cheri-bounds-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @panic(i64, i64) noreturn cold

; v[0]: icmp eq %len, 0, bundle length folded to 0, success load of the base.
define i8 @folded_eq(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 1, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@folded_eq(
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %ptr, i64 0)
; CHECK: icmp eq i64 %len, 0
; CHECK: [[NEQ:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %ptr, i64 %len)
; CHECK: %cheri.recovered = getelementptr i8, ptr addrspace(200) [[NEQ]], i64 0
; CHECK: load i8, ptr addrspace(200) %cheri.recovered
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %ptr, i64 0)

; Same fold, success edge is `0 <u %len`.
define i8 @folded_ult(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %c = icmp ult i64 0, %len
  br i1 %c, label %ok, label %panic
ok:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 2, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@folded_ult(
; CHECK-NOT: bounds.set.exact
; CHECK: icmp ult i64 0, %len
; CHECK: [[NULT:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %ptr, i64 %len)
; CHECK: %cheri.recovered = getelementptr i8, ptr addrspace(200) [[NULT]], i64 0
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact

; Same fold, success edge is `%len >u 0`.
define i8 @folded_ugt(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %c = icmp ugt i64 %len, 0
  br i1 %c, label %ok, label %panic
ok:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 3, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@folded_ugt(
; CHECK-NOT: bounds.set.exact
; CHECK: icmp ugt i64 %len, 0
; CHECK: [[NUGT:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %ptr, i64 %len)
; CHECK: %cheri.recovered = getelementptr i8, ptr addrspace(200) [[NUGT]], i64 0
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact

; Negative: the icmp constant is not the panic index, and the folded length
; is not that constant. Do not invent a recovered guard or narrow to 0.
define i8 @not_index(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %eq = icmp eq i64 %len, 1
  br i1 %eq, label %panic, label %ok
ok:
  %b = load i8, ptr addrspace(200) %ptr, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 4, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@not_index(
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set
; CHECK: load i8, ptr addrspace(200) %ptr
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set

; Negative: the icmp does name %len and 0, but the success access is not the
; base (and not base + 0). Do not recover it and do not narrow to 0.
define i8 @not_offset(ptr addrspace(200) %ptr, i64 %len) {
entry:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  %p = getelementptr inbounds i8, ptr addrspace(200) %ptr, i64 8
  %b = load i8, ptr addrspace(200) %p, align 1
  ret i8 %b
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %ptr, i64 0, i64 1, i64 5, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@not_offset(
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set
; CHECK: getelementptr {{.*}}i8, ptr addrspace(200) %ptr, i64 8
; CHECK: load i8
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set

; sv_insert_remove: the guard's pointer is a PHI that includes the check base
; on the success edge. Bundle length was folded to 0; narrow the runtime length
; into that incoming only.
define i16 @phi_base(ptr addrspace(200) %base, ptr addrspace(200) %other, i64 %len, i64 %idx, i1 %to_check) {
entry:
  br i1 %to_check, label %check, label %side
side:
  br label %ok
check:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  %phi = phi ptr addrspace(200) [ %base, %check ], [ %other, %side ]
  %g = getelementptr inbounds i16, ptr addrspace(200) %phi, i64 %idx, !mem.guard !0
  %v = load i16, ptr addrspace(200) %g, align 2
  ret i16 %v
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %base, i64 0, i64 2, i64 11, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@phi_base(
; CHECK-NOT: bounds.set.exact
; CHECK: icmp eq i64 %len, 0
; CHECK: [[BPHI:%.*]] = mul nuw nsw i64 %len, 2
; CHECK: [[NPHI:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 [[BPHI]])
; CHECK: [[PPHI:%.*]] = phi ptr addrspace(200) [ [[NPHI]], %check ], [ %other, %side ]
; CHECK: getelementptr {{.*}}i16, ptr addrspace(200) [[PPHI]], i64 %idx
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: bounds.set.exact
; CHECK-NOT: bounds.set.i64(ptr addrspace(200) %base, i64 0)

; Negative: Mk.Base is a PHI incoming, but not on the success edge.
define i16 @phi_wrong_edge(ptr addrspace(200) %base, ptr addrspace(200) %other, i64 %len, i64 %idx, i1 %to_check) {
entry:
  br i1 %to_check, label %check, label %side
side:
  br label %ok
check:
  %eq = icmp eq i64 %len, 0
  br i1 %eq, label %panic, label %ok
ok:
  %phi = phi ptr addrspace(200) [ %other, %check ], [ %base, %side ]
  %g = getelementptr inbounds i16, ptr addrspace(200) %phi, i64 %idx, !mem.guard !1
  %v = load i16, ptr addrspace(200) %g, align 2
  ret i16 %v
panic:
  call void @panic(i64 0, i64 0) [ "mem.check"(ptr addrspace(200) %base, i64 0, i64 2, i64 12, i64 256) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@phi_wrong_edge(
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set
; CHECK: phi ptr addrspace(200) [ %other, %check ], [ %base, %side ]
; CHECK: call {{.*}}@panic(i64 0, i64 0)
; CHECK-NOT: cheri.recovered
; CHECK-NOT: llvm.cheri.cap.bounds.set

; Relink: the guard metadata is gone. The GEP pointer is a PHI that includes
; the check base on the success edge, and the index is the checked index.
define i16 @phi_relink(ptr addrspace(200) %base, ptr addrspace(200) %other, i64 %len, i64 %idx, i1 %to_check) {
entry:
  br i1 %to_check, label %check, label %side
side:
  br label %ok
check:
  %c = icmp ult i64 %idx, %len
  br i1 %c, label %ok, label %panic
ok:
  %phi = phi ptr addrspace(200) [ %base, %check ], [ %other, %side ]
  %g = getelementptr inbounds i16, ptr addrspace(200) %phi, i64 %idx
  %v = load i16, ptr addrspace(200) %g, align 2
  ret i16 %v
panic:
  call void @panic(i64 %idx, i64 %len) [ "mem.check"(ptr addrspace(200) %base, i64 %len, i64 2, i64 21, i64 0) ]
  unreachable
}
; CHECK-LABEL: define {{.*}}@phi_relink(
; CHECK-NOT: bounds.set.exact
; CHECK: icmp ult i64 %idx, %len
; CHECK: [[BREL:%.*]] = mul nuw nsw i64 %len, 2
; CHECK: [[NREL:%.*]] = call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %base, i64 [[BREL]])
; CHECK: phi ptr addrspace(200) [ [[NREL]], %check ], [ %other, %side ]
; CHECK: call {{.*}}@panic(i64 %idx, i64 %len)
; CHECK-NOT: bounds.set.exact

!0 = !{i64 11}
!1 = !{i64 12}

; STATS: markers=8 {{.*}}borrow=7 unlinked=3 guards=5 narrowed=5 {{.*}}twoversion=0 {{.*}}kept=5 {{.*}}relinked=1 {{.*}}recovered=3 recovered_markers=3
