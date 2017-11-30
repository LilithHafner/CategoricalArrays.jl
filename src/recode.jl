const ≅ = isequal

"""
    recode!(dest::AbstractArray, src::AbstractArray[, default::Any], pairs::Pair...)

Fill `dest` with elements from `src`, replacing those matching a key of `pairs`
with the corresponding value.

For each `Pair` in `pairs`, if the element is equal to (according to [`isequal`](@ref))
or [`in`](@ref) the key (first item of the pair), then the corresponding value
(second item) is copied to `dest`.
If the element matches no key and `default` is not provided or `nothing`, it is copied as-is;
if `default` is specified, it is used in place of the original element.
`dest` and `src` must be of the same length, but not necessarily of the same type.
Elements of `src` as well as values from `pairs` will be `convert`ed when possible
on assignment.
If an element matches more than one key, the first match is used.

    recode!(dest::AbstractArray, src::AbstractArray{>:Missing}[, default::Any], pairs::Pair...)

If `src` contains missing values, they are never replaced with `default`:
use `missing` in a pair to recode them.
"""
function recode! end

recode!(dest::AbstractArray, src::AbstractArray, pairs::Pair...) =
    recode!(dest, src, nothing, pairs...)

function recode!(dest::AbstractArray{T}, src::AbstractArray, default::Any, pairs::Pair...) where {T}
    if length(dest) != length(src)
        throw(DimensionMismatch("dest and src must be of the same length (got $(length(dest)) and $(length(src)))"))
    end

    @inbounds for i in eachindex(dest, src)
        x = src[i]

        for j in 1:length(pairs)
            p = pairs[j]
            if (!isa(p.first, Union{AbstractArray, Tuple}) && x ≅ p.first) ||
               (isa(p.first, Union{AbstractArray, Tuple}) && x in p.first)
                dest[i] = p.second
                @goto nextitem
            end
        end

        # Value not in any of the pairs
        if ismissing(x)
            eltype(dest) >: Missing ||
                throw(MissingException("missing value found, but dest does not support them: " *
                                       "recode them to a supported value"))
            dest[i] = missing
        elseif default === nothing
            try
                dest[i] = x
            catch err
                isa(err, MethodError) || rethrow(err)
                throw(ArgumentError("cannot `convert` value $(repr(x)) (of type $(typeof(x))) to type of recoded levels ($T). " *
                                    "This will happen with recode() when not all original levels are recoded " *
                                    "(i.e. some are preserved) and their type is incompatible with that of recoded levels."))
            end
        else
            dest[i] = default
        end

        @label nextitem
    end

    dest
end

function recode!(dest::CategoricalArray{T}, src::AbstractArray, default::Any, pairs::Pair...) where {T}
    if length(dest) != length(src)
        throw(DimensionMismatch("dest and src must be of the same length (got $(length(dest)) and $(length(src)))"))
    end

    vals = T[p.second for p in pairs]
    default !== nothing && push!(vals, default)

    levels!(dest.pool, filter!(!ismissing, unique(vals)))
    # In the absence of duplicated recoded values, we do not need to lookup the reference
    # for each pair in the loop, which is more efficient (with loop unswitching)
    dupvals = length(vals) != length(levels(dest.pool))

    drefs = dest.refs
    pairmap = [ismissing(v) ? 0 : get(dest.pool, v) for v in vals]
    defaultref = default === nothing || ismissing(default) ? 0 : get(dest.pool, default)
    @inbounds for i in eachindex(drefs, src)
        x = src[i]

        for j in 1:length(pairs)
            p = pairs[j]
            if (!isa(p.first, Union{AbstractArray, Tuple}) && x ≅ p.first) ||
               (isa(p.first, Union{AbstractArray, Tuple}) && x in p.first)
                drefs[i] = dupvals ? pairmap[j] : j
                @goto nextitem
            end
        end

        # Value not in any of the pairs
        if ismissing(x)
            eltype(dest) >: Missing ||
                throw(MissingException("missing value found, but dest does not support them: " *
                                       "recode them to a supported value"))
            drefs[i] = 0
        elseif default === nothing
            try
                dest[i] = x # Need a dictionary lookup, and potentially adding a new level
            catch err
                isa(err, MethodError) || rethrow(err)
                throw(ArgumentError("cannot `convert` value $(repr(x)) (of type $(typeof(x))) to type of recoded levels ($T). " *
                                    "This will happen with recode() when not all original levels are recoded "*
                                    "(i.e. some are preserved) and their type is incompatible with that of recoded levels."))
            end
        else
            drefs[i] = defaultref
        end

        @label nextitem
    end

    # Put existing levels first, and sort them if possible
    # for consistency with CategoricalArray
    oldlevels = setdiff(levels(dest), vals)
    filter!(!ismissing, oldlevels)
    if method_exists(isless, (eltype(oldlevels), eltype(oldlevels)))
        sort!(oldlevels)
    end
    levels!(dest, union(oldlevels, levels(dest)))

    dest
