; [LLM-generated] M7.1b. The fact names the owner's buffer-pointer field, which a
; later copy must not read. MemCpyOpt used to forward memcpy(tmp <- v);
; memcpy(c <- tmp) into memcpy(c <- v) at the later site, after the fact.
; The fact clobbers that field, so the copy of v stays in front of it.
; The field escapes, so SROA does not promote it and drop the fact.
;
; RUN: opt -S -passes=memcpyopt < %s | FileCheck %s --check-prefix=COPY
; RUN: opt -S -O2 < %s | FileCheck %s --check-prefix=O2
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @llvm.memcpy.p200.p200.i64(ptr addrspace(200), ptr addrspace(200), i64, i1)
declare void @llvm.mem.fact()
declare ptr addrspace(200) @alloc(i64)
declare void @escape(ptr addrspace(200))

define void @forward(ptr addrspace(200) noalias %c, ptr addrspace(200) %loan) {
  %v = alloca [48 x i8], align 16, addrspace(200)
  %tmp = alloca [48 x i8], align 16, addrspace(200)
  %buf = call ptr addrspace(200) @alloc(i64 32)
  store ptr addrspace(200) %buf, ptr addrspace(200) %v, align 16
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %tmp, ptr addrspace(200) %v, i64 48, i1 false)
  call void @llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %v, ptr addrspace(200) %loan, i64 1) ]
  call void @llvm.memcpy.p200.p200.i64(ptr addrspace(200) %c, ptr addrspace(200) %tmp, i64 48, i1 false)
  call void @escape(ptr addrspace(200) %v)
  ret void
}
; COPY-LABEL: define void @forward(
; COPY: @llvm.memcpy{{.*}}%v,
; COPY: call {{.*}}@llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %v, ptr addrspace(200) %loan, i64 1) ]
; COPY-NOT: @llvm.memcpy{{.*}}%v,
; COPY: ret void
; -O2 may replace the copy with the pointer stored before the fact. It must
; not reload the field, or memcpy it, after the fact.
; O2-LABEL: define void @forward(
; O2: call {{.*}}@llvm.mem.fact() [ "mem.loan_into"(ptr addrspace(200) %v, ptr addrspace(200) %loan, i64 1) ]
; O2-NOT: load {{.*}}%v
; O2-NOT: @llvm.memcpy{{.*}}%v,
; O2: ret void
