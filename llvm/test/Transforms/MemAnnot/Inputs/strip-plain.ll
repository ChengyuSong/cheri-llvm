declare void @sink(i64, ptr)
declare void @panic(i64) noreturn cold

define i32 @f(i1 %c, ptr %a, ptr %b, i64 %x, i64 %i) {
  call void @sink(i64 %x, ptr %a)
  %g = getelementptr inbounds i32, ptr %a, i64 %i
  %v = load i32, ptr %g
  %ok = icmp ult i64 %i, 4
  br i1 %ok, label %ret, label %fail
ret:
  ret i32 %v
fail:
  call void @panic(i64 %i)
  unreachable
}
