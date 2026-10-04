# Copyright (c) 2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

const _InstancePath = Vector{Union{Int,String}}

struct SingleIssue
    x::Any
    path::String
    reason::String
    val::Any
    _segments::Union{Nothing,_InstancePath}
end

function SingleIssue(x, path::AbstractString, reason::AbstractString, val)
    segments = isempty(path) ? _InstancePath() : nothing
    return SingleIssue(x, String(path), String(reason), val, segments)
end

function SingleIssue(x, path::_InstancePath, reason, val)
    return SingleIssue(
        x,
        join("[$segment]" for segment in path),
        reason,
        val,
        copy(path),
    )
end

"""
    JSONSchema.json_pointer(issue::SingleIssue)

Return the validation issue's instance location as an RFC 6901 JSON Pointer URI
fragment. Array indices are zero-based; object keys retain their text. Escape `~`
and `/` in keys and percent-encode characters outside the URI unreserved set.
The root location is `"#"`.

The existing `issue.path` string retains its Julia-style representation, such as
`"[foo][1][bar]"`; its pointer is `"#/foo/0/bar"`. A manually constructed issue with
a nonempty string path has no unambiguous pointer and throws `ArgumentError`.
"""
function json_pointer(issue::SingleIssue)
    segments = issue._segments
    if segments === nothing
        throw(
            ArgumentError(
                "JSON pointer segments are unavailable for a manually constructed string path",
            ),
        )
    end
    io = IOBuffer()
    print(io, '#')
    for segment in segments
        token =
            segment isa Int ? string(segment - 1) :
            replace(segment, "~" => "~0", "/" => "~1")
        escaped = URIs.escapeuri(
            token,
            c -> isascii(c) && (isletter(c) || isnumeric(c) || c in "-._~"),
        )
        print(io, '/', escaped)
    end
    return String(take!(io))
end

function Base.show(io::IO, issue::SingleIssue)
    return println(
        io,
        """Validation failed:
path:         $(isempty(issue.path) ? "top-level" : issue.path)
instance:     $(issue.x)
schema key:   $(issue.reason)
schema value: $(issue.val)""",
    )
end

"""
    validate(s::Schema, x)

Validate the object `x` against the Schema `s`. If valid, return `nothing`, else
return a `SingleIssue`. When printed, the returned `SingleIssue` describes the
reason why the validation failed.


Note that if `x` is a `String` in JSON format, you must use `JSON.parse(x)`
before passing to `validate`, that is, JSONSchema operates on the parsed
representation, not on the underlying `String` representation of the JSON data.

## Examples

```julia
julia> schema = Schema(
            Dict(
                "properties" => Dict(
                    "foo" => Dict(),
                    "bar" => Dict()
                ),
                "required" => ["foo"]
            )
        )
Schema

julia> data_pass = Dict("foo" => true)
Dict{String,Bool} with 1 entry:
    "foo" => true

julia> data_fail = Dict("bar" => 12.5)
Dict{String,Float64} with 1 entry:
    "bar" => 12.5

julia> validate(data_pass, schema)

julia> validate(data_fail, schema)
Validation failed:
path:         top-level
instance:     Dict("bar"=>12.5)
schema key:   required
schema value: ["foo"]
```
"""
function validate(schema::Schema, x)
    return _validate(x, schema.data, _InstancePath())
end

Base.isvalid(schema::Schema, x) = validate(schema, x) === nothing

# Fallbacks for the opposite argument.
validate(x, schema::Schema) = validate(schema, x)
Base.isvalid(x, schema::Schema) = isvalid(schema, x)

function _validate(x, schema, path::_InstancePath)
    schema = _resolve_refs(schema)
    return _validate_entry(x, schema, path)
end

function _validate_child(x, schema, path::_InstancePath, segment)
    push!(path, segment)
    try
        return _validate(x, schema, path)
    finally
        pop!(path)
    end
end

