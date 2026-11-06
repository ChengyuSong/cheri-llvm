; [LLM-generated] M5r R15: ordinary pipelines keep Rust memory facts, and a
; last-use program point is not moved before a slot reload that used to
; precede it. Loan ids of nested inlines stay distinct.
;
; Facts under test (see llvm/IR/MemAnnot.h):
;   llvm.mem.claim, "mem.check", "mem.free", llvm.mem.fact bundles,
;   !mem.guard, !mem.last_use, !mem.loan, llvm.lifetime.end.
;
; RUN: opt -S -passes='default<O1>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -S -passes='default<O2>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -S -passes='default<O3>' -verify-each < %s | FileCheck %s --check-prefix=PIPE
; RUN: opt -disable-output -mem-annot-census -mem-annot-census-strict \
; RUN:   -passes='mem-annot-census-start,default<O2>,mem-annot-census-late' < %s
; RUN: opt -S -passes='loop-mssa(licm)' < %s | FileCheck %s --check-prefix=LICM
; RUN: opt -S -passes='simplifycfg<hoist-common-insts>' < %s | FileCheck %s --check-prefix=HOIST
; RUN: opt -S -passes=gvn-hoist < %s | FileCheck %s --check-prefix=GVNH
; RUN: opt -S -passes=loop-unroll -unroll-count=2 < %s | FileCheck %s --check-prefix=UNROLL
; RUN: opt -S -passes=instcombine < %s | FileCheck %s --check-prefix=IC
; RUN: opt -S -passes=dce < %s | FileCheck %s --check-prefix=DCE
; RUN: opt -S -passes=adce < %s | FileCheck %s --check-prefix=DCE
; RUN: opt -S -passes=sroa < %s | FileCheck %s --check-prefix=SROA
; RUN: opt -S -passes=inline < %s > %t.inline.ll
; RUN: FileCheck %s --check-prefix=INLINE < %t.inline.ll
; RUN: python3 -c 'import pathlib,re,sys; t=pathlib.Path(sys.argv[1]).read_text(); m=re.search(r"define void @nested\(.*?\n\}", t, re.S); assert m, "missing @nested"; refs=re.findall(r"!mem\.(?:loan|last_use) !(\d+)", m.group(0)); md={n:int(v) for n,v in re.findall(r"!(\d+) = !\{i64 (\d+)\}", t)}; vals=[md[r] for r in refs]; assert len(vals)>=4, vals; assert len(set(vals))>=2, vals; assert all((v & ((1<<42)-1))==3 for v in vals), vals' %t.inline.ll

target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"

declare void @use(ptr, i32)
declare void @use_ptr(ptr)
declare void @use_i64(i64) memory(none)
declare void @touch(ptr nocapture) memory(argmem: readwrite)
declare void @escape(ptr)
declare void @dealloc(ptr)
declare void @panic(i64, i64) noreturn cold
declare void @llvm.mem.fact()
declare ptr @llvm.mem.claim.p0(ptr, i64, i64)
declare void @llvm.lifetime.start.p0(i64, ptr)
declare void @llvm.lifetime.end.p0(i64, ptr)

