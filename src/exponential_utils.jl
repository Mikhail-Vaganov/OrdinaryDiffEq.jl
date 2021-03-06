# exponential_utils.jl
# Contains functions related to the evaluation of scalar/matrix phi functions 
# that are used by the exponential integrators.
#
# TODO: write a version of `expm!` that is non-allocating.

###################################################
# Dense algorithms

"""
    phi(z,k[;cache]) -> [phi_0(z),phi_1(z),...,phi_k(z)]

Compute the scalar phi functions for all orders up to k.

The phi functions are defined as

```math
\\varphi_0(z) = \\exp(z),\\quad \\varphi_k(z+1) = \\frac{\\varphi_k(z) - 1}{z} 
```

Instead of using the recurrence relation, which is numerically unstable, a 
formula given by Sidje is used (Sidje, R. B. (1998). Expokit: a software 
package for computing matrix exponentials. ACM Transactions on Mathematical 
Software (TOMS), 24(1), 130-156. Theorem 1).
"""
function phi(z::T, k::Integer; cache=nothing) where {T <: Number}
  # Construct the matrix
  if cache == nothing
    cache = zeros(T, k+1, k+1)
  else
    fill!(cache, zero(T))
  end
  cache[1,1] = z
  for i = 1:k
    cache[i,i+1] = one(T)
  end
  P = Base.LinAlg.expm!(cache)
  return P[1,:]
end

"""
    phimv_dense(A,v,k[;cache]) -> [phi_0(A)v phi_1(A)v ... phi_k(A)v]

Compute the matrix-phi-vector products for small, dense `A`. `k`` >= 1.

The phi functions are defined as

```math
\\varphi_0(z) = \\exp(z),\\quad \\varphi_k(z+1) = \\frac{\\varphi_k(z) - 1}{z} 
```

Instead of using the recurrence relation, which is numerically unstable, a 
formula given by Sidje is used (Sidje, R. B. (1998). Expokit: a software 
package for computing matrix exponentials. ACM Transactions on Mathematical 
Software (TOMS), 24(1), 130-156. Theorem 1).
"""
function phimv_dense(A, v, k; cache=nothing)
  w = Matrix{eltype(A)}(length(v), k+1)
  phimv_dense!(w, A, v, k; cache=cache)
end
"""
    phimv_dense!(w,A,v,k[;cache]) -> w

Non-allocating version of `phimv_dense`.
"""
function phimv_dense!(w::AbstractMatrix{T}, A::AbstractMatrix{T}, 
  v::AbstractVector{T}, k::Integer; cache=nothing) where {T <: Number}
  @assert size(w, 1) == size(A, 1) == size(A, 2) == length(v) "Dimension mismatch"
  @assert size(w, 2) == k+1 "Dimension mismatch"
  m = length(v)
  # Construct the extended matrix
  if cache == nothing
    cache = zeros(T, m+k, m+k)
  else
    @assert size(cache) == (m+k, m+k) "Dimension mismatch"
    fill!(cache, zero(T))
  end
  cache[1:m, 1:m] = A
  cache[1:m, m+1] = v
  for i = m+1:m+k-1
    cache[i, i+1] = one(T)
  end
  P = Base.LinAlg.expm!(cache)
  # Extract results
  @views A_mul_B!(w[:, 1], P[1:m, 1:m], v)
  @inbounds for i = 1:k
    @inbounds for j = 1:m
      w[j, i+1] = P[j, m+i]
    end
  end
  return w
end

"""
    phim(A,k[;cache]) -> [phi_0(A),phi_1(A),...,phi_k(A)]

Compute the matrix phi functions for all orders up to k. `k` >= 1.

The phi functions are defined as
  
```math
\\varphi_0(z) = \\exp(z),\\quad \\varphi_k(z+1) = \\frac{\\varphi_k(z) - 1}{z} 
```

Calls `phimv_dense` on each of the basis vectors to obtain the answer.
"""
phim(x::Number, k) = phi(x, k) # fallback
function phim(A, k; caches=nothing)
  m = size(A, 1)
  out = [Matrix{eltype(A)}(m, m) for i = 1:k+1]
  phim!(out, A, k; caches=caches)
end
"""
    phim!(out,A,k[;caches]) -> out

Non-allocating version of `phim`.
"""
function phim!(out::Vector{Matrix{T}}, A::AbstractMatrix{T}, k::Integer; caches=nothing) where {T <: Number}
  m = size(A, 1)
  @assert length(out) == k + 1 && all(P -> size(P) == (m,m), out) "Dimension mismatch"
  if caches == nothing
    e = Vector{T}(m)
    W = Matrix{T}(m, k+1)
    C = Matrix{T}(m+k, m+k)
  else
    e, W, C = caches
    @assert size(e) == (m,) && size(W) == (m, k+1) && size(C) == (m+k, m+k) "Dimension mismatch"
  end
  @inbounds for i = 1:m
    fill!(e, zero(T)); e[i] = one(T) # e is the ith basis vector
    phimv_dense!(W, A, e, k; cache=C) # W = [phi_0(A)*e phi_1(A)*e ... phi_k(A)*e]
    @inbounds for j = 1:k+1
      @inbounds for s = 1:m
        out[j][s, i] = W[s, j]
      end
    end
  end
  return out
