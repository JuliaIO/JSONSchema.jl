# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Shared types and helpers for schema generation and validation

# Context for tracking type definitions during schema generation with $ref support
mutable struct SchemaContext
    # Map from Type to definition name
    type_names::Dict{Type, String}
    # Map from definition name to schema
    definitions::Object{String, Any}
    # Stack to detect circular references during generation
    generation_stack::Vector{Type}
    # Where to store definitions: :definitions (Draft 7) or :defs (Draft 2019+)
    defs_location::Symbol

    SchemaContext(defs_location::Symbol = :definitions) = new(
        Dict{Type, String}(),
        Object{String, Any}(),
        Type[],
        defs_location
    )
end

"""
    Schema{T}

A typed JSON Schema for type `T`. Contains the schema specification and can be used
for validation via `isvalid` (which overloads `Base.isvalid`).

# Fields
- `type::Type{T}`: The Julia type this schema describes
- `spec::Object{String, Any}`: The JSON Schema specification

# Example
```julia
using JSONSchema, StructUtils

@defaults struct User
    name::String = ""
    email::String = ""
    age::Int = 0
end

schema = JSONSchema.schema(User)
instance = User("alice", "alice@example.com", 25)
isvalid(schema, instance)  # returns true
```
"""
struct Schema{T}
    type::Type{T}
    spec::Object{String, Any}
    context::Union{Nothing, SchemaContext}

    # Existing constructor (unchanged for backwards compatibility)
    Schema{T}(type::Type{T}, spec::Object{String, Any}) where {T} = new{T}(type, spec, nothing)
    # New constructor with context
    Schema{T}(type::Type{T}, spec::Object{String, Any}, ctx::Union{Nothing, SchemaContext}) where {T} = new{T}(type, spec, ctx)
end

Base.getindex(s::Schema, key) = s.spec[key]
Base.haskey(s::Schema, key) = haskey(s.spec, key)
Base.keys(s::Schema) = keys(s.spec)
Base.get(s::Schema, key, default) = get(s.spec, key, default)

# Constructors for creating Schema from spec objects (for test suite compatibility)
function Schema(spec)
    spec_obj = spec isa Object ? spec : Object{String, Any}(spec)
    return Schema{Any}(Any, spec_obj, nothing)
end
Schema(spec::AbstractString) = Schema(JSON.parse(spec))
Schema(spec::AbstractVector{UInt8}) = Schema(JSON.parse(spec))

# Boolean schemas are part of the draft6 specification.
function Schema(b::Bool)
    if b
        # true schema accepts everything - empty schema
        return Schema{Any}(Any, Object{String, Any}(), nothing)
    else
        # false schema rejects everything - use "not: {}" pattern
        return Schema{Any}(Any, Object{String, Any}("not" => Object{String, Any}()), nothing)
    end
end

# Internal helpers for field tags and JSON names.
function _json_field_tags(all_field_tags, fname::Symbol)
    field_tags = haskey(all_field_tags, fname) ? all_field_tags[fname] : nothing
    return field_tags isa NamedTuple && haskey(field_tags, :json) ? field_tags.json : nothing
end

function _json_field_name(fname::Symbol, tags)
    return tags isa NamedTuple && haskey(tags, :name) ? string(tags.name) : string(fname)
end

function _field_ignored(tags)
    return tags isa NamedTuple && get(tags, :ignore, false)
end

# Allow JSON serialization of Schema objects
StructUtils.lower(::JSONWriteStyle, s::Schema) = s.spec
