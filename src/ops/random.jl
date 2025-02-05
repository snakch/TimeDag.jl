abstract type RandBase{T} <: UnaryNodeOp{T} end

mutable struct RandState{RNG<:Random.AbstractRNG} <: NodeEvaluationState
    rng::RNG
end

always_ticks(::RandBase) = true
time_agnostic(::RandBase) = true
value_agnostic(::RandBase) = true
# Note that we should never mutate the random state on the node op itself.
create_operator_evaluation_state(::Tuple{Node}, op::RandBase) = RandState(copy(op.rng))

struct Rand{T<:Real} <: RandBase{T}
    rng::Random.AbstractRNG
end

Base.hash(x::Rand, h::UInt64) = hash(x.rng, hash(:Rand, h))
Base.:(==)(x::Rand{T}, y::Rand{T}) where {T} = x.rng == y.rng

operator!(::Rand{T}, state::RandState) where {T} = rand(state.rng, T)

struct RandArray{T,N} <: RandBase{Array{T,N}}
    rng::Random.AbstractRNG
    dims::Dims{N}
end

Base.hash(x::RandArray, h::UInt64) = hash(x.rng, hash(x.dims, hash(:RandArray, h)))
Base.:(==)(x::RandArray{T}, y::RandArray{T}) where {T} = x.rng == y.rng && x.dims == y.dims

operator!(op::RandArray{T}, state::RandState) where {T} = rand(state.rng, T, op.dims)

# See docstring below — Xoshiro only exists (and is the default) in Julia 1.7 and later.
_make_rng() = VERSION < v"1.7.0" ? MersenneTwister() : Xoshiro()

"""
    rand([rng=...,] alignment::Node[, S, dims...])

Generate random numbers aligned to `alignment`, with the given `rng` if provided.

Semantics are otherwise very similar to the usual `Base.rand`:
* If specified, `S` will be the element type, and will default to `Float64` otherwise.
* If specified, `dims` should be a tuple or vararg of integers representing the dimensions
    of an array.

!!! note
    The values of the knots from `alignment` will be ignored.

!!! note
    The default value of `rng` on Julia 1.6 is `MersenneTwister()`. On Julia 1.7 and later
    it is `Xoshiro()`. This matches the default random number generator used in the
    language.

!!! tip
    If provided, `rng` will be copied before it is used. This is to ensure reproducability
    when evaluating a node multiple times.
"""
Base.rand(alignment::Node) = rand(_make_rng(), alignment)
Base.rand(rng::Random.AbstractRNG, alignment::Node) = rand(rng, alignment, Float64)
function Base.rand(rng::Random.AbstractRNG, alignment::Node, ::Type{X}) where {X}
    return obtain_node((alignment,), Rand{X}(copy(rng)))
end

Base.rand(alignment::Node, dims::Integer...) = rand(_make_rng(), alignment, Dims(dims))
Base.rand(alignment::Node, dims::Dims) = rand(_make_rng(), alignment, dims)
function Base.rand(rng::Random.AbstractRNG, alignment::Node, dims::Dims)
    return rand(rng, alignment, Float64, dims)
end
function Base.rand(
    rng::Random.AbstractRNG, alignment::Node, ::Type{X}, dims::Integer...
) where {X}
    return rand(rng, alignment, X, Dims(dims))
end
function Base.rand(
    rng::Random.AbstractRNG, alignment::Node, ::Type{X}, dims::Dims
) where {X}
    return obtain_node((alignment,), RandArray{X,length(dims)}(copy(rng), dims))
end