end

##############################################
# Krylov algorithms
"""
    KrylovSubspace{T}(n,[maxiter=30]) -> Ks

Constructs an uninitialized Krylov subspace, which can be filled by `arnoldi!`.

The dimension of the subspace, `Ks.m`, can be dynamically altered. `Ks[:V]` and 
`Ks[:H]` provides a view into the larger arrays `Ks.V` and `Ks.H` compatible 
with the subspace dimension. `Ks.m` should be smaller than `maxiter`, the 
maximum allowed arnoldi iterations.

    resize!(Ks, maxiter) -> Ks

Resize `Ks` to a different `maxiter`, keeping its contents.

This is an expensive operation and should be used scarsely.
"""
mutable struct KrylovSubspace{B, T}
  m::Int        # subspace dimension
  beta::B       # norm(b,2)
  V::Matrix{T}  # orthonormal bases
  H::Matrix{T}  # Gram-Schmidt coefficients
  KrylovSubspace{T}(n::Integer, maxiter::Integer=30) where {T} = new{real(T), T}(
    0, zero(real(T)), Matrix{T}(n, maxiter), zeros(T, maxiter, maxiter))
end
maxiter(Ks::KrylovSubspace) = size(Ks.V, 2)
function Base.getindex(Ks::KrylovSubspace, which::Symbol)
  if which == :V
    return @view(Ks.V[:, 1:Ks.m])
  elseif which == :H
    return @view(Ks.H[1:Ks.m, 1:Ks.m])
  else
    throw(ArgumentError(repr(which)))
  end
end
function Base.resize!(Ks::KrylovSubspace{B,T}, maxiter::Integer) where {B,T}
  prevsize = maxiter(Ks)
  if prevsize <= maxiter
    V = Matrix{T}(size(Ks.V, 1), maxiter)
    H = zeros(T, maxiter, maxiter)
    V[:, 1:prevsize] = Ks.V
    H[1:prevsize, 1:prevsize] = Ks.H
  else
    # Resizing to a smaller size is not necessary, this is just for the sake 
    # of completeness.
    V = Ks.V[:, 1:maxiter]
    H = Ks.H[1:maxiter, 1:maxiter]
  end
  Ks.V = V; Ks.H = H
  return Ks
end
function Base.show(io::IO, Ks::KrylovSubspace)
  println(io, "$(Ks.m)-dimensional Krylov subspace with fields")
  println(io, "beta: $(Ks.beta)")
  print(io, "V: ")
  println(IOContext(io, limit=true), Ks[:V])
  print(io, "H: ")
  println(IOContext(io, limit=true), Ks[:H])
end

"""
    arnoldi(A,b[;m,tol,norm,cache]) -> Ks

Performs `m` anoldi iterations to obtain the Krylov subspace K_m(A,b).

The n x m unitary basis vectors `Ks[:V]` and the m x m upper Heisenberg 
matrix `Ks[:H]` are related by the recurrence formula

```
v_1=b,\\quad Av_j = \\sum_{i=1}^{j+1}h_{ij}v_i\\quad(j = 1,2,\\ldots,m)
```

Refer to `KrylovSubspace` for more information regarding the output.

Happy-breakdown occurs whenver `norm(v_j) < tol * norm(A, Inf)`, in this case 
the dimension of `Ks` is smaller than `m`.
"""
function arnoldi(A, b; m=min(30, size(A, 1)), tol=1e-7, norm=Base.norm, 
  cache=nothing)
  Ks = KrylovSubspace{eltype(b)}(length(b), m)
  arnoldi!(Ks, A, b; m=m, tol=tol, norm=norm, cache=cache)
