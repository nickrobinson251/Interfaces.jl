module Interfaces

export isinterfacetype, @interface, @implements, InterfaceImplementationError

struct InterfaceImplementationError <: Exception
    msg::String
end

isinterfacetype(::Type{T}) where {T} = false
isinterfacetype(::Type{Type{T}}) where {T} = isinterfacetype(T)

function interface end

struct Interface
    name
    exprs::Vector{Any}
end

# TODO: custom show for Interface

function implements end

implements(::Type{Type{T}}, ::Type{Type{S}}, mods::Vector{Module}=[parentmodule(T)]) where {T, S} =
    implements(T, S, mods)

function implemented(f, args, mods)
    impls = Base.methods(f, args, mods)
    return length(impls) > 0
end

"""
Replace all arguments `T` with `sym` (default `:T`) in the given `expr::Expr`.

Used to swap `::SomeInterface` -> `::T`, because `@interface` uses syntax like:

    @interface SomeInterface begin
        foo(::SomeInterface)
    end

to express "`T` implements the interface `SomeInterface` if there is a method `foo(::T)`",
i.e. we need there to be a `foo` method that accepts the type `T` not the type `SomeInterface`.
"""
function recursiveswapT!(T, expr, sym=:T)
    for i = 1:length(expr.args)
        arg = expr.args[i]
        if arg == T
            expr.args[i] = sym
        elseif arg isa Expr
            recursiveswapT!(T, arg, sym)
        end
    end
    return
end

"""
Convert arguments to just their type constraints.
Used as part of converting method signature syntax to a something we can check for with
`methods(f, args)`.

    # Given `foo(x::Int, ::Float64, z)`
    args = [:(1::Int), :(::Float64), :z]
    convertargs(:SomeInterface, :foo, args) == :(Tuple{Int, Float64, Any})
"""
function convertargs(T, nm, args)
    isempty(args) && throw(ArgumentError("invalid `$T` interface method with zero arguments: `$nm()`"))
    for i = 1:length(args)
        arg = args[i]
        if arg isa Symbol
            args[i] = :Any
        elseif arg.head === :(::) && length(arg.args) == 1
            recursiveswapT!(T, arg)
            args[i] = arg.args[1]
        elseif arg.head === :(::) && length(arg.args) == 2
            recursiveswapT!(T, arg)
            args[i] = arg.args[2]
        else
            throw(ArgumentError("invalid `$T` interface method argument for method `$nm`: `$arg`"))
        end
    end
    return Expr(:curly, :Tuple, args...)
end

unconvertargs(::Type{T}) where {T <: Tuple} = Any[Expr(:(::), fieldtype(T, i)) for i = 1:fieldcount(T)]

"""
Extract the (quoted) function name and argument types from a method signature.

    methodparts(:SomeInterface, :(foo(x::Int, ::Float64, z))) == (:foo, :(Tuple{Int, Float64, Any}))
"""
function methodparts(T, x::Expr)
    @assert x.head === :call
    methodname = x.args[1]
    args = convertargs(T, methodname, x.args[2:end])
    return methodname, args
end

requiredmethod(T, nm, args, shouldthrow) = :(Interfaces.implemented($nm, $args, mods) || ($shouldthrow && Interfaces.missingmethod($T, $nm, $args, mods)))

function requiredreturn(T, nm, args, shouldthrow, RT_sym, __RT__)
    return quote
        check = $(requiredmethod(T, nm, args, shouldthrow))
        $RT_sym = Interfaces.returntype($nm, $args)
        # @show $RT_sym, $nm, $args, Interfaces.isinterfacetype($__RT__)
        check |= Interfaces.isinterfacetype($__RT__) ?  Interfaces.implements($RT_sym, $__RT__) : $RT_sym <: $__RT__
        check || ($shouldthrow && Interfaces.invalidreturntype($nm, $args, $RT_sym, $__RT__))
    end
end

