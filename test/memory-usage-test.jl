using QRupdate, TimerOutputs

m = 1000
n = 10
T = ComplexF64
work = rand(T, n)
work2 = rand(T, n)
work3 = rand(T, n)
work4 = rand(T, n)
work5 = rand(T, m)
Rin = zeros(T,n,n)
Ain = zeros(T,m,n)

reset_timer!(QRupdate.to)
for i in 1:n
    a = randn(T, m)
    @timeit QRupdate.to "add col" qraddcol!(Ain, Rin, a, i-1, work, work2, work3, work4, work5)
    Qin = view(Ain, :, 1:i)*inv(view(Rin, 1:i, 1:i))
end

println(QRupdate.to)
println("N of rows: $(m)")


