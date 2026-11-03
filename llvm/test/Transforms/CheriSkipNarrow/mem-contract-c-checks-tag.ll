; LLM-generated test for the local M4.0 prototype: RS_CHECKS_TAG(1, T, tag, 66) +
; RS_RET_REF(uint64_t[32]) on a typed accessor. checks_tag is recorded in the
; canonical "mem.contract" string (verified on the body by mc-check --verify-tag)
; and makes the ref return nullable: no nonnull on the return.
; RUN: opt -S -passes=mem-contract-c < %s | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@s.ref = private unnamed_addr addrspace(200) constant [17 x i8] c"mem.contract.ref\00", section "llvm.metadata"
@s.tag = private unnamed_addr addrspace(200) constant [24 x i8] c"mem.contract.checks_tag\00", section "llvm.metadata"
@s.file = private unnamed_addr addrspace(200) constant [4 x i8] c"t.c\00", section "llvm.metadata"
@a.ret = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 0, i64 256, i64 8 }, section "llvm.metadata"
@a.tag = private unnamed_addr addrspace(200) constant { i32, i64, i64, i32 } { i32 1, i64 0, i64 4, i32 66 }, section "llvm.metadata"
@llvm.global.annotations = appending addrspace(200) global [2 x { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) }] [
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @get, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.ret },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @get, ptr addrspace(200) @s.tag, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.tag }
], section "llvm.metadata"

; CHECK-NOT: llvm.global.annotations
; CHECK: define noundef align 8 "mem.alloc_inbounds" ptr addrspace(200) @get(ptr addrspace(200) %x) addrspace(200) [[A:#[0-9]+]]
; CHECK: attributes [[A]] = { "mem.contract"="ref(ret,256,8);checks_tag(0,0,4,66)" }
define ptr addrspace(200) @get(ptr addrspace(200) %x) addrspace(200) {
entry:
  %t = load i32, ptr addrspace(200) %x, align 4
  %ok = icmp eq i32 %t, 66
  br i1 %ok, label %yes, label %no
yes:
  %f = getelementptr inbounds i8, ptr addrspace(200) %x, i64 16
  %p = load ptr addrspace(200), ptr addrspace(200) %f, align 16
  ret ptr addrspace(200) %p
no:
  ret ptr addrspace(200) null
}