end
"""
    arnoldi!(Ks,A,b[;tol,m,norm,cache]) -> Ks

Non-allocating version of `arnoldi`.
"""
function arnoldi!(Ks::KrylovSubspace{B, T}, A, b::AbstractVector{T}; tol=1e-7, 
  m=min(maxiter(Ks), size(A, 1)), norm=Base.norm, cache=nothing) where {B, T <: Number}
  if m > maxiter(Ks)
    resize!(Ks, m)
  end
  V, H = Ks.V, Ks.H
  vtol = tol * norm(A, Inf)
  # Safe checks
  n = size(V, 1)
  @assert length(b) == size(A,1) == size(A,2) == n "Dimension mismatch"
  if cache == nothing
    cache = similar(b)
  else
    @assert size(cache) == (n,) "Dimension mismatch"
  end
  # Arnoldi iterations
  Ks.beta = norm(b)
  V[:, 1] = b / Ks.beta
  @inbounds for j = 1:m
    A_mul_B!(cache, A, @view(V[:, j]))
    @inbounds for i = 1:j
      alpha = dot(@view(V[:, i]), cache)
      H[i, j] = alpha
      Base.axpy!(-alpha, @view(V[:, i]), cache)
    end
    beta = norm(cache)
    if beta < vtol || j == m
      # happy-breakdown or maximum iteration is reached
      Ks.m = j
      return Ks
    end
    H[j+1, j] = beta
    @inbounds for i = 1:n
      V[i, j+1] = cache[i] / beta
    end
  end
end

"""
    expmv(t,A,b; kwargs) -> exp(tA)b

Compute the matrix-exponential-vector product using Krylov.

A Krylov subspace is constructed using `arnoldi` and `expm!` is called 
on the Heisenberg matrix. Consult `arnoldi` for the values of the keyword 
arguments.
"""
function expmv(t, A, b; m=min(30, size(A, 1)), tol=1e-7, norm=Base.norm, cache=nothing)
  Ks = arnoldi(A, b; m=m, tol=tol, norm=norm)
  w = similar(b)
  expmv!(w, t, Ks; cache=cache)
end
"""
    expmv!(w,t,Ks[;cache]) -> w

Non-allocating version of `expmv` that uses precomputed Krylov subspace `Ks`.
"""
function expmv!(w::Vector{T}, t::Number, Ks::KrylovSubspace{B, T}; 
  cache=nothing) where {B, T <: Number}
  m, beta, V, H = Ks.m, Ks.beta, Ks[:V], Ks[:H]
  @assert length(w) == size(V, 1) "Dimension mismatch"
  if cache == nothing
    cache = Matrix{T}(m, m)
  else
    # The cache may have a bigger size to handle different values of m.
    # Here we only need a portion.
    cache = @view(cache[1:m, 1:m])
  end
  @. cache = t * H
  expH = Base.LinAlg.expm!(cache)
  scale!(beta, A_mul_B!(w, V, @view(expH[:,1]))) # exp(A) ≈ norm(b) * V * exp(H)e
end

"""
    phimv(t,A,b,k; kwargs) -> [phi_0(tA)b phi_1(tA)b ... phi_k(tA)b]

Compute the matrix-phi-vector products using Krylov. `k` >= 1.

The phi functions are defined as

```math
\\varphi_0(z) = \\exp(z),\\quad \\varphi_k(z+1) = \\frac{\\varphi_k(z) - 1}{z} 
```

A Krylov subspace is constructed using `arnoldi` and `phimv_dense` is called 
on the Heisenberg matrix. Consult `arnoldi` for the values of the keyword 
arguments.
"""
function phimv(t, A, b, k; m=min(30, size(A, 1)), tol=1e-7, norm=Base.norm, 
  caches=nothing)
  Ks = arnoldi(A, b; m=m, tol=tol, norm=norm)
  w = Matrix{eltype(b)}(length(b), k+1)
  phimv!(w, t, Ks, k; caches=caches)
end
"""
    phimv!(w,t,Ks,k[;caches]) -> w

Non-allocating version of 'phimv' that uses precomputed Krylov subspace `Ks`.
"""
function phimv!(w::Matrix{T}, t::Number, Ks::KrylovSubspace{B, T}, k::Integer; 
  caches=nothing) where {B, T <: Number}
  m, beta, V, H = Ks.m, Ks.beta, Ks[:V], Ks[:H]
  @assert size(w, 1) == size(V, 1) "Dimension mismatch"
  @assert size(w, 2) == k + 1 "Dimension mismatch"
  if caches == nothing
    e = Vector{T}(m)
    Hcopy = Matrix{T}(m, m)
    C1 = Matrix{T}(m + k, m + k)
    C2 = Matrix{T}(m, k + 1)
  else
    e, Hcopy, C1, C2 = caches
    # The caches may have a bigger size to handle different values of m.
    # Here we only need a portion of them.
    e = @view(e[1:m])
    Hcopy = @view(Hcopy[1:m, 1:m])
    C1 = @view(C1[1:m + k, 1:m + k])
    C2 = @view(C2[1:m, 1:k + 1])
  end
  @. Hcopy = t * H
  fill!(e, zero(T)); e[1] = one(T) # e is the [1,0,...,0] basis vector
  phimv_dense!(C2, Hcopy, e, k; cache=C1) # C2 = [ϕ0(H)e ϕ1(H)e ... ϕk(H)e]
  scale!(beta, A_mul_B!(w, V, C2)) # f(A) ≈ norm(b) * V * f(H)e
end
