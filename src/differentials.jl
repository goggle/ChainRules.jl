#####
##### `AbstractDifferential`
#####

"""
The subtypes of `AbstractDifferential` define a custom \"algebra\" for chain
rule evaluation that attempts to factor various features like complex derivative
support, broadcast fusion, zero-elision, etc. into nicely separated parts.

All subtypes of `AbstractDifferential` implement the following operations:

`add(a, b)`: linearly combine differential `a` and differential `b`

`mul(a, b)`: multiply the differential `a` by the differential `b`

`Base.conj(x)`: complex conjugate of the differential `x`

`extern(x)`: convert `x` into an appropriate non-`AbstractDifferential` type for
use outside of `ChainContext`.

Valid arguments to these operations are `T` where `T<:AbstractDifferential`, or
where `T` has proper `+` and `*` implementations.

Additionally, all subtypes of `AbstractDifferential` support `Base.iterate` and
`Base.Broadcast.broadcastable(x)`.
"""
abstract type AbstractDifferential end

"""
    extern(x)

Return `x` converted to an appropriate non-`AbstractDifferential` type, for use
with external packages that might not handle `AbstractDifferential` types.

Note that this function may return an alias (not necessarily a copy) to data
wrapped by `x`, such that mutating `extern(x)` might mutate `x` itself.
"""
@inline extern(x) = x

@inline Base.conj(x::AbstractDifferential) = x

#=
This `AbstractDifferential` algebra has a monad-y "fallthrough" implementation;
each step handles an element of the algebra before dispatching to the next step.
This way, we don't need to implement promotion/conversion rules between subtypes
of `AbstractDifferential` to resolve potential ambiguities.
=#

const PRECEDENCE_LIST = [:wirtinger, :casted, :zero, :dne, :one, :thunk, :fallback]

global defs = Expr(:block)

let previous_add_name = :add, previous_mul_name = :mul
    for name in PRECEDENCE_LIST
        next_add_name = Symbol(string(:add_, name))
        next_mul_name = Symbol(string(:mul_, name))
        push!(defs.args, quote
            @inline $(previous_add_name)(a, b) = $(next_add_name)(a, b)
            @inline $(previous_mul_name)(a, b) = $(next_mul_name)(a, b)
        end)
        previous_add_name = next_add_name
        previous_mul_name = next_mul_name
    end
end

eval(defs)

@inline add_fallback(a, b) = a + b

@inline mul_fallback(a, b) = a * b

@inline add(x) = x

@inline mul(x) = x

#####
##### `Wirtinger`
#####
# TODO does this represent (∂f/∂z, ∂f/∂z̄) or (∂f/∂z, ∂f̄/∂z) or what?

struct Wirtinger{P,C} <: AbstractDifferential
    primal::P
    conjugate::C
    function Wirtinger(primal::Union{Number,AbstractDifferential},
                       conjugate::Union{Number,AbstractDifferential})
        return new{typeof(primal),typeof(conjugate)}(primal, conjugate)
    end
    function Wirtinger(primal, conjugate)
        error("`Wirtinger` only supports elements of type <: Union{Number,AbstractDifferential} for now")
    end
end

wirtinger_primal(x::Wirtinger) = x.primal
wirtinger_primal(x) = x

wirtinger_conjugate(x::Wirtinger) = x.conjugate
wirtinger_conjugate(::Any) = Zero()

extern(x::Wirtinger) = error("`Wirtinger` cannot be converted into an external type.")

Base.Broadcast.broadcastable(w::Wirtinger) = Wirtinger(broadcastable(w.primal),
                                                       broadcastable(w.conjugate))

Base.iterate(x::Wirtinger) = (x, nothing)
Base.iterate(::Wirtinger, ::Any) = nothing

Base.conj(x::Wirtinger) = error("`conj(::Wirtinger)` not yet defined")

function add_wirtinger(a::Wirtinger, b::Wirtinger)
    return Wirtinger(add(a.primal, b.primal), add(a.conjugate, b.conjugate))
end

add_wirtinger(a::Wirtinger, b) = add(a, Wirtinger(b, Zero()))
add_wirtinger(a, b::Wirtinger) = add(Wirtinger(a, Zero()), b)

# TODO
mul_wirtinger(a::Wirtinger, b::Wirtinger) = error()

