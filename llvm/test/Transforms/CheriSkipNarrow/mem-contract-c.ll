; LLM-generated test for the local M3.1 prototype (mem_contract.h lowering).
; The C header mirror of Rust type contracts arrives as function-level
; annotate("mem.contract.<kind>", ...) entries (as clang emits them).
; RUN: opt -S -passes=mem-contract-c < %s | FileCheck %s
; RUN: opt -S -passes=mem-contract-c -mem-contract-spatial-only < %s | FileCheck %s --check-prefix=SPATIAL
target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

@s.slice = private unnamed_addr addrspace(200) constant [19 x i8] c"mem.contract.slice\00", section "llvm.metadata"
@s.slice_mut = private unnamed_addr addrspace(200) constant [23 x i8] c"mem.contract.slice_mut\00", section "llvm.metadata"
@s.ref = private unnamed_addr addrspace(200) constant [17 x i8] c"mem.contract.ref\00", section "llvm.metadata"
@s.ref_mut = private unnamed_addr addrspace(200) constant [21 x i8] c"mem.contract.ref_mut\00", section "llvm.metadata"
@s.box = private unnamed_addr addrspace(200) constant [17 x i8] c"mem.contract.box\00", section "llvm.metadata"
@s.cstr = private unnamed_addr addrspace(200) constant [18 x i8] c"mem.contract.cstr\00", section "llvm.metadata"
@s.keep = private unnamed_addr addrspace(200) constant [18 x i8] c"mem.contract.keep\00", section "llvm.metadata"
@s.rb = private unnamed_addr addrspace(200) constant [25 x i8] c"mem.contract.ret_borrows\00", section "llvm.metadata"
@s.other = private unnamed_addr addrspace(200) constant [6 x i8] c"other\00", section "llvm.metadata"
@s.file = private unnamed_addr addrspace(200) constant [4 x i8] c"t.c\00", section "llvm.metadata"
@a.slice_u64 = private unnamed_addr addrspace(200) constant { i32, i32, i64, i64 } { i32 1, i32 2, i64 8, i64 8 }, section "llvm.metadata"
@a.slice_u8 = private unnamed_addr addrspace(200) constant { i32, i32, i64, i64 } { i32 1, i32 2, i64 1, i64 1 }, section "llvm.metadata"
@a.ret_slice_u32 = private unnamed_addr addrspace(200) constant { i32, i32, i64, i64 } { i32 0, i32 1, i64 4, i64 4 }, section "llvm.metadata"
@a.ref_u32 = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 1, i64 4, i64 4 }, section "llvm.metadata"
@a.ref_pair = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 1, i64 16, i64 8 }, section "llvm.metadata"
@a.ret_ref_u8 = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 0, i64 1, i64 1 }, section "llvm.metadata"
@a.ret_pair = private unnamed_addr addrspace(200) constant { i32, i64, i64 } { i32 0, i64 16, i64 8 }, section "llvm.metadata"
@a.p1 = private unnamed_addr addrspace(200) constant { i32 } { i32 1 }, section "llvm.metadata"
@a.p0 = private unnamed_addr addrspace(200) constant { i32 } zeroinitializer, section "llvm.metadata"

@llvm.global.annotations = appending addrspace(200) global [15 x { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) }] [
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_sum, ptr addrspace(200) @s.slice, ptr addrspace(200) @s.file, i32 1, ptr addrspace(200) @a.slice_u64 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_fill, ptr addrspace(200) @s.slice_mut, ptr addrspace(200) @s.file, i32 2, ptr addrspace(200) @a.slice_u8 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_peek, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 3, ptr addrspace(200) @a.ref_u32 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_bump, ptr addrspace(200) @s.ref_mut, ptr addrspace(200) @s.file, i32 4, ptr addrspace(200) @a.ref_pair },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_drop_box, ptr addrspace(200) @s.box, ptr addrspace(200) @s.file, i32 5, ptr addrspace(200) @a.ref_pair },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_strlen, ptr addrspace(200) @s.cstr, ptr addrspace(200) @s.file, i32 6, ptr addrspace(200) @a.p1 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_register, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 7, ptr addrspace(200) @a.ref_u32 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_register, ptr addrspace(200) @s.keep, ptr addrspace(200) @s.file, i32 7, ptr addrspace(200) @a.p1 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_first, ptr addrspace(200) @s.slice, ptr addrspace(200) @s.file, i32 8, ptr addrspace(200) @a.slice_u8 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_first, ptr addrspace(200) @s.ref, ptr addrspace(200) @s.file, i32 8, ptr addrspace(200) @a.ret_ref_u8 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_first, ptr addrspace(200) @s.rb, ptr addrspace(200) @s.file, i32 8, ptr addrspace(200) @a.p1 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_table, ptr addrspace(200) @s.slice, ptr addrspace(200) @s.file, i32 9, ptr addrspace(200) @a.ret_slice_u32 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_new_pair, ptr addrspace(200) @s.box, ptr addrspace(200) @s.file, i32 10, ptr addrspace(200) @a.ret_pair },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @c_name, ptr addrspace(200) @s.cstr, ptr addrspace(200) @s.file, i32 11, ptr addrspace(200) @a.p0 },
  { ptr addrspace(200), ptr addrspace(200), ptr addrspace(200), i32, ptr addrspace(200) } { ptr addrspace(200) @unrelated, ptr addrspace(200) @s.other, ptr addrspace(200) @s.file, i32 12, ptr addrspace(200) null }
], section "llvm.metadata"

