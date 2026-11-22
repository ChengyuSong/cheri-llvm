; [LLM-generated] M7.2h: callee store marks at invokes (calls that can unwind).
; The caller fact goes at the start of the normal destination when the invoke is
; that block's single predecessor; the unwind path gets nothing. A normal
; destination with another predecessor gets nothing (the fact would also hold
; on the other path). -cheri-invalidate-stores-into-marks-invoke=false and
; -cheri-invalidate-stores-into-marks=false add nothing at invokes.
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free < %s | FileCheck %s
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stores-into-marks-invoke=false < %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stores-into-marks=false < %s | FileCheck %s --check-prefix=OFF
; RUN: rm -f %t.stats && opt -disable-output -passes=cheri-bounds-lowering -cheri-invalidate=loan+free -cheri-invalidate-stats-out=%t.stats < %s && FileCheck %s --check-prefix=STATS < %t.stats

target datalayout = "e-m:e-pf200:128:128:128:64-p:64:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @free(ptr addrspace(200))
declare void @use(ptr addrspace(200))
declare i32 @pers(...)
declare void @put(ptr addrspace(200) "mem.stores_into_dst"="1" %r, ptr addrspace(200) "mem.stores_into"="1:16" %p)

; Single-predecessor normal destination: fact at its start, clear at the free.
define void @inv(ptr addrspace(200) %heap, ptr addrspace(200) %buf) personality ptr addrspace(200) @pers {
entry:
  invoke void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
          to label %cont unwind label %lp
cont:
  call void @use(ptr addrspace(200) %heap)
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
lp:
  %l = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %l
}
; CHECK-LABEL: define void @inv(
; CHECK: invoke {{.*}}@put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
; CHECK: cont:
; CHECK-NEXT: @llvm.cheri.cap.address.get.i64(ptr addrspace(200) %buf)
; CHECK: call {{.*}}@use(ptr addrspace(200) %heap)
; CHECK: %[[S:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(200) %heap, i64 16
; CHECK: store volatile ptr addrspace(200) null, ptr addrspace(200) %[[S]], align 16
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)
; CHECK: lp:
; OFF-LABEL: define void @inv(
; OFF-NOT: store volatile ptr addrspace(200) null
; OFF: call {{.*}}@free(ptr addrspace(200) %buf)

; The normal destination has a second predecessor: nothing.
define void @inv_join(ptr addrspace(200) %heap, ptr addrspace(200) %buf, i1 %c) personality ptr addrspace(200) @pers {
entry:
  br i1 %c, label %call, label %join
call:
  invoke void @put(ptr addrspace(200) %heap, ptr addrspace(200) %buf)
          to label %join unwind label %lp
join:
  call void @free(ptr addrspace(200) %buf) [ "mem.free"(ptr addrspace(200) %buf) ]
  ret void
lp:
  %l = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %l
}
; CHECK-LABEL: define void @inv_join(
; CHECK-NOT: store volatile ptr addrspace(200) null
; CHECK: call {{.*}}@free(ptr addrspace(200) %buf)

; STATS: cheri-stores-into-marks: {{.*}} calls=1 facts=1
