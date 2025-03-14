module QRupdate

using LinearAlgebra, TimerOutputs
to = TimerOutput()

export qraddcol, qraddcol!, qraddrow, qrdelcol, qrdelcol!, csne, csne!

function swapcols!(M::Matrix{T},i::Int,j::Int) where {T}
    Base.permutecols!!(M, replace(axes(M,2), i=>j, j=>i))
end


"""
Triangular solve `Rx = b`, where `R` is upper triangular of size `realSize x realSize`. The storage of `R` is described in the documentation for `qraddcol!`.
"""
function solveR!(R::AbstractMatrix{T}, b::AbstractVector{T}, sol::AbstractVector{T}) where {T}
    # Note  : R is upper triangular
    # Note 2: I tried implementing a forward substitution algorithm by 
    # hand but in the end in was a bit slower and less accurate for smaller
    # matrix sizes, so I left the abstract implementation. The Upper/Lower functions
    # provide a view only, so they do not incur in further memory allocations. I 
    # verified this with BenchmarkTooks. 
    # N Barnafi 06/11/24 
    ldiv!(sol, UpperTriangular(R), b)
end

"""
Triangular solve `R'x = b`, where `R` is upper triangular of size `realSize x realSize`. The storage of `R` is described in the documentation for `qraddcol!`.
"""
function solveRT!(R::AbstractMatrix{T}, b::AbstractVector{T}, sol::AbstractVector{T}) where {T}
    # Note: R is upper triangular.
    # Note 2: We solve for the conjugate transpose.
    ldiv!(sol, LowerTriangular(R'), b)
end


"""
Add a column to a QR factorization without using Q.

`R = qraddcol(A,R,v)`  adds the m-vector `v` to the QR factorization of the
m-by-n matrix `A` without using `Q`. On entry, `R` is a dense n-by-n upper
triangular matrix such that `R'*R = A'*A`.

`R = qraddcol(A,R,v,β)` is similar to the above, except that the
routine updates the QR factorization of
```
[A; β I],   and   R'*R = (A'*A + β^2*I).
```

`A` should have fewer columns than rows.  `A` and `v` may be sparse or
dense.  On exit, `R` is the (n+1)-by-(n+1) factor corresponding to

```
  Anew = [A        V ],    Rnew = [R   u  ],   Rnew'Rnew = Anew'Anew.
         [beta*I     ]            [  gamma]
         [       beta]
```

The new column `v` is assumed to be nonzero.
If `A` has no columns yet, input `A = []`, `R = []`.
"""
function qraddcol(A::AbstractMatrix{T}, Rin::AbstractMatrix{T}, a::Vector{T}, β::T = zero(T)) where {T}

    n = size(A, 2)
    anorm  = norm(a)
    anorm2 = anorm^2
    β2  = β^2
    if β != 0
        anorm2 = anorm2 + β2
        anorm  = sqrt(anorm2)
    end

    if n == 0
        return reshape([convert(T, anorm)], 1, 1)
    end

    R = UpperTriangular(Rin)

    c      = A'a           # = [A' β*I 0]*[a; 0; β]
    u      = R'\c
    unorm2 = norm(u)^2
    d2     = anorm2 - unorm2

    if d2 > anorm2 #DISABLE 0.01*anorm2     # Cheap case: γ is not too small
        γ = sqrt(d2)
    else
        z = R\u          # First approximate solution to min ||Az - a||
        r = a - A*z
        c = A'r
        if β != 0
            c = c - β2*z
        end
        du = R'\c
        dz = R\du
        z  += dz          # Refine z
      # u  = R*z          # Original:     Bjork's version.
        u  += du          # Modification: Refine u
        r  = a - A*z
        γ = norm(r)       # Safe computation (we know gamma >= 0).
        if !iszero(β)
            γ = sqrt(γ^2 + β2*norm(z)^2 + β2)
        end
    end

    # This seems to be faster than concatenation, ie:
    # [ Rin         u
    #   zeros(1,n)  γ ]
    Rout = zeros(T, n+1, n+1)
    Rout[1:n,1:n] .= R
    Rout[1:n,n+1] .= u
    Rout[n+1,n+1] = γ

    return Rout
end

""" 
This function is identical to the previous one, but it does in-place calculations on R. It requires 
knowing which is the last and new column of A. The logic is that 'A' is allocated at the beginning 
of an iterative procedure, and thus does not require further allocations:

It 0      -->    It 1       -->   It 2  
A = [0  0  0]    A = [a1  0  0]   A = [a1 a2 0]

and so on. This yields that R is

It 0      -->   It 1        -->   It 2
R = [0  0  0    R = [r11  0  0    R = [r11  r12  0
     0  0  0           0  0  0           0  r22  0
     0  0  0]          0  0  0]          0    0  0]
"""
function qraddcol!(A::AbstractMatrix{T}, R::AbstractMatrix{T}, a::AbstractVector{T}, N::Int64, work::AbstractVector{T}, work2::AbstractVector{T}, u::AbstractVector{T}, z::AbstractVector{T}, r::AbstractVector{T}; updateMat::Bool=true, verbose::Bool=false, log::Bool=false, ortho_tol::Float64=1e-14, ortho_max_it::Int=1) where {T}
    #c,u,z,du,dz are R^n. Only r is R^m
    #c -> work; du -> work2. dz is redundant

    m, n = size(A)
    @assert size(work,1) == n "Expected "*string(n)*", actual size: " * string(size(work))
    @assert size(work2,1) == n
    @assert size(u,1) == n
    @assert size(z,1) == n
    @assert size(r,1) == m

    @timeit to "Extract views" begin
    if N < n
        cols = 1:N
        Atr = view(A, :, cols) #truncated
        Rtr = view(R, cols, cols)
        work_tr = view(work, cols)
        work2_tr = view(work2, cols)
        u_tr = view(u, cols)
        z_tr = view(z, cols)
    else
        Atr = A
        Rtr = R
        work_tr = work
        work2_tr = work2
        u_tr = u
        z_tr = z
    end
    end # Extract views"

    anorm = norm(a)
    anorm2 = anorm^2

    @timeit to "Base case" begin
    if N == 0
        # First iteration is simpler
        anorm  = sqrt(anorm2)
        R[1,1] = anorm
        updateMat && view(A,:,N+1) .= a
        return 0
    end
    end #timeit Base case
    

    # work := c = A'a
    @timeit to "Default iteration" begin
    @timeit to "A'a" mul!(work_tr, Atr', a)
    @timeit to "solveRT" solveRT!(Rtr, work_tr, u_tr) #u = R'\c = R'\work
    @timeit to "solveR" solveR!(Rtr, u_tr, z_tr) #z = R\u  
    @timeit to "copy" copy!(r, a)
    @timeit to "mul!" mul!(r, Atr, z_tr, -1, 1) #r = a - A*z
    γ = norm(r)
    @timeit to "mul: c=A'r" mul!(work_tr, Atr', r) # r := c = A'r
    err = norm(work_tr) / sqrt(anorm2)
    end # timeit Default iteration

    # Iterative refinement
    i = 0
    if err < ortho_tol
        @timeit to "No refinement update" begin
        view(R,1:N,N+1) .= u_tr
        R[N+1,N+1] = γ
        updateMat && view(A,:,N+1) .= a
        end # timeit No refinement
    else
        @timeit "Reorthogonalize" while err > ortho_tol && i < ortho_max_it

            solveRT!(Rtr, work_tr, work2_tr) # work2 := du = R'\c
            axpy!(1.0, work2_tr, u_tr) # Refine u
            solveR!(Rtr, work2_tr, work_tr) # work := dz = R\du
            axpy!(1.0, work_tr, z_tr) #z  += dz          # Refine z

            copy!(r, a)
            mul!(r, Atr, z_tr, -1.0, 1.0) #r = a - A*z
            γ = norm(r)
            mul!(work_tr, Atr', r) # work := c = A'r

            err = norm(work_tr) / sqrt(anorm2)
            i += 1
        end # while
        verbose && println("      *** $(i) reorthogonalization steps. Error:", err)

        @timeit to axpy!(1, work2_tr, u_tr)
        @timeit to "Update R" view(R,1:N,N+1) .= u_tr
        @timeit to "Update R" R[N+1,N+1] = γ
        @timeit "Update A" updateMat && view(A,:,N+1) .= a
        log && return i
    end # if
    return 0
end

"""
Add a row and update a Q-less QR factorization.

`qraddrow!(R, a)` returns the triangular part of a QR factorization of `[A; a]`, where `A = QR` for some `Q`.  The argument `a` should be a row
vector.
"""
function qraddrow(R::AbstractMatrix{T}, a::AbstractMatrix{T}) where {T}

    n = size(R,1)
    @inbounds for k in 1:n
        G, r = givens( R[k,k], a[k], 1, 2 )
        B = G * [ reshape(R[k,k:n], 1, n-k+1)
                  reshape(a[:,k:n], 1, n-k+1) ]
        R[k,k:n] = B[1,:]
        a[  k:n] = B[2,:]
    end
    return R
end

"""
Delete the k-th column and update a Q-less QR factorization.

`R = qrdelcol(R,k)` deletes the k-th column of the upper-triangular
`R` and restores it to upper-triangular form.  On input, `R` is an n x
n upper-triangular matrix.  On output, `R` is an n-1 x n-1 upper
triangle.

    18 Jun 2007: First version of QRdelcol.m.
                 Michael Friedlander (mpf@cs.ubc.ca) and
                 Michael Saunders (saunders@stanford.edu)
                 To allow for R being sparse,
                 we eliminate the k-th row of the usual
                 Hessenberg matrix rather than its subdiagonals,
                 as in Reid's Bartel-Golub LU update and also
                 the Forrest-Tomlin update.
                 (But Matlab will still be pretty inefficient.)
    18 Jun 2007: R is now the exact size on entry and exit.
    30 Dec 2015: Translate to Julia.
"""
function qrdelcol(R::AbstractMatrix{T}, k::Integer) where {T}

    m = size(R,1)
    R = R[:,1:m .!= k]          # Delete the k-th column
    n = size(R,2)               # Should have m=n+1

    for j in k:n                # Forward sweep to reduce k-th row to zeros
        G, y = givens(R[j+1,j], R[k,j], 1, 2)
        R[j+1,j] = y
        if j<n && G.s != 0
            @inbounds for i in j+1:n
                tmp = G.c*R[j+1,i] + G.s*R[k,i]
                R[k,i] = G.c*R[k,i] - conj(G.s)*R[j+1,i]
                R[j+1,i] = tmp
            end
        end
    end
    R = R[1:m .!= k, :]         # Delete the k-th row
    return R
end

"""
This function is identical to the previous one, but instead leaves R
with a column of zeros. This is useful to avoid copying the matrix. 
"""
function qrdelcol!(A::AbstractMatrix{T}, R::AbstractMatrix{T}, k::Integer) where {T}

    # Note that R is n x n
    m, n = size(A)
    mR,nR = size(R)
    
    # Shift columns. This is apparently faster than copying views.
    @inbounds for j in (k+1):n
        R[:,j-1] .= @view R[:, j]
        A[:,j-1] .= @view A[:, j]
    end
    A[:,n] .= zero(T)
    R[:,n] .= zero(T)

    @inbounds for j in k:(nR-1)          # Forward sweep to reduce k-th row to zeros
        G, y = givens(R[j+1,j], R[k,j], 1, 2)
        R[j+1,j] = y
        if j<n && !iszero(G.s)
            for i in j+1:n
                tmp = G.c*R[j+1,i] + G.s*R[k,i]
                R[k,i] = G.c*R[k,i] - conj(G.s)*R[j+1,i]
                R[j+1,i] = tmp
            end
        end
    end
    #end # timeit givens downdate

    # Shift k-th row. We skipped the removed column.
    @inbounds for j in k:(n-1)
        for i in k:j
            R[i,j] = R[i+1, j]
        end
        R[j+1,j] = zero(T)
    end
end

"""
    x, r = csne(R, A, b)

solves the least-squares problem

    minimize  ||r||_2,  r := b - A*x

using the corrected semi-normal equation approach described by Bjork (1987). Assumes that `R` is upper triangular.
"""
function csne(Rin::AbstractMatrix{T}, A::AbstractMatrix{T}, b::Vector{T}) where {T}

    R = UpperTriangular(Rin)
    q = A'b
    x = R' \ q

    # bnorm2 = sum(abs2, b)
    # xnorm2 = sum(abs2, x)
    # d2 = bnorm2 - xnorm2

    x = R \ x

    # Apply one step of iterative refinement.
    r = b - A*x
    q = A'r
    dx = R' \ q
    dx = R  \ dx
    x += dx
    r = b - A*x
    return (x, r)
end

function csne!(R::RT, A::AT, b::bT, sol::solT, work::wT, work2::w2T, u::uT,  r::rT, N::Int; verbose::Bool=false, log::Bool=false, ortho_tol::Float64=1e-14, ortho_max_it::Int=1) where {RT,AT,bT,solT,wT,w2T,uT,rT}
    #c,u,sol,du are R^n. Only r is R^m
    #c -> work; du -> work2. dsol is redundant.

    m, n = size(A)
    @assert size(sol,1) == n
    @assert size(work,1) == n
    @assert size(work2,1) == n
    @assert size(u,1) == n
    @assert size(r,1) == m
    if N < n
        cols = 1:N
        Atr = view(A, :, cols) #truncated
        Rtr = view(R, cols, cols)
        work_tr = view(work, cols)
        work2_tr = view(work2, cols)
        u_tr = view(u, cols)
        sol_tr = view(sol, cols)
    else
        Atr = A
        Rtr = R
        work_tr = work
        work2_tr = work2
        u_tr = u
        sol_tr = sol
    end
    bnorm = norm(b)
    bnorm2 = bnorm^2
    # work := c = A'b
    mul!(work_tr, Atr', b)
    solveRT!(Rtr, work_tr, u_tr)

    solveR!(Rtr, u_tr, sol_tr) #z = R\u  
    copy!(r, b)
    mul!(r, Atr, sol_tr, -1, 1) #r = b - A*z
    mul!(work_tr, Atr', r) # r := c = A'r
    err = norm(work_tr) / bnorm

    i = 0
    while err > ortho_tol && i < ortho_max_it

        solveRT!(Rtr, work_tr, work2_tr) # work2 := du = R'\c
        solveR!(Rtr, work2_tr, work_tr) # work := dz = R\du
        axpy!(1.0, work_tr, sol_tr) #z  += dz          # Refine z

        copy!(r, b)
        mul!(r, Atr, sol_tr, -1.0, 1.0) #r = b - A*z
        mul!(work_tr, Atr', r) # work := c = A'r

        err = norm(work_tr) / bnorm
        i += 1

    end

    i > 0 && verbose && println("      *** $(i) CSNE reorthogonalization steps. Error:", err)
    log && return i
end

end # module
