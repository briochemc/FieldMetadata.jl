module FieldMetadata

export @metadata, @chain

"""
Generate a macro that constructs methods of the same name.
These methods return the metadata information provided for each
field of the struct.

```julia
@metadata def_range (0, 0)
@def_range struct Model
    a::Int | (1, 4)
    b::Int | (4, 9)
end

model = Model(3, 5)
def_range(model, Val{:a})
(1, 4)

def_range(model)
((1, 4), (4, 9))
```
"""
macro metadata(name, default)
    symname = QuoteNode(name)
    default = esc(default)
    rename = esc(Meta.parse("re$name"))
    name = esc(name)
    return quote
        macro $name(expr)
            name = $symname
            return funcs_from_struct(expr, name)
        end

        macro $name(typ, expr)
            name = $symname
            return funcs_from_block(typ, expr, name)
        end

        macro $rename(expr)
            name = $symname
            return funcs_from_struct(expr, name; update=true)
        end

        # Single field methods
        $name(x, key) = $default
        $name(x::Type, key::Type) = $default
        $name(::X, key::Symbol) where X = $name(X, Val{key})
        $name(::X, key::Type) where X = $name(X, key)
        $name(::Type{X}, key::Symbol) where X = $name(X, Val{key})

        # All field methods
        $name(::X) where X = $name(X)
        $name(x::Type{X}) where X = $name(X, fieldname_vals(X))
        $name(::Type{X}, keys::Tuple) where X =
            ($name(X, keys[1]), $name(X, Base.tail(keys))...)
        $name(::Type{X}, keys::Tuple{}) where X = tuple()
    end
end

"""
Chain together any macros. Useful for combining @metadata macros.

### Example
```julia
@chain columns @label @units @default_kw

@columns struct Foo
  bar::Int | 7 | u"g" | "grams of bar"
end
```
"""
macro chain(name, ex)
    macros = chained_macros(ex)
    return quote
        macro $(esc(name))(ex)
            macros = $macros
            for mac in reverse(macros)
                ex = Expr(:macrocall, mac, LineNumberNode(75, "FieldMetadata.jl"), ex)
            end
            esc(ex)
        end
    end
end

Base.@pure fieldname_vals(::Type{X}) where X = ([Val{fn} for fn in fieldnames(X)]...,)


function funcs_from_struct(expr::Expr, name::Symbol; update=false)
    macros = chained_macros(expr)
    typ = firsthead(x -> namify(x.args[2]), expr, :struct)
    # If there is no struct this is a begin block
    # with chained macros
    if typ === nothing 
        if length(macros) > 0
            findexpr = expr
            for i in 1:length(macros) - 1
                findexpr = findexpr.args[3]
            end
            typ = findexpr.args[3]
        else
            error("incorrect arguments for @$name")
        end
    else
    end
    func_exprs = Expr[]
    firsthead(expr, :block) do block
        parseblock!(block, func_exprs, name, typ)
    end
    if length(macros) == 0
        if update 
            Expr(:block, func_exprs...)
        else
            Expr(:block, :(Base.@__doc__ $(esc(expr))), func_exprs...)
        end
    else
        Expr(:block, esc(expr), func_exprs...)
    end
end

function funcs_from_block(objtyp::Union{Symbol,Expr}, expr::Expr, name::Symbol)
    macros = chained_macros(objtyp)
    typ = firsthead(x -> namify(x.args[2]), expr, :)
    func_exprs = Expr[]
    firsthead(expr, :block) do block
        parseblock!(block, func_exprs, name, objtyp)
    end
    if length(macros) == 0
        Expr(:block, func_exprs...)
    else
        Expr(:block, esc(typ), esc(ex), func_exprs...)
    end
end

# Parse the block: and Function expressions are built for each line, 
# and one layer of metadata is removed. Both arguments are modified.  
function parseblock!(block::Expr, exprs::Vector, name::Symbol, typ::Union{Symbol,Expr})
    for (i, line) in enumerate(block.args)
        :head in fieldnames(typeof(line)) || continue
        # Allow Parameters.jl to coexist
        if line.head == :(=)
            call = line.args[2]
            call.args[1] == :(|) || continue
            # The fieldname is the first arg
            fn = line.args[1]
            maybeaddmethod!(exprs, name, typ, fn, call)
            # Replace the rest of the line after the = call
            line.args[2] = call.args[2]
        elseif line.head == :call || line.args[1] == :(|)
            fn = line.args[2]
            if fn isa Expr
                processline(block, line, name, typ)
            elseif fn isa Symbol
                maybeaddmethod!(exprs, name, typ, fn, line)
                # Replace the line in the parent block
                block.args[i] = line.args[2]
            end
        end
    end
end

function processline!(block, line, name, typ, i) 
        if fn.head == :call 
            processline!(block, fn, name, typ, i) 
        else
            maybeaddmethod!(exprs, name, typ, fn, line)
            # Replace the line with the field
            line.head = fn.head
            line.args = fn.args
        end
end

function maybeaddmethod!(exprs, name, typ, fn, ex)
    # Get just the fieldname symbol from the full fieldname
    val = ex.args[3]
    key = getkey(fn)
    # Add a method expression unless this contains a `_` default
    val == :_ || addmethod!(exprs, name, typ, key, val)
end

function addmethod!(exprs, name, typ, key, value)
    func = esc(:(function $name(::Type{<:$typ}, ::Type{Val{$(QuoteNode(key))}}) $value end))
    push!(exprs, func)
end

getkey(ex::Expr) = begin
    key = firsthead(y -> y.args[1], ex, :(::))
    if key == nothing 
        key = firsthead(y -> y.args[1], ex, :(=))
    end
    if key == nothing 
        key = firsthead(y -> y.args[2], ex, :call)
    end
    key
end
getkey(ex::Symbol) = ex

chained_macros(ex) = chained_macros!(Symbol[], ex)
chained_macros!(macros, ex::Expr) = begin
    if ex.head == :macrocall
        push!(macros, ex.args[1])
        length(ex.args) > 2 && chained_macros!(macros, ex.args[3])
    end
    macros
end
chained_macros!(macros, ex::Symbol) = Symbol[]

firsthead(f, ex::Expr, sym) =
    if ex.head == sym
        out = f(ex)
        return out
    else
        for arg in ex.args
            x = firsthead(f, arg, sym)
            x == nothing || return x
        end
        return nothing
    end
firsthead(f, ex, sym) = nothing

namify(x) = x
namify(x::Expr) = namify(x.args[1])



# FieldMetadata api
@metadata default nothing
@metadata units 1
@metadata prior nothing
@metadata description ""
@metadata limits (1e-7, 1.0) # just above zero so log transform is possible 
@metadata bounds (1e-7, 1.0) # just above zero so log transform is possible 
@metadata label ""
@metadata logscaled false
@metadata flattenable true
@metadata plottable true
@metadata selectable Nothing

# Set the default label to be the field name
label(x::Type, ::Type{Val{F}}) where F = F

end # module