function _validate_entry(x, schema::AbstractDict, path)
    for (k, v) in schema
        ret = _validate(x, schema, Val{Symbol(k)}(), v, path)
        if ret !== nothing
            return ret
        end
    end
    return
end

function _validate_entry(x, schema::Bool, path::_InstancePath)
    if !schema
        return SingleIssue(x, path, "schema", schema)
    end
    return
end

function _resolve_refs(schema::AbstractDict, explored_refs = nothing)
    if !haskey(schema, "\$ref")
        return schema
    end
    if explored_refs === nothing
        explored_refs = Any[schema]
    end
    schema = schema["\$ref"]
    if any(x -> x === schema, explored_refs)
        error("cannot support circular references in schema.")
    end
    push!(explored_refs, schema)
    return _resolve_refs(schema, explored_refs)
end
_resolve_refs(schema, explored_refs = nothing) = schema

# Default fallback
_validate(::Any, ::Any, ::Val, ::Any, ::_InstancePath) = nothing

# JSON treats == between Bool and Number differently to Julia, so:
#   false != 0
#   true != 1
#   0 == 0.0
#   1.0 == 1
# Both nothing and missing represent JSON null; do not propagate missing from ==.
_isequal(x, y) = (x === missing ? nothing : x) == (y === missing ? nothing : y)

_isequal(::Bool, ::Number) = false

_isequal(::Number, ::Bool) = false

_isequal(x::Bool, y::Bool) = x == y

function _isequal(x::AbstractVector, y::AbstractVector)
    return length(x) == length(y) && all(_isequal.(x, y))
end

function _isequal(x::AbstractDict, y::AbstractDict)
    return Set(keys(x)) == Set(keys(y)) &&
           all(_isequal(v, y[k]) for (k, v) in x)
end

###
### Core JSON Schema
###

# 9.2.1.1
function _validate(
    x,
    schema,
    ::Val{:allOf},
    val::AbstractVector,
    path::_InstancePath,
)
    for v in val
        ret = _validate(x, v, path)
        if ret !== nothing
            return ret
        end
    end
    return
end

# 9.2.1.2
function _validate(
    x,
    schema,
    ::Val{:anyOf},
    val::AbstractVector,
    path::_InstancePath,
)
    for v in val
        if _validate(x, v, path) === nothing
            return
        end
    end
    return SingleIssue(x, path, "anyOf", val)
end

# 9.2.1.3
function _validate(
    x,
    schema,
    ::Val{:oneOf},
    val::AbstractVector,
    path::_InstancePath,
)
    found_match = false
    for v in val
        if _validate(x, v, path) === nothing
            if found_match # Found more than one match!
                return SingleIssue(x, path, "oneOf", val)
            end
            found_match = true
        end
    end
    if !found_match
        return SingleIssue(x, path, "oneOf", val)
    end
    return
end

# 9.2.1.4
function _validate(x, schema, ::Val{:not}, val, path::_InstancePath)
    if _validate(x, val, path) === nothing
        return SingleIssue(x, path, "not", val)
    end
    return
end

# 9.2.2.1: if
function _validate(x, schema, ::Val{:if}, val, path::_InstancePath)
    # ignore if without then or else
    if haskey(schema, "then") || haskey(schema, "else")
        return _if_then_else(x, schema, path)
    end
    return
end

# 9.2.2.2: then
function _validate(x, schema, ::Val{:then}, val, path::_InstancePath)
    # ignore then without if
    if haskey(schema, "if")
        return _if_then_else(x, schema, path)
    end
    return
end

# 9.2.2.3: else
function _validate(x, schema, ::Val{:else}, val, path::_InstancePath)
    # ignore else without if
    if haskey(schema, "if")
        return _if_then_else(x, schema, path)
    end
    return
end

