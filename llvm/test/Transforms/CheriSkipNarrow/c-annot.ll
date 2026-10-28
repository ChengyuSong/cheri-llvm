; LLM-generated: C-produced annotations (mem_annot.h conventions, as emitted by
; clang -O2 -Xclang -disable-llvm-optzns for riscv64 purecap) lowered by
; mem-annotate-c and consumed by cheri-skip-narrow.
; RUN: opt -S -passes='function(mem-annotate-c,sroa,cheri-skip-narrow)' < %s | FileCheck %s
; RUN: opt -S -passes='function(mem-annotate-c,sroa,cheri-skip-narrow)' -cheri-skip-narrow=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes='function(mem-annotate-c)' < %s | FileCheck %s --check-prefix=LOWER
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@.str = private unnamed_addr addrspace(200) constant [19 x i8] c"mem.alloc_inbounds\00", section "llvm.metadata"
@.file = private unnamed_addr addrspace(200) constant [4 x i8] c"t.c\00", section "llvm.metadata"

declare ptr addrspace(200) @__mem_checked_narrow(ptr addrspace(200), i64) addrspace(200)
declare void @llvm.var.annotation.p200.p200(ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200)) addrspace(200)
declare void @abort() addrspace(200)

; long get(MEM_ALLOC_INBOUNDS long *a, unsigned long n, unsigned long i) {
;   return MEM_CHECKED_INDEX(a, n, i); }
; LOWER-LABEL: define i64 @get(ptr addrspace(200) "mem.alloc_inbounds" %a,
; LOWER-NOT: llvm.var.annotation
; LOWER: call {{.*}}@llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %{{.*}}, i64 %{{.*}}) [ "mem.checked"(ptr addrspace(200) %{{.*}}, i64 %{{.*}}) ], !cheri.access_narrow
; CHECK-LABEL: define i64 @get(
; CHECK-NOT: bounds.set
; CHECK: icmp
; CHECK: getelementptr inbounds i64, ptr addrspace(200) %a
; OFF-LABEL: define i64 @get(
; OFF: @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %a, i64 %{{.*}}), !cheri.access_narrow !{{[0-9]+}}, !mem.checked
define i64 @get(ptr addrspace(200) %a, i64 %n, i64 %i) addrspace(200) {
entry:
  %a.addr = alloca ptr addrspace(200), align 16, addrspace(200)
  store ptr addrspace(200) %a, ptr addrspace(200) %a.addr, align 16
  call void @llvm.var.annotation.p200.p200(ptr addrspace(200) %a.addr, ptr addrspace(200) @.str, ptr addrspace(200) @.file, i32 3, ptr addrspace(200) null)
  %ok = icmp ult i64 %i, %n
  br i1 %ok, label %in, label %oob
oob:
  call void @abort()
  unreachable
in:
  %b = load ptr addrspace(200), ptr addrspace(200) %a.addr, align 16
  %bytes = mul i64 %n, 8
  %nb = call ptr addrspace(200) @__mem_checked_narrow(ptr addrspace(200) %b, i64 %bytes)
  %g = getelementptr inbounds i64, ptr addrspace(200) %nb, i64 %i
  %v = load i64, ptr addrspace(200) %g, align 8
  ret i64 %v
}

; Same access, parameter not annotated: the narrow is kept.
; CHECK-LABEL: define i64 @get_plain(
; CHECK: @llvm.cheri.cap.bounds.set.i64(ptr addrspace(200) %a,
define i64 @get_plain(ptr addrspace(200) %a, i64 %n, i64 %i) addrspace(200) {
entry:
  %ok = icmp ult i64 %i, %n
  br i1 %ok, label %in, label %oob
oob:
  call void @abort()
  unreachable
in:
  %bytes = mul i64 %n, 8
  %nb = call ptr addrspace(200) @__mem_checked_narrow(ptr addrspace(200) %a, i64 %bytes)
  %g = getelementptr inbounds i64, ptr addrspace(200) %nb, i64 %i
  %v = load i64, ptr addrspace(200) %g, align 8
  ret i64 %v
}
