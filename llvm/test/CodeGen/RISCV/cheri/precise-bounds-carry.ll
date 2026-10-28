; Precise-bounds alignment when rounding a length up carries into the next exponent.
; 8185 (0x1ff9) bytes round to 0x2000, which needs 16-byte alignment, and 16376
; (0x3ff8) bytes round to 0x4000, which needs 32-byte alignment (CRAM/CRRL on
; QEMU-CHERI and CHERI-Toooba). The mask used to be computed from the unrounded
; length (8 and 16), so bounds on these objects could overlap their neighbours.
; RUN: %riscv64_cheri_purecap_llc -mattr=+d -verify-machineinstrs -O2 < %s | FileCheck %s

@x0 = addrspace(200) global [32 x i8] zeroinitializer, align 1
@b = addrspace(200) global [5000 x i8] zeroinitializer, align 1
@d = addrspace(200) global [8185 x i8] zeroinitializer, align 1
@c = addrspace(200) global [16376 x i8] zeroinitializer, align 1

declare void @use(ptr addrspace(200)) addrspace(200)

define ptr addrspace(200) @gb() addrspace(200) nounwind { ret ptr addrspace(200) @b }
define ptr addrspace(200) @gc() addrspace(200) nounwind { ret ptr addrspace(200) @c }
define ptr addrspace(200) @gd() addrspace(200) nounwind { ret ptr addrspace(200) @d }
define ptr addrspace(200) @gx() addrspace(200) nounwind { ret ptr addrspace(200) @x0 }

; The escaping 16376-byte alloca is aligned to 32, which realigns the stack.
; CHECK-LABEL: stack:
; CHECK:         andi a0, sp, -32
; CHECK-NEXT:    csetaddr sp, sp, a0
; CHECK:         csetbounds a0, a0, 24
; CHECK:         lui [[LEN:a[0-9]+]], 4
; CHECK-NEXT:    cincoffset [[P:a[0-9]+]], sp, 32
; CHECK-NEXT:    csetbounds a0, [[P]], [[LEN]]
define void @stack() addrspace(200) nounwind {
  %s = alloca [24 x i8], align 8, addrspace(200)
  %a = alloca [16376 x i8], align 1, addrspace(200)
  call void @use(ptr addrspace(200) %s)
  call void @use(ptr addrspace(200) %a)
  ret void
}

; Globals are emitted after the functions.
; CHECK:       .p2align 3, 0x0
; CHECK-NEXT: b:
; CHECK-NEXT:  .zero 5000
; CHECK:       .p2align 4, 0x0
; CHECK-NEXT: d:
; CHECK-NEXT:  .zero 8185
; CHECK-NEXT:  .zero 7
; CHECK:       .p2align 5, 0x0
; CHECK-NEXT: c:
; CHECK-NEXT:  .zero 16376
; CHECK-NEXT:  .zero 8
