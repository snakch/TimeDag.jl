"""
    _wrap(::Type{T}, x...)

Wrap value(s) into a data object of the given type, for use with associative combinations.
"""
_wrap(::Type{T}, x::T) where {T} = x

"""
    _unfiltered(op) -> Bool

Returns true iff `_should_tick` will always return true.
"""
_unfiltered(::NodeOp) = false

"""
    _should_tick(op, data) -> Bool

This should be defined for any op that does not have `_unfiltered(op)` returning true.
The return value determines whether a knot should be emitted for this value.
"""
function _should_tick end

"""
    _extract(op, data) -> value

This should be defined for all inception and windowed ops. Given some data object, it should
compute the appropriate output value for the node.
"""
function _extract end

"""Unary operator accumulated from inception."""
abstract type UnaryInceptionOp{T,Data,CombineOp} <: UnaryNodeOp{T} end

"""Binary operator accumulated from inception."""
abstract type BinaryInceptionOp{T,Data,CombineOp,A} <: BinaryAlignedNodeOp{T,A} end

const InceptionOp{T,Data,CombineOp} = Union{
    UnaryInceptionOp{T,Data,CombineOp},BinaryInceptionOp{T,Data,CombineOp}
}

always_ticks(op::InceptionOp) = _unfiltered(op)
time_agnostic(::InceptionOp) = true

mutable struct InceptionOpState{Data} <: NodeEvaluationState
    initialised::Bool
    data::Data
    # `data` will be uninitialised until the first call.
    InceptionOpState{Data}() where {Data} = new{Data}(false)
end

function create_operator_evaluation_state(
    ::Tuple{Node}, ::UnaryInceptionOp{T,Data}
) where {T,Data}
    return InceptionOpState{Data}()
end

function create_operator_evaluation_state(
    ::Tuple{Node,Node}, ::BinaryInceptionOp{T,Data}
) where {T,Data}
    return InceptionOpState{Data}()
end

function operator!(
    op::InceptionOp{T,Data,CombineOp}, state::InceptionOpState{Data}, x...
) where {T,Data,CombineOp}
    if !state.initialised
        state.data = _wrap(Data, x...)
        state.initialised = true
    else
        state.data = CombineOp(state.data, _wrap(Data, x...))
    end
    return if always_ticks(op)
        # Deal with the case where we always emit.
        _extract(op, state.data)
    elseif _unfiltered(op) || _should_tick(op, state.data)
        Maybe(_extract(op, state.data))
    else
        Maybe{T}()
    end
end

"""
Windowed associative binary operator, potentially emitting early before the window is full.
"""
abstract type UnaryWindowOp{T,Data,CombineOp,EmitEarly} <: UnaryNodeOp{T} end

"""
    _window(window_op) -> Int64

Return the window for the specified op.
The default implementation expects a field called `window` on the op structure.
"""
_window(op::UnaryWindowOp) = op.window

"""Whether or not this window op is set to emit with a non-full window."""
function _emit_early(::UnaryWindowOp{T,Data,CombineOp,true}) where {T,Data,CombineOp}
    return true
end
function _emit_early(::UnaryWindowOp{T,Data,CombineOp,false}) where {T,Data,CombineOp}
    return false
end

always_ticks(op::UnaryWindowOp) = _emit_early(op) && _unfiltered(op)
time_agnostic(::UnaryWindowOp) = true

mutable struct WindowOpState{Data} <: NodeEvaluationState
    window_state::FixedWindowAssociativeOp{Data}
end

function create_operator_evaluation_state(
    ::Tuple{Node}, op::UnaryWindowOp{T,Data,CombineOp}
) where {T,Data,CombineOp}
    return WindowOpState{Data}(FixedWindowAssociativeOp{Data,CombineOp}(_window(op)))
end

function operator!(
    op::UnaryWindowOp{T,Data,CombineOp}, state::WindowOpState{Data}, x
) where {T,Data,CombineOp}
    update_state!(state.window_state, _wrap(Data, x))
    if always_ticks(op)
        # Deal with the case where we always emit.
        return _extract(op, window_value(state.window_state))
    end

    ready = _emit_early(op) || window_full(state.window_state)
    if !ready
        return Maybe{T}()
    end

    data = window_value(state.window_state)
    return if _unfiltered(op) || _should_tick(op, data)
        Maybe(_extract(op, data))
    else
        Maybe{T}()
    end
end