end

function recode!(dest::CategoricalArray{T}, src::CategoricalArray, default::Any, pairs::Pair...) where {T}
    if length(dest) != length(src)
        throw(DimensionMismatch("dest and src must be of the same length (got $(length(dest)) and $(length(src)))"))
    end

    vals = T[p.second for p in pairs]
    if default === nothing
        srclevels = levels(src)

        # Remove recoded levels as they won't appear in result
        firsts = (p.first for p in pairs)
        keptlevels = Vector{T}()
        sizehint!(keptlevels, length(srclevels))

        for l in srclevels
            if !(any(x -> x ≅ l, firsts) ||
                 any(f -> isa(f, Union{AbstractArray, Tuple}) && l in f, firsts))
                try
                    push!(keptlevels, l)
                catch err
                    isa(err, MethodError) || rethrow(err)
                    throw(ArgumentError("cannot `convert` value $(repr(l)) (of type $(typeof(l))) to type of recoded levels ($T). " *
                                        "This will happen with recode() when not all original levels are recoded " *
                                        "(i.e. some are preserved) and their type is incompatible with that of recoded levels."))
                end
            end
        end
        levs, ordered = mergelevels(isordered(src), keptlevels, filter!(!ismissing, unique(vals)))
    else
        push!(vals, default)
        levs = filter!(!ismissing, unique(vals))
        # The order of default cannot be determined
        ordered = false
    end

    srcindex = src.pool === dest.pool ? copy(index(src.pool)) : index(src.pool)
    levels!(dest.pool, levs)

    drefs = dest.refs
    srefs = src.refs

    origmap = [get(dest.pool, v, 0) for v in srcindex]
    indexmap = Vector{DefaultRefType}(length(srcindex)+1)
    # For missing values (0 if no missing in pairs' keys)
    indexmap[1] = 0
    for p in pairs
        if ismissing(p.first)
            indexmap[1] = get(dest.pool, p.second)
            break
        end
    end
    pairmap = [ismissing(p.second) ? 0 : get(dest.pool, p.second) for p in pairs]
    # Preserving ordered property only makes sense if new order is consistent with previous one
    ordered && (ordered = issorted(pairmap))
    ordered!(dest, ordered)
    defaultref = default === nothing || ismissing(default) ? 0 : get(dest.pool, default)
    @inbounds for (i, l) in enumerate(srcindex)
        for j in 1:length(pairs)
            p = pairs[j]
            if (!isa(p.first, Union{AbstractArray, Tuple}) && l ≅ p.first) ||
               (isa(p.first, Union{AbstractArray, Tuple}) && l in p.first)
                indexmap[i+1] = pairmap[j]
                @goto nextitem
            end
        end

        # Value not in any of the pairs
        if default === nothing
            indexmap[i+1] = origmap[i]
        else
            indexmap[i+1] = defaultref
        end

        @label nextitem
    end

    @inbounds for i in eachindex(drefs)
        v = indexmap[srefs[i]+1]
        if !(eltype(dest) >: Missing)
            v > 0 || throw(MissingException("missing value found, but dest does not support them: " *
                                            "recode them to a supported value"))
        end
        drefs[i] = v
    end

    dest
end