"""
    _if_then_else(x, schema, path)

The if, then and else keywords allow the application of a subschema based on the
outcome of another schema. Details are in the link and the truth table is as
follows:

```
┌─────┬──────┬──────┬────────┐
│ if  │ then │ else │ result │
├─────┼──────┼──────┼────────┤
│ T   │ T    │ n/a  │ T      │
│ T   │ F    │ n/a  │ F      │
│ F   │ n/a  │ T    │ T      │
│ F   │ n/a  │ F    │ F      │
│ n/a │ n/a  │ n/a  │ T      │
└─────┴──────┴──────┴────────┘
```

See https://json-schema.org/understanding-json-schema/reference/conditionals#ifthenelse
for details.
"""
function _if_then_else(x, schema, path)
    if _validate(x, schema["if"], path) !== nothing
        if haskey(schema, "else")
            return _validate(x, schema["else"], path)
        end
    elseif haskey(schema, "then")
        return _validate(x, schema["then"], path)
    end
    return
end

###
### Checks for Arrays.
###

# 9.3.1.1
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:items},
    val::AbstractDict,
    path::_InstancePath,
)
    items = fill(false, length(x))
    for (i, xi) in enumerate(x)
        ret = _validate_child(xi, val, path, i)
        if ret !== nothing
            return ret
        end
        items[i] = true
    end
    additionalItems = get(schema, "additionalItems", nothing)
    return _additional_items(x, schema, items, additionalItems, path)
end

function _validate(
    x::AbstractVector,
    schema,
    ::Val{:items},
    val::AbstractVector,
    path::_InstancePath,
)
    items = fill(false, length(x))
    for (i, xi) in enumerate(x)
        if i > length(val)
            break
        end
        ret = _validate_child(xi, val[i], path, i)
        if ret !== nothing
            return ret
        end
        items[i] = true
    end
    additionalItems = get(schema, "additionalItems", nothing)
    return _additional_items(x, schema, items, additionalItems, path)
end

function _validate(
    x::AbstractVector,
    schema,
    ::Val{:items},
    val::Bool,
    path::_InstancePath,
)
    if !val && length(x) > 0
        return SingleIssue(x, path, "items", val)
    end
    return
end

function _additional_items(x, schema, items, val, path)
    for i in 1:length(x)
        if items[i]
            continue  # Validated against 'items'.
        end
        ret = _validate_child(x[i], val, path, i)
        if ret !== nothing
            return ret
        end
    end
    return
end

function _additional_items(x, schema, items, val::Bool, path)
    if !val && !all(items)
        return SingleIssue(x, path, "additionalItems", val)
    end
    return
end

_additional_items(x, schema, items, val::Nothing, path) = nothing

# 9.3.1.2
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:additionalItems},
    val,
    path::_InstancePath,
)
    return  # Supported in `items`.
end

# 9.3.1.3: unevaluatedProperties

# 9.3.1.4
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:contains},
    val,
    path::_InstancePath,
)
    for (i, xi) in enumerate(x)
        ret = _validate_child(xi, val, path, i)
        if ret === nothing
            return
        end
    end
    return SingleIssue(x, path, "contains", val)
end

###
### Checks for Objects
###

# 9.3.2.1
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:properties},
    val::AbstractDict,
    path::_InstancePath,
)
    for (k, v) in x
        if haskey(val, k)
            ret = _validate_child(v, val[k], path, string(k))
            if ret !== nothing
                return ret
            end
        end
    end
    return
end

# 9.3.2.2
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:patternProperties},
    val::AbstractDict,
    path::_InstancePath,
)
    for (k_val, v_val) in val
        r = Regex(k_val)
        for (k_x, v_x) in x
            if match(r, k_x) === nothing
                continue
            end
            ret = _validate_child(v_x, v_val, path, string(k_x))
            if ret !== nothing
                return ret
            end
        end
    end
    return
end