# Sum, cumulative over time.
struct Sum{T} <: UnaryInceptionOp{T,T,+} end
_unfiltered(::Sum) = true
_extract(::Sum, data) = data
Base.show(io::IO, ::Sum{T}) where {T} = print(io, "Sum{$T}")
function Base.sum(x::Node)
    _is_constant(x) && return x
    return obtain_node((x,), Sum{value_type(x)}())
end

# Sum over fixed window.
struct WindowSum{T,EmitEarly} <: UnaryWindowOp{T,T,+,EmitEarly}
    window::Int64
end
_unfiltered(::WindowSum) = true
_extract(::WindowSum, data) = data
Base.show(io::IO, op::WindowSum{T}) where {T} = print(io, "WindowSum{$T}($(_window(op)))")
function Base.sum(x::Node, window::Int; emit_early::Bool=false)
    return obtain_node((x,), WindowSum{value_type(x),emit_early}(window))
end

# Product, cumulative over time.
struct Prod{T} <: UnaryInceptionOp{T,T,*} end
_unfiltered(::Prod) = true
_extract(::Prod, data) = data
Base.show(io::IO, ::Prod{T}) where {T} = print(io, "Prod{$T}")
function Base.prod(x::Node)
    _is_constant(x) && return x
    return obtain_node((x,), Prod{value_type(x)}())
end

# Product over fixed window.
struct WindowProd{T,EmitEarly} <: UnaryWindowOp{T,T,*,EmitEarly}
    window::Int64
end
_unfiltered(::WindowProd) = true
_extract(::WindowProd, data) = data
Base.show(io::IO, op::WindowProd{T}) where {T} = print(io, "WindowProd{$T}($(_window(op)))")
function Base.prod(x::Node, window::Int; emit_early::Bool=false)
    return obtain_node((x,), WindowProd{value_type(x),emit_early}(window))
end

# Mean, cumulative over time.
# In order to be numerically stable, use a generalisation of Welford's algorithm.
# Disable formatting: https://github.com/domluna/JuliaFormatter.jl/issues/480
#! format: off
const MeanData{T} = @NamedTuple{n::Int64, mean::T} where {T}
#! format: on
_wrap(::Type{MeanData{T}}, x) where {T} = MeanData{T}((1, x))
function _combine(state_a::MeanData{T}, state_b::MeanData{T})::MeanData{T} where {T}
    na = state_a.n
    nb = state_b.n
    nc = na + nb
    return MeanData{T}((n=nc, mean=state_a.mean * (na / nc) + state_b.mean * (nb / nc)))
end
struct Mean{T} <: UnaryInceptionOp{T,MeanData{T},_combine} end
_unfiltered(::Mean) = true
_extract(::Mean, data::MeanData) = data.mean
Base.show(io::IO, ::Mean{T}) where {T} = print(io, "Mean{$T}")
function Statistics.mean(x::Node)
    _is_constant(x) && return x
    T = output_type(/, value_type(x), Int)
    return obtain_node((x,), Mean{T}())
end

# Mean over fixed window.
struct WindowMean{T,EmitEarly} <: UnaryWindowOp{T,MeanData{T},_combine,EmitEarly}
    window::Int64
end
_unfiltered(::WindowMean) = true
_extract(::WindowMean, data::MeanData) = data.mean
Base.show(io::IO, op::WindowMean{T}) where {T} = print(io, "WindowMean{$T}($(_window(op)))")
function Statistics.mean(x::Node, window::Int; emit_early::Bool=false)
    T = output_type(/, value_type(x), Int)
    return obtain_node((x,), WindowMean{T,emit_early}(window))
end

# Variance, cumulative over time.
# In order to be numerically stable, use a generalisation of Welford's algorithm.
# Disable formatting: https://github.com/domluna/JuliaFormatter.jl/issues/480
#! format: off
const VarData{T} = @NamedTuple{n::Int64, mean::T, s::T} where {T}
#! format: on
_wrap(::Type{VarData{T}}, x) where {T} = VarData{T}((1, x, 0))
function _combine(state_a::VarData{T}, state_b::VarData{T})::VarData{T} where {T}
    na = state_a.n
    nb = state_b.n
    nc = na + nb

    μa = state_a.mean
    μb = state_b.mean
    μc = μa * (na / nc) + μb * (nb / nc)

    sa = state_a.s
    sb = state_b.s

    return VarData{T}((n=nc, mean=μc, s=(sa + sb) + nb * (μb - μa) * (μb - μc)))