"""
    recode!(a::AbstractArray[, default::Any], pairs::Pair...)

Convenience function for in-place recoding, equivalent to `recode!(a, a, ...)`.

# Examples
```jldoctest
julia> using CategoricalArrays

julia> x = collect(1:10);

julia> recode!(x, 1=>100, 2:4=>0, [5; 9:10]=>-1);

julia> x
10-element Array{Int64,1}:
 100
   0
   0
   0
  -1
   6
   7
   8
  -1
  -1
```
"""
recode!(a::AbstractArray, default::Any, pairs::Pair...) = recode!(a, a, default, pairs...)
recode!(a::AbstractArray, pairs::Pair...) = recode!(a, a, nothing, pairs...)

promote_valuetype(x::Pair{K, V}) where {K, V} = V
promote_valuetype(x::Pair{K, V}, y::Pair...) where {K, V} = promote_type(V, promote_valuetype(y...))

keytype_hasmissing(x::Pair{K}) where {K} = K === Missing
keytype_hasmissing(x::Pair{K}, y::Pair...) where {K} = K === Missing || keytype_hasmissing(y...)

"""
    recode(a::AbstractArray[, default::Any], pairs::Pair...)

Return a copy of `a`, replacing elements matching a key of `pairs` with the corresponding value.
The type of the array is chosen so that it can
hold all recoded elements (but not necessarily original elements from `a`).

For each `Pair` in `pairs`, if the element is equal to (according to [`isequal`](@ref))
or [`in`](@ref) the key (first item of the pair), then the corresponding value
(second item) is used.
If the element matches no key and `default` is not provided or `nothing`, it is copied as-is;
if `default` is specified, it is used in place of the original element.
If an element matches more than one key, the first match is used.

# Examples
```jldoctest
julia> using CategoricalArrays

julia> recode(1:10, 1=>100, 2:4=>0, [5; 9:10]=>-1)
10-element Array{Int64,1}:
 100
   0
   0
   0
  -1
   6
   7
   8
  -1
  -1

```

     recode(a::AbstractArray{>:Missing}[, default::Any], pairs::Pair...)

If `a` contains missing values, they are never replaced with `default`:
use `missing` in a pair to recode them. If that's not the case, the returned array
will accept missing values.

# Examples
```jldoctest
julia> using CategoricalArrays, Missings

julia> recode(1:10, 1=>100, 2:4=>0, [5; 9:10]=>-1, 6=>missing)
10-element Array{Union{Int64, Missings.Missing},1}:
 100    
   0    
   0    
   0    
  -1    
    missing
   7    
   8    
  -1    
  -1    

```
"""
function recode end

recode(a::AbstractArray, pairs::Pair...) = recode(a, nothing, pairs...)

function recode(a::AbstractArray, default::Any, pairs::Pair...)
    V = promote_valuetype(pairs...)
    # T cannot take into account eltype(src), since we can't know
    # whether it matters at compile time (all levels recoded or not)
    # and using a wider type than necessary would be annoying
    T = default === nothing ? V : promote_type(typeof(default), V)
    # Exception: if original array accepted missing values and missing does not appear
    # in one of the pairs' LHS, result must accept missing values
    if T >: Missing || default === missing || (eltype(a) >: Missing && !keytype_hasmissing(pairs...))
        dest = Array{Union{T, Missing}}(size(a))
    else
        dest = Array{Missings.T(T)}(size(a))
    end
    recode!(dest, a, default, pairs...)
end

function recode(a::CategoricalArray{S, N, R}, default::Any, pairs::Pair...) where {S, N, R}
    V = promote_valuetype(pairs...)
    # T cannot take into account eltype(src), since we can't know
    # whether it matters at compile time (all levels recoded or not)
    # and using a wider type than necessary would be annoying
    T = default === nothing ? V : promote_type(typeof(default), V)
    # Exception: if original array accepted missing values and missing does not appear
    # in one of the pairs' LHS, result must accept missing values
    if T >: Missing || default === missing || (eltype(a) >: Missing && !keytype_hasmissing(pairs...))
        dest = CategoricalArray{Union{T, Missing}, N, R}(size(a))
    else
        dest = CategoricalArray{Missings.T(T), N, R}(size(a))
    end
    recode!(dest, a, default, pairs...)
end