# 9.3.2.3
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:additionalProperties},
    val::AbstractDict,
    path::_InstancePath,
)
    properties = get(schema, "properties", Dict{String,Any}())
    patternProperties = get(schema, "patternProperties", Dict{String,Any}())
    for (k, v) in x
        if k in keys(properties) ||
           any(r -> match(Regex(r), k) !== nothing, keys(patternProperties))
            continue
        end
        ret = _validate_child(v, val, path, string(k))
        if ret !== nothing
            return ret
        end
    end
    return
end

function _validate(
    x::AbstractDict,
    schema,
    ::Val{:additionalProperties},
    val::Bool,
    path::_InstancePath,
)
    if val
        return
    end
    properties = get(schema, "properties", Dict{String,Any}())
    patternProperties = get(schema, "patternProperties", Dict{String,Any}())
    for (k, v) in x
        if k in keys(properties) ||
           any(r -> match(Regex(r), k) !== nothing, keys(patternProperties))
            continue
        end
        return SingleIssue(x, path, "additionalProperties", val)
    end
    return
end

# 9.3.2.4: unevaluatedProperties

# 9.3.2.5
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:propertyNames},
    val,
    path::_InstancePath,
)
    for k in keys(x)
        ret = _validate(k, val, path)
        if ret !== nothing
            return ret
        end
    end
    return
end

###
### Checks for generic types.
###

# 6.1.1
function _validate(x, schema, ::Val{:type}, val::String, path::_InstancePath)
    if !_is_type(x, Val{Symbol(val)}())
        return SingleIssue(x, path, "type", val)
    end
    return
end

function _validate(
    x,
    schema,
    ::Val{:type},
    val::AbstractVector,
    path::_InstancePath,
)
    if !any(v -> _is_type(x, Val{Symbol(v)}()), val)
        return SingleIssue(x, path, "type", val)
    end
    return
end

_is_type(::Any, ::Val) = false
_is_type(::Array, ::Val{:array}) = true
_is_type(::Bool, ::Val{:boolean}) = true
_is_type(::Integer, ::Val{:integer}) = true
_is_type(x::Float64, ::Val{:integer}) = isinteger(x)
_is_type(::Real, ::Val{:number}) = true
_is_type(::Nothing, ::Val{:null}) = true
_is_type(::Missing, ::Val{:null}) = true
_is_type(::AbstractDict, ::Val{:object}) = true
_is_type(::String, ::Val{:string}) = true
# Note that Julia treat's Bool <: Number, but JSON-Schema distinguishes them.
_is_type(::Bool, ::Val{:number}) = false
_is_type(::Bool, ::Val{:integer}) = false

# 6.1.2
function _validate(x, schema, ::Val{:enum}, val, path::_InstancePath)
    if !any(_isequal(x, v) for v in val)
        return SingleIssue(x, path, "enum", val)
    end
    return
end

# 6.1.3
function _validate(x, schema, ::Val{:const}, val, path::_InstancePath)
    if !_isequal(x, val)
        return SingleIssue(x, path, "const", val)
    end
    return
end

###
### Checks for numbers.
###

# Bool is a Julia Number, but JSON numeric assertions do not apply to booleans.

# 6.2.1
function _validate(
    x::Number,
    schema,
    ::Val{:multipleOf},
    val::Number,
    path::_InstancePath,
)
    x isa Bool && return
    y = x / val
    if !isfinite(y) || !isapprox(y, round(y))
        return SingleIssue(x, path, "multipleOf", val)
    end
    return
end

# 6.2.2
function _validate(
    x::Number,
    schema,
    ::Val{:maximum},
    val::Number,
    path::_InstancePath,
)
    x isa Bool && return
    if x > val
        return SingleIssue(x, path, "maximum", val)
    end
    return
end

# 6.2.3
function _validate(
    x::Number,
    schema,
    ::Val{:exclusiveMaximum},
    val::Number,
    path::_InstancePath,
)
    x isa Bool && return
    if x >= val
        return SingleIssue(x, path, "exclusiveMaximum", val)
    end
    return
end

