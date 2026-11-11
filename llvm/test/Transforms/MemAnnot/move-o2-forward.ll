; [LLM-generated] M7.1a. Inlined from_elem shape: the callee copied its local
; into the return slot and emitted mem.move after that copy; the caller then
; copies the return slot onward. MemCpyOpt's memcpy-memcpy forward used to
; rewrite the later copy to read the original local and leave it after the
; fact (lv6_churn: mem.move(%v.i); memcpy %c <- %v.i; mem.move(%v.i)).
; The fact clobbers its slot, so the source copy stays before the fact.
;
; RUN: opt -S -passes=memcpyopt < %s | FileCheck %s
; RUN: opt -S -O2 < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @llvm.mem.fact()
declare ptr addrspace(200) @alloc(i64)

define void @forward(ptr addrspace(200) noalias %c) {
  %v = alloca [48 x i8], align 16, addrspace(200)
  %tmp = alloca [48 x i8], align 16, addrspace(200)
  %buf = call ptr addrspace(200) @alloc(i64 32)
  store ptr addrspace(200) %buf, ptr addrspace(200) %v, align 16
  %len = getelementptr inbounds i8, ptr addrspace(200) %v, i64 16
  store i64 4, ptr addrspace(200) %len, align 8
  %cap = getelementptr inbounds i8, ptr addrspace(200) %v, i64 32
  store i64 4, ptr addrspace(200) %cap, align 8
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 48, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %c, ptr addrspace(200) %tmp, i64 48, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %tmp) ]
  ret void
}
; CHECK-LABEL: define void @forward(
; The copy of %v is not after its fact. The onward copy may still read %tmp.
; CHECK: @llvm.memcpy{{.*}}%v,
; CHECK: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
; CHECK-NOT: @llvm.memcpy{{.*}}%v,
; CHECK: ret void

; A single copy already followed by the fact stays in that order at -O2.
define void @after_only(ptr addrspace(200) noalias %c) {
  %v = alloca [48 x i8], align 16, addrspace(200)
  %buf = call ptr addrspace(200) @alloc(i64 32)
  store ptr addrspace(200) %buf, ptr addrspace(200) %v, align 16
  %len = getelementptr inbounds i8, ptr addrspace(200) %v, i64 16
  store i64 4, ptr addrspace(200) %len, align 8
  %cap = getelementptr inbounds i8, ptr addrspace(200) %v, i64 32
  store i64 4, ptr addrspace(200) %cap, align 8
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %c, ptr addrspace(200) %v, i64 48, i1 false)
  call void @llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
  ret void
}
; CHECK-LABEL: define void @after_only(
; CHECK: @llvm.memcpy{{.*}}%v,
; CHECK: call {{.*}}@llvm.mem.fact() [ "mem.move"(ptr addrspace(200) %v) ]
; CHECK-NOT: @llvm.memcpy
; CHECK: ret void
