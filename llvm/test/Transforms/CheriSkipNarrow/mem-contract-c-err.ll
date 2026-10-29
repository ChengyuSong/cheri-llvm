; LLM-generated test for the local M3.1 prototype: malformed contracts are
; diagnosed, not silently lowered.
; RUN: not opt -S -passes=mem-contract-c < %s 2>&1 | FileCheck %s
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@s.slice = private unnamed_addr addrspace(200) constant [19 x i8] c"mem.contract.slice\00", section "llvm.metadata"
@s.ref = private unnamed_addr addrspace(200) constant [17 x i8] c"mem.contract.ref\00", section "llvm.metadata"
@s.bogus = private unnamed_addr addrspace(200) constant [19 x i8] c"mem.contract.bogus\00", section "llvm.metadata"
@s.file = private unnamed_addr addrspace(200) constant [4 x i8] c"t.c\00", section "llvm.metadata"
@a.bad_len = private unnamed_addr addrspace(200) constant { i32, i32, i64, i64 } { i32 1, i32 1, i64 8, i64 8 }, section "llvm.metadata"
@a.not_ptr = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 2, i64 4, i64 4 }, section "llvm.metadata"
@a.short = private unnamed_addr addrspace(200) constant { i32 } { i32 1 }, section "llvm.metadata"
@llvm.global.annotations = appending addrspace(200) global [4 x { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) }] [
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @f, ptr addrspace(200) @s.slice, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.bad_len },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @f, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.not_ptr },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @f, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.short },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @f, ptr addrspace(200) @s.bogus, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.short }
], section "llvm.metadata"

; CHECK-DAG: error: mem.contract.ref on f: expected 3 integer arguments
; CHECK-DAG: error: mem.contract: unknown contract 'mem.contract.bogus'
; CHECK-DAG: error: mem.contract on f: slice length index 1 is not an integer parameter
; CHECK-DAG: error: mem.contract on f: ref index 2 is not a pointer parameter/return
declare void @f(ptr addrspace(200), i64)