function _validate(
    x::Number,
    schema,
    ::Val{:exclusiveMaximum},
    val::Bool,
    path::_InstancePath,
)
    x isa Bool && return
    if val && x >= get(schema, "maximum", Inf)
        return SingleIssue(x, path, "exclusiveMaximum", val)
    end
    return
end

# 6.2.4
function _validate(
    x::Number,
    schema,
    ::Val{:minimum},
    val::Number,
    path::_InstancePath,
)
    x isa Bool && return
    if x < val
        return SingleIssue(x, path, "minimum", val)
    end
    return
end

# 6.2.5
function _validate(
    x::Number,
    schema,
    ::Val{:exclusiveMinimum},
    val::Number,
    path::_InstancePath,
)
    x isa Bool && return
    if x <= val
        return SingleIssue(x, path, "exclusiveMinimum", val)
    end
    return
end

function _validate(
    x::Number,
    schema,
    ::Val{:exclusiveMinimum},
    val::Bool,
    path::_InstancePath,
)
    x isa Bool && return
    if val && x <= get(schema, "minimum", -Inf)
        return SingleIssue(x, path, "exclusiveMinimum", val)
    end
    return
end

###
### Checks for strings.
###

# 6.3.1
function _validate(
    x::String,
    schema,
    ::Val{:maxLength},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) > val
        return SingleIssue(x, path, "maxLength", val)
    end
    return
end

# 6.3.2
function _validate(
    x::String,
    schema,
    ::Val{:minLength},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) < val
        return SingleIssue(x, path, "minLength", val)
    end
    return
end

# 6.3.3
function _validate(
    x::String,
    schema,
    ::Val{:pattern},
    val::String,
    path::_InstancePath,
)
    if !occursin(Regex(val), x)
        return SingleIssue(x, path, "pattern", val)
    end
    return
end

###
### Checks for arrays.
###

# 6.4.1
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:maxItems},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) > val
        return SingleIssue(x, path, "maxItems", val)
    end
    return
end

# 6.4.2
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:minItems},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) < val
        return SingleIssue(x, path, "minItems", val)
    end
    return
end

# 6.4.3
function _validate(
    x::AbstractVector,
    schema,
    ::Val{:uniqueItems},
    val::Bool,
    path::_InstancePath,
)
    if !val
        return
    end
    # TODO(odow): O(n^2) here. But probably not too bad, because there shouldn't
    # be a large x.
    for i in eachindex(x), j in eachindex(x)
        if i != j && _isequal(x[i], x[j])
            return SingleIssue(x, path, "uniqueItems", val)
        end
    end
    return
end

# 6.4.4: maxContains

# 6.4.5: minContains

###
### Checks for objects.
###

# 6.5.1
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:maxProperties},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) > val
        return SingleIssue(x, path, "maxProperties", val)
    end
    return
end

# 6.5.2
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:minProperties},
    val::Union{Integer,Float64},
    path::_InstancePath,
)
    if length(x) < val
        return SingleIssue(x, path, "minProperties", val)
    end
    return
end

# 6.5.3
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:required},
    val::AbstractVector,
    path::_InstancePath,
)
    if any(v -> !haskey(x, v), val)
        return SingleIssue(x, path, "required", val)
    end
    return
end

# 6.5.4
function _validate(
    x::AbstractDict,
    schema,
    ::Val{:dependencies},
    val::AbstractDict,
    path::_InstancePath,
)
    for (k, v) in val
        if !haskey(x, k)
            continue
        elseif !_dependencies(x, path, v)
            return SingleIssue(x, path, "dependencies", val)
        end
    end
    return
end

function _dependencies(
    x::AbstractDict,
    path::_InstancePath,
    val::Union{Bool,AbstractDict},
)
    return _validate(x, val, path) === nothing
end

function _dependencies(x::AbstractDict, path::_InstancePath, val::Array)
    return all(v -> haskey(x, v), val)
end