; Consumed entries are removed; unrelated annotations stay.
; CHECK: @llvm.global.annotations = appending addrspace(200) global [1 x {{.*}} @unrelated
; CHECK-NOT: @s.slice =
; CHECK-NOT: @a.slice_u64 =

; RS_SLICE(1, 2, uint64_t): spatial + trusted, borrow for the call.
; CHECK: declare i64 @c_sum(ptr addrspace(200) noalias nofree noundef nonnull readonly align 8 captures(none) "mem.alloc_inbounds" "mem.range"="1:8", i64 noundef range(i64 0, 1152921504606846976)) addrspace(200) [[SUM:#[0-9]+]]
; SPATIAL: declare i64 @c_sum(ptr addrspace(200) nonnull align 8 "mem.alloc_inbounds" "mem.range"="1:8", i64 range(i64 0, 1152921504606846976))
declare i64 @c_sum(ptr addrspace(200), i64)
; RS_SLICE_MUT(1, 2, uint8_t): noalias, no readonly; u8 length range is [0, 2^63).
; CHECK: declare void @c_fill(ptr addrspace(200) noalias nofree noundef nonnull captures(none) "mem.alloc_inbounds" "mem.range"="1:1", i64 noundef range(i64 0, -9223372036854775808))
; SPATIAL: declare void @c_fill(ptr addrspace(200) nonnull "mem.alloc_inbounds" "mem.range"="1:1", i64 range(i64 0, -9223372036854775808))
declare void @c_fill(ptr addrspace(200), i64)
; RS_REF(1, uint32_t)
; CHECK: declare i32 @c_peek(ptr addrspace(200) noalias nofree noundef nonnull readonly align 4 captures(none) dereferenceable(4) "mem.alloc_inbounds")
; SPATIAL: declare i32 @c_peek(ptr addrspace(200) nonnull align 4 dereferenceable(4) "mem.alloc_inbounds")
declare i32 @c_peek(ptr addrspace(200))
; RS_REF_MUT(1, pair_t)
; CHECK: declare void @c_bump(ptr addrspace(200) noalias nofree noundef nonnull align 8 captures(none) dereferenceable(16) "mem.alloc_inbounds")
; SPATIAL: declare void @c_bump(ptr addrspace(200) nonnull align 8 dereferenceable(16) "mem.alloc_inbounds")
declare void @c_bump(ptr addrspace(200))
; RS_BOX(1, pair_t): ownership moves; no dereferenceable, nofree or captures.
; CHECK: declare void @c_drop_box(ptr addrspace(200) noalias noundef nonnull align 8 "mem.alloc_inbounds" "mem.box_family"="__rust_alloc")
; SPATIAL: declare void @c_drop_box(ptr addrspace(200) nonnull align 8 "mem.alloc_inbounds")
declare void @c_drop_box(ptr addrspace(200))
; RS_CSTR(1)
; CHECK: declare i64 @c_strlen(ptr addrspace(200) noalias nofree noundef nonnull readonly captures(none) "mem.alloc_inbounds" "mem.cstr")
; SPATIAL: declare i64 @c_strlen(ptr addrspace(200) nonnull "mem.alloc_inbounds" "mem.cstr")
declare i64 @c_strlen(ptr addrspace(200))
; RS_REF(1, uint32_t) RS_KEEP(1): retained, only the frozen-shared read claim.
; CHECK: declare void @c_register(ptr addrspace(200) noalias nofree noundef nonnull readonly align 4 captures(address, read_provenance) dereferenceable(4) "mem.alloc_inbounds")
declare void @c_register(ptr addrspace(200))
; RS_SLICE(1,2,uint8_t) RS_RET_REF(uint8_t) RS_RET_BORROWS(1)
; CHECK: declare noundef nonnull dereferenceable(1) "mem.alloc_inbounds" ptr addrspace(200) @c_first(ptr addrspace(200) noalias nofree noundef nonnull readonly captures(ret: address, provenance) "mem.alloc_inbounds" "mem.range"="1:1", i64 noundef range(i64 0, -9223372036854775808)) addrspace(200) [[FIRST:#[0-9]+]]
; SPATIAL: declare nonnull dereferenceable(1) "mem.alloc_inbounds" ptr addrspace(200) @c_first(ptr addrspace(200) nonnull "mem.alloc_inbounds" "mem.range"="1:1", i64 range(i64 0, -9223372036854775808))
declare ptr addrspace(200) @c_first(ptr addrspace(200), i64)
; RS_RET_SLICE(1, uint32_t): extent of the return is arg 0 elements of 4 bytes.
; CHECK: declare noundef nonnull align 4 "mem.alloc_inbounds" "mem.range"="0:4" ptr addrspace(200) @c_table(i64 noundef range(i64 0, 2305843009213693952))
declare ptr addrspace(200) @c_table(i64)
; RS_RET_BOX(pair_t): no noalias on returns.
; CHECK: declare noundef nonnull align 8 "mem.alloc_inbounds" "mem.box_family"="__rust_alloc" ptr addrspace(200) @c_new_pair()
; SPATIAL: declare nonnull align 8 "mem.alloc_inbounds" ptr addrspace(200) @c_new_pair()
declare ptr addrspace(200) @c_new_pair()
; RS_RET_CSTR (all-zero args struct folds to zeroinitializer)
; CHECK: declare noundef nonnull "mem.alloc_inbounds" "mem.cstr" ptr addrspace(200) @c_name()
declare ptr addrspace(200) @c_name()
; CHECK: declare void @unrelated() addrspace(200){{$}}
declare void @unrelated()

; Canonical contract record (0-based indices) for the M3.4 manifest.
; CHECK: attributes [[SUM]] = { "mem.contract"="slice(0,1,8,8)" }
; CHECK: attributes [[FIRST]] = { "mem.contract"="slice(0,1,1,1);ref(ret,1,1);ret_borrows(0)" }