end
struct Var{T,corrected} <: UnaryInceptionOp{T,VarData{T},_combine} end
_should_tick(::Var, data::VarData) = data.n > 1
_extract(::Var{T,true}, data::VarData) where {T} = data.s / (data.n - 1)
_extract(::Var{T,false}, data::VarData) where {T} = data.s / data.n
Base.show(io::IO, ::Var{T}) where {T} = print(io, "Var{$T}")
function Statistics.var(x::Node; corrected::Bool=true)
    _is_constant(x) && throw(ArgumentError("Cannot compute variance of constant $x"))
    T = output_type(/, value_type(x), Int)
    return obtain_node((x,), Var{T,corrected}())
end

# Variance over fixed window.
struct WindowVar{T,Corrected,EmitEarly} <: UnaryWindowOp{T,VarData{T},_combine,EmitEarly}
    window::Int64
end
_should_tick(::WindowVar, data::VarData) = data.n > 1
_extract(::WindowVar{T,true}, data::VarData) where {T} = data.s / (data.n - 1)
_extract(::WindowVar{T,false}, data::VarData) where {T} = data.s / data.n
Base.show(io::IO, op::WindowVar{T}) where {T} = print(io, "WindowVar{$T}($(_window(op)))")
function Statistics.var(x::Node, window::Int; emit_early::Bool=false, corrected::Bool=true)
    window >= 2 || throw(ArgumentError("Got window=$window, but should be at least 2"))
    T = output_type(/, value_type(x), Int)
    return obtain_node((x,), WindowVar{T,corrected,emit_early}(window))
end

# Standard deviation.
Statistics.std(x::Node; corrected::Bool=true) = sqrt(var(x; corrected))
function Statistics.std(x::Node, window::Int; emit_early::Bool=false, corrected::Bool=true)
    return sqrt(var(x, window; emit_early, corrected))
end

# Covariance, cumulative over time.
# Disable formatting: https://github.com/domluna/JuliaFormatter.jl/issues/480
#! format: off
const CovData{T} = @NamedTuple{n::Int64, mean_x::T, mean_y::T, c::T} where {T}
#! format: on
_wrap(::Type{CovData{T}}, x, y) where {T} = CovData{T}((1, x, y, 0))
function _combine(state_a::CovData{T}, state_b::CovData{T})::CovData{T} where {T}
    na = state_a.n
    nb = state_b.n
    nc = na + nb

    μxa = state_a.mean_x
    μxb = state_b.mean_x
    μxc = μxa * (na / nc) + μxb * (nb / nc)

    μya = state_a.mean_y
    μyb = state_b.mean_y
    μyc = μya * (na / nc) + μyb * (nb / nc)

    ca = state_a.c
    cb = state_b.c
    # FIXME This is speculation - do the algebra to check this!
    cc = (ca + cb) + nb * (μxb - μxa) * (μyb - μyc)

    return CovData{T}((n=nc, mean_x=μxc, mean_y=μyc, c=cc))
end
struct Cov{T,corrected,A} <: BinaryInceptionOp{T,CovData{T},_combine,A} end
_should_tick(::Cov, data::CovData) = data.n > 1
_extract(::Cov{T,true}, data::CovData) where {T} = data.c / (data.n - 1)
_extract(::Cov{T,false}, data::CovData) where {T} = data.c / data.n
Base.show(io::IO, ::Cov{T}) where {T} = print(io, "Var{$T}")
function Statistics.cov(x, y, ::Type{A}; corrected::Bool=true) where {A<:Alignment}
    x = _ensure_node(x)
    y = _ensure_node(y)
    if _is_constant(x) && _is_constant(y)
        throw(ArgumentError("Cannot compute variance of constants $x and $y"))
    end
    T = output_type(/, output_type(*, value_type(x), value_type(y)), Int)
    return obtain_node((x, y), Cov{T,corrected,A}())
end
function Statistics.cov(x::Node, y::Node; corrected::Bool=true)
    return cov(x, y, DEFAULT_ALIGNMENT; corrected)
end
Statistics.cov(x::Node, y; corrected::Bool=true) = cov(x, y, DEFAULT_ALIGNMENT; corrected)
Statistics.cov(x, y::Node; corrected::Bool=true) = cov(x, y, DEFAULT_ALIGNMENT; corrected)