; Slot reload, then the marked last use, then lifetime.end and mem.free.
; The check stays on the untaken side. O1/O2/O3 must not move the last-use
; above the slot reload, drop the free/check/claim, or sink lifetime.end
; above the reload.
define i32 @pipeline(ptr dereferenceable(64) %s, ptr %cap, ptr %heap, i64 %i) {
; PIPE-LABEL: define i32 @pipeline(
; PIPE: store ptr %cap, ptr %slot{{.*}}!mem.loan
; PIPE: !mem.guard
; PIPE: call ptr @llvm.mem.claim
; PIPE: load volatile ptr, ptr %slot
; PIPE-NOT: !mem.last_use
; PIPE: load i32, ptr {{.*}}!mem.last_use
; PIPE: call void @llvm.lifetime.end
; PIPE: call void @dealloc(ptr %heap) {{.*}}[ "mem.free"(ptr %heap) ]
; PIPE: [ "mem.check"(ptr %s, i64 16, i64 4, i64 1, i64 0) ]
;
  %slot = alloca ptr, align 8
  call void @llvm.lifetime.start.p0(i64 8, ptr %slot)
  store ptr %cap, ptr %slot, align 8, !mem.loan !0
  %in = icmp ult i64 %i, 16
  br i1 %in, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr %s, i64 %i, !mem.guard !1
  %cl = call ptr @llvm.mem.claim.p0(ptr %g, i64 4, i64 0)
  %borrowed = load volatile ptr, ptr %slot, align 8
  %v = load i32, ptr %cl, align 4, !mem.guard !1, !mem.last_use !0
  call void @use(ptr %borrowed, i32 %v)
  call void @llvm.lifetime.end.p0(i64 8, ptr %slot)
  call void @dealloc(ptr %heap) [ "mem.free"(ptr %heap) ]
  ret i32 %v
fail:
  call void @panic(i64 %i, i64 16) [ "mem.check"(ptr %s, i64 16, i64 4, i64 1, i64 0) ]
  unreachable
}

; Invariant load hoisted out of the loop. Its last-use must stay after the
; in-loop slot reload (the call), not ride the hoisted load into the preheader.
define void @licm_last_use(ptr noalias %slot, ptr noalias %p, ptr %cap) {
; LICM-LABEL: define void @licm_last_use(
; LICM: store ptr %cap, ptr %slot{{.*}}!mem.loan
; LICM: load i32, ptr %p
; LICM-NOT: !mem.last_use
; LICM: br label %loop
; LICM: load ptr, ptr %slot
; LICM-NOT: !mem.last_use
; LICM: call void @touch(ptr %slot){{.*}}!mem.last_use
;
entry:
  store ptr %cap, ptr %slot, align 8, !mem.loan !0
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %c = load ptr, ptr %slot, align 8
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  call void @touch(ptr %slot)
  %n = ptrtoint ptr %c to i64
  %vn = zext i32 %v to i64
  %both = add i64 %n, %vn
  call void @use_i64(i64 %both)
  %i1 = add nuw i64 %i, 1
  %cond = icmp ult i64 %i1, 4
  br i1 %cond, label %loop, label %exit
exit:
  ret void
}

; The identical last-use loads are hoisted. The slot reloads are not (different
; pointers) and must still happen before the loan end on each path.
define void @cfg_hoist(i1 %c, ptr %p, ptr %slot1, ptr %slot2) {
; HOIST-LABEL: define void @cfg_hoist(
; The hoisted load is before both slot reloads, so it must not keep the marker.
; One path forwards the marker to the call. The erased copy's transfer lands
; on the previous carrier (the slot reload); the clear is still after that reload.
; HOIST: load i32, ptr %p, align 4{{$}}
; HOIST: br i1 %c
; HOIST: load ptr, ptr %slot1
; HOIST-NOT: !mem.last_use
; HOIST: call void @use_ptr(ptr {{.*}}){{.*}}!mem.last_use
; HOIST: load ptr, ptr %slot2{{.*}}!mem.last_use
; HOIST: call void @use_ptr(ptr
;
  br i1 %c, label %t, label %f
t:
  %s1 = load ptr, ptr %slot1, align 8
  %v1 = load i32, ptr %p, align 4, !mem.last_use !0
  call void @use_ptr(ptr %s1)
  br label %j
f:
  %s2 = load ptr, ptr %slot2, align 8
  %v2 = load i32, ptr %p, align 4, !mem.last_use !0
  call void @use_ptr(ptr %s2)
  br label %j
j:
  ret void
}

define void @gvn_hoist(i1 %c, ptr %p, ptr %slot1, ptr %slot2) {
; GVNH-LABEL: define void @gvn_hoist(
; GVNH: store i32 1, ptr %p, align 4{{$}}
; GVNH: br i1 %c
; GVNH: load ptr, ptr %slot1{{.*}}!mem.last_use
; GVNH: call void @use_ptr(ptr
; GVNH: load ptr, ptr %slot2{{.*}}!mem.last_use
; GVNH: call void @use_ptr(ptr
;
  br i1 %c, label %t, label %f
t:
  store i32 1, ptr %p, align 4, !mem.last_use !0
  %s1 = load ptr, ptr %slot1, align 8
  call void @use_ptr(ptr %s1)
  br label %j
f:
  store i32 1, ptr %p, align 4, !mem.last_use !0
  %s2 = load ptr, ptr %slot2, align 8
  call void @use_ptr(ptr %s2)
  br label %j
j:
  ret void
}

; Each unrolled copy is one dynamic execution of the original program point,
; so each keeps the marker. It is not moved onto the preheader, and the slot
; reload of a copy stays before that copy's marker.
define void @unroll_last_use(ptr noalias %slot, ptr noalias %p) {
; UNROLL-LABEL: define void @unroll_last_use(
; UNROLL-NOT: load i32, ptr %p{{.*}}!mem.last_use
; UNROLL: load ptr, ptr %slot
; UNROLL-NOT: !mem.last_use
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use
; UNROLL: load ptr, ptr %slot
; UNROLL-NOT: !mem.last_use
; UNROLL: load i32, ptr %p{{.*}}!mem.last_use
;
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %c = load ptr, ptr %slot, align 8
  %v = load i32, ptr %p, align 4, !mem.last_use !0
  call void @use(ptr %c, i32 %v)
  %i1 = add nuw i64 %i, 1
  %cond = icmp ult i64 %i1, 2
  br i1 %cond, label %loop, label %exit
exit:
  ret void
}

; A narrowed load is the same access: guard and last-use stay on it.
; A select/phi of two claims does not fold either claim away.
define i8 @narrow(ptr %p) {
; IC-LABEL: define i8 @narrow(
; IC: load i32, ptr %p{{.*}}!mem.guard{{.*}}!mem.last_use
;
  %v = load i32, ptr %p, align 1, !mem.guard !1, !mem.last_use !0
  %t = trunc i32 %v to i8
  ret i8 %t
}

define i32 @select_claims(i1 %c, ptr %p, ptr %q) {
; IC-LABEL: define i32 @select_claims(
; IC: call ptr @llvm.mem.claim.p0(ptr %p, i64 4, i64 0)
; IC: call ptr @llvm.mem.claim.p0(ptr %q, i64 4, i64 0)
; IC: select i1 %c
; IC: load i32, ptr
;
  %a = call ptr @llvm.mem.claim.p0(ptr %p, i64 4, i64 0)
  %b = call ptr @llvm.mem.claim.p0(ptr %q, i64 4, i64 0)
  %s = select i1 %c, ptr %a, ptr %b
  %v = load i32, ptr %s, align 4
  ret i32 %v
}

define i32 @phi_claims(i1 %c, ptr %p, ptr %q) {
; IC-LABEL: define i32 @phi_claims(
; IC: call ptr @llvm.mem.claim.p0(ptr %p, i64 4, i64 0)
; IC: call ptr @llvm.mem.claim.p0(ptr %q, i64 4, i64 0)
; IC: phi ptr
; IC: load i32, ptr
;
  br i1 %c, label %t, label %f
t:
  %a = call ptr @llvm.mem.claim.p0(ptr %p, i64 4, i64 0)
  br label %j
f:
  %b = call ptr @llvm.mem.claim.p0(ptr %q, i64 4, i64 0)
  br label %j
j:
  %s = phi ptr [ %a, %t ], [ %b, %f ]
  %v = load i32, ptr %s, align 4
  ret i32 %v
}

; mem.free is a safety constraint. The fact intrinsic writes inaccessible
; memory, so DCE/ADCE keep it (and a non-redundant alloc_inbounds fact).
; lifetime.end stays after the escape, not before it.
define void @dce_free(ptr %p) {
; DCE-LABEL: define void @dce_free(
; DCE: [ "mem.alloc_inbounds"(ptr %p) ]
; DCE: [ "mem.free"(ptr %p) ]
; DCE: call void @escape(ptr %a)
; DCE: call void @llvm.lifetime.end
; IC-LABEL: define void @dce_free(
; IC: [ "mem.free"(ptr %p) ]
; IC: call void @escape(ptr
; IC: call void @llvm.lifetime.end
;
  call void @llvm.mem.fact() [ "mem.alloc_inbounds"(ptr %p) ]
  call void @llvm.mem.fact() [ "mem.free"(ptr %p) ]
  %a = alloca i8, i64 16
  call void @llvm.lifetime.start.p0(i64 16, ptr %a)
  call void @escape(ptr %a)
  call void @llvm.lifetime.end.p0(i64 16, ptr %a)
  ret void
}

; Rewritten slice load/store keep the program point and the loan link.
define i64 @sroa_keep(ptr %cap) {
; SROA-LABEL: define i64 @sroa_keep(
; The pointer field is promoted, so its loan store has no stack slot left.
; The rewritten volatile field load keeps the guard and the last-use.
; SROA: load volatile i32, ptr {{.*}}!mem.guard{{.*}}!mem.last_use
;
  %a = alloca { ptr, i32 }, align 8
  %f0 = getelementptr inbounds { ptr, i32 }, ptr %a, i32 0, i32 0
  store ptr %cap, ptr %f0, align 8, !mem.loan !0
  %f1 = getelementptr inbounds { ptr, i32 }, ptr %a, i32 0, i32 1
  store i32 7, ptr %f1, align 4
  %pref = load ptr, ptr %f0, align 8
  %v = load volatile i32, ptr %f1, align 4, !mem.guard !1, !mem.last_use !0
  %n = ptrtoint ptr %pref to i64
  %vn = zext i32 %v to i64
  %both = add i64 %n, %vn
  ret i64 %both
}

; inner is inlined into mid first (two salts), then mid into nested. The two
; copies must not collapse back onto one loan id.
define internal void @inner(ptr %slot, ptr %cap) alwaysinline {
  store ptr %cap, ptr %slot, align 8, !mem.loan !2
  %v = load i32, ptr %cap, align 4, !mem.last_use !2
  call void @use(ptr %slot, i32 %v)
  ret void
}

define internal void @mid(ptr %a, ptr %b, ptr %c1, ptr %c2) alwaysinline {
  call void @inner(ptr %a, ptr %c1)
  call void @inner(ptr %b, ptr %c2)
  ret void
}

define void @nested(ptr %a, ptr %b, ptr %c1, ptr %c2) {
; INLINE-LABEL: define void @nested(
; INLINE: store ptr %c1, ptr %a{{.*}}!mem.loan [[L1:![0-9]+]]
; INLINE: load i32, ptr %c1{{.*}}!mem.last_use [[L1]]
; INLINE: store ptr %c2, ptr %b{{.*}}!mem.loan [[L2:![0-9]+]]
; INLINE: load i32, ptr %c2{{.*}}!mem.last_use [[L2]]
; INLINE: [[L1]] = !{i64 [[N1:[0-9]+]]}
; INLINE: [[L2]] = !{i64 [[N2:[0-9]+]]}
;
  call void @mid(ptr %a, ptr %b, ptr %c1, ptr %c2)
  ret void
}

!0 = !{i64 7}
!1 = !{i64 1}
!2 = !{i64 3}