mul_wirtinger(a::Wirtinger, b) = Wirtinger(mul(a.primal, b), mul(a.conjugate, b))
mul_wirtinger(a, b::Wirtinger) = Wirtinger(mul(a, b.primal), mul(a, b.conjugate))

#####
##### `Casted`
#####

struct Casted{V} <: AbstractDifferential
    value::V
end

cast(x) = Casted(x)
cast(f, args...) = Casted(broadcasted(f, args...))

extern(x::Casted) = materialize(broadcasted(extern, x.value))

Base.Broadcast.broadcastable(x::Casted) = x.value

Base.iterate(x::Casted) = iterate(x.value)
Base.iterate(x::Casted, state) = iterate(x.value, state)

Base.conj(x::Casted) = cast(conj, x.value)

add_casted(a::Casted, b::Casted) = Casted(broadcasted(add, a.value, b.value))
add_casted(a::Casted, b) = Casted(broadcasted(add, a.value, b))
add_casted(a, b::Casted) = Casted(broadcasted(add, a, b.value))

mul_casted(a::Casted, b::Casted) = Casted(broadcasted(mul, a.value, b.value))
mul_casted(a::Casted, b) = Casted(broadcasted(mul, a.value, b))
mul_casted(a, b::Casted) = Casted(broadcasted(mul, a, b.value))

#####
##### `Zero`
#####

struct Zero <: AbstractDifferential end

extern(x::Zero) = false

Base.Broadcast.broadcastable(::Zero) = Ref(Zero())

Base.iterate(x::Zero) = (x, nothing)
Base.iterate(::Zero, ::Any) = nothing

add_zero(::Zero, ::Zero) = Zero()
add_zero(::Zero, b) = b
add_zero(a, ::Zero) = a

mul_zero(::Zero, ::Zero) = Zero()
mul_zero(::Zero, ::Any) = Zero()
mul_zero(::Any, ::Zero) = Zero()

#####
##### `DNE`
#####

struct DNE <: AbstractDifferential end

extern(x::DNE) = error("`DNE` cannot be converted into an external type.")

Base.Broadcast.broadcastable(::DNE) = Ref(DNE())

Base.iterate(x::DNE) = (x, nothing)
Base.iterate(::DNE, ::Any) = nothing

add_dne(::DNE, ::DNE) = DNE()
add_dne(::DNE, b) = b
add_dne(a, ::DNE) = a

mul_dne(::DNE, ::DNE) = DNE()
mul_dne(::DNE, ::Any) = DNE()
mul_dne(::Any, ::DNE) = DNE()

#####
##### `One`
#####

struct One <: AbstractDifferential end

extern(x::One) = true

Base.Broadcast.broadcastable(::One) = Ref(One())

Base.iterate(x::One) = (x, nothing)
Base.iterate(::One, ::Any) = nothing

add_one(a::One, b::One) = add(extern(a), extern(b))
add_one(a::One, b) = add(extern(a), b)
add_one(a, b::One) = add(a, extern(b))

mul_one(::One, ::One) = One()
mul_one(::One, b) = b
mul_one(a, ::One) = a

#####
##### `Thunk`
#####

struct Thunk{F} <: AbstractDifferential
    f::F
end

macro thunk(body)
    return :(Thunk(() -> $(esc(body))))
end

@inline extern(x::Thunk{F}) where {F} = x.f()

Base.Broadcast.broadcastable(x::Thunk) = broadcastable(extern(x))

@inline function Base.iterate(x::Thunk)
    externed = extern(x)
    element, state = iterate(externed)
    return element, (externed, state)
end

@inline function Base.iterate(::Thunk, (externed, state))
    element, new_state = iterate(externed, state)
    return element, (externed, new_state)
end

Base.conj(x::Thunk) = @thunk(conj(extern(x)))

add_thunk(a::Thunk, b::Thunk) = add(extern(a), extern(b))
add_thunk(a::Thunk, b) = add(extern(a), b)
add_thunk(a, b::Thunk) = add(a, extern(b))

mul_thunk(a::Thunk, b::Thunk) = mul(extern(a), extern(b))
mul_thunk(a::Thunk, b) = mul(extern(a), b)
mul_thunk(a, b::Thunk) = mul(a, extern(b))

#####
##### misc.
#####

# TODO justify this
function Wirtinger(primal::Union{Real,DNE,Zero,One},
                   conjugate::Union{Real,DNE,Zero,One})
    return add(primal, conjugate)
end
