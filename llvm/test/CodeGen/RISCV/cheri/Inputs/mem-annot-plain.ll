source_filename = "mem-annot"
target datalayout = "e-m:e-p:64:64-pf200:128:128:128:64-i64:64-i128:128-n32:64-S128-A200-P200-G200"

declare void @use(ptr addrspace(200))
declare void @free(ptr addrspace(200))
declare void @panic(i64) noreturn cold

define i32 @f(ptr addrspace(200) %s, i64 %n) addrspace(200) {
entry:
  %buf = alloca [4 x i32], align 4, addrspace(200)
  store i32 1, ptr addrspace(200) %buf, align 4
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %ok ]
  %acc = phi i32 [ 0, %entry ], [ %acc1, %ok ]
  %c = icmp ult i64 %i, 16
  br i1 %c, label %ok, label %fail
ok:
  %g = getelementptr inbounds i32, ptr addrspace(200) %s, i64 %i
  %v = load i32, ptr addrspace(200) %g, align 4
  %acc1 = add i32 %acc, %v
  %i1 = add nuw i64 %i, 1
  %e = icmp ult i64 %i1, %n
  br i1 %e, label %loop, label %exit
exit:
  %b = load i32, ptr addrspace(200) %buf, align 4
  %r = add i32 %acc1, %b
  call void @free(ptr addrspace(200) %s)
  ret i32 %r
fail:
  call void @panic(i64 %i)
  unreachable
}