@noinline missingmethod(T, f, args, mods) = throw(InterfaceImplementationError("missing `$T` interface method definition: `$(Expr(:call, f, unconvertargs(args)...))`, in module(s): `$mods`"))
@noinline invalidreturntype(T, f, args, RT1, RT2) = throw(InterfaceImplementationError("invalid return type for `$T` interface method definition: `$(Expr(:call, f, unconvertargs(args)...))`; inferred $RT1, required $RT2"))
@noinline subtypingrequired(IT, T) = throw(InterfaceImplementationError("interface `$IT` requires implementing types to subtype, like: `struct $T <: $IT`"))
@noinline atleastonerequired(T, expr) = throw(InterfaceImplementationError("for `$T` interface, one of the following method definitions is required: `$expr`"))

function toimplements!(T, arg::Expr, shouldthrow::Bool=true)
    if arg.head == :call
        # required method definition
        nm, args = methodparts(T, arg)
        return requiredmethod(T, nm, args, shouldthrow)
    elseif arg.head == :(::)
        # required method definition and required return type
        nm, args = methodparts(T, arg.args[1])
        annotation = arg.args[2]
        if !isa(annotation, Symbol) && annotation.head == :where
            # `::(T where T)` or `::(T where T<:Foo)`
            sym = annotation.args[1]
            __RT__ = annotation.args[2] isa Symbol ? Any : annotation.args[2].args[2]
        else # `::Foo` or `::Union{Foo,Bar}` or `::Type{Foo}`
            sym = gensym()
            __RT__ = annotation
        end
        return requiredreturn(T, nm, args, shouldthrow, sym, __RT__)
    elseif arg.head == :<:
        return :((T <: $T) || Interfaces.subtypingrequired($T, T))
    elseif arg.head == :if
        # conditional requirement
        origarg = arg
        recursiveswapT!(T, arg.args[1])
        arg.args[2] = toimplements!(T, arg.args[2])
        while length(arg.args) > 2
            if arg.args[3].head == :elseif
                arg = arg.args[3]
                recursiveswapT!(T, arg.args[1])
                arg.args[2] = toimplements!(T, arg.args[2])
            else
                # else block
                arg.args[3] = toimplements!(T, arg.args[3])
                break
            end
        end
        return origarg
    elseif arg.head == :||
        # one of many required
        argcopy = copy(arg)
        origarg = arg
        while true
            arg.args[1] = toimplements!(T, arg.args[1], false)
            arg.args[2].head == :|| || break
            arg = arg.args[2]
        end
        arg.args[2] = toimplements!(T, arg.args[2], false)
        return :(($origarg) || Interfaces.atleastonerequired($T, $(Meta.quot(argcopy))))
    elseif arg.head == :block
        # not supported at top-level of @interface block
        # but can be block of if-else or || expressions
        map!(x -> toimplements!(T, x, shouldthrow), arg.args, arg.args)
        return arg
    else
        throw(ArgumentError("unsupported expression in @interface block for `$T`: `$arg`"))
    end
end

macro interface(T, alias_or_block, maybe_block=nothing)
    @assert T isa Symbol || T.head == :.
    if alias_or_block isa Symbol
        alias = alias_or_block
        block = maybe_block
    else
        alias = T
        block = alias_or_block
    end
    @assert block isa Expr && block.head == :block
    Base.remove_linenums!(block)
    if T !== alias
        recursiveswapT!(alias, block, T)
    end
    iface = Interface(T, deepcopy(block.args))
    filter!(x -> !(x isa String), block.args)
    toimplements!(T, block)
    return esc(quote
        Interfaces.isinterfacetype(::Type{$T}) = true
        Interfaces.interface(::Type{$T}) = $iface
        function Interfaces.implements(::Type{T}, ::Type{$T}, mods::Vector{Module}=[parentmodule(T)]) where {T}
            $block
        end
    end)
end

macro implements(T, IT)
    return esc(quote
        @assert Interfaces.implements($T, $IT)
        Interfaces.implements(::Type{$T}, ::Type{$IT}) = true
    end)
end

@noinline returntype(@nospecialize(f), @nospecialize(args)) = Base.return_types(f, args)[1]

end # module
