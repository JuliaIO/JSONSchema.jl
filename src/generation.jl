# Copyright (c) 2018: fredo-dedup and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

const DEFAULT_GENERATED_DRAFT = "https://json-schema.org/draft-07/schema#"

"""
    schema(::Type{T}; kwargs...) where {T}

Generate a small JSON Schema for Julia data type `T`.

This generator intentionally covers the type shapes used by agent tool
parameters: `NamedTuple`s, concrete structs, scalar JSON primitives, vectors,
dicts, tuples, and nullable unions such as `Union{Nothing, String}`.

Keyword arguments:
- `draft`: URI to place in the generated `"\$schema"` field.
- `all_fields_required`: mark every object field as required, including fields
  whose type admits `nothing` or `missing`.
- `additionalProperties`: when set to a boolean, apply that value to generated
  object schemas that have fixed properties.

`refs` is accepted for provider compatibility; generated schemas are inlined
in this first pass.
"""
function schema(
    ::Type{T};
    draft::AbstractString = DEFAULT_GENERATED_DRAFT,
    refs = false,
    all_fields_required::Bool = false,
    additionalProperties::Union{Nothing,Bool} = nothing,
) where {T}
    generated = _schema_for_type(T; all_fields_required, draft)
    generated["\$schema"] = String(draft)
    if additionalProperties !== nothing
        _set_additional_properties!(generated, additionalProperties)
    end
    return Schema(generated)
end

function _schema_for_type(
    ::Type{T};
    all_fields_required::Bool,
    draft::AbstractString,
) where {T}
    if T === Any
        return Dict{String,Any}()
    elseif T === Nothing || T === Missing
        return Dict{String,Any}("type" => "null")
    elseif _is_union_type(T)
        return _union_schema(T; all_fields_required, draft)
    elseif T <: AbstractString || T <: Symbol
        return Dict{String,Any}("type" => "string")
    elseif T <: Bool
        return Dict{String,Any}("type" => "boolean")
    elseif T <: Integer
        return Dict{String,Any}("type" => "integer")
    elseif T <: Real
        return Dict{String,Any}("type" => "number")
    elseif T <: NamedTuple
        return _object_schema(
            fieldnames(T),
            fieldtypes(T);
            all_fields_required,
            draft,
        )
    elseif T <: AbstractVector
        return _array_schema(eltype(T); all_fields_required, draft)
    elseif T <: Tuple
        return _tuple_schema(T; all_fields_required, draft)
    elseif T <: AbstractDict
        return _dict_schema(T; all_fields_required, draft)
    elseif isconcretetype(T) && isstructtype(T)
        return _object_schema(
            fieldnames(T),
            fieldtypes(T);
            all_fields_required,
            draft,
        )
    else
        return Dict{String,Any}()
    end
end

_is_union_type(::Type{T}) where {T} = T isa Union

function _union_schema(
    ::Type{T};
    all_fields_required::Bool,
    draft::AbstractString,
) where {T}
    union_types = Base.uniontypes(T)
    nullable = any(t -> t === Nothing || t === Missing, union_types)
    non_null_types = filter(t -> t !== Nothing && t !== Missing, union_types)

    if isempty(non_null_types)
        return Dict{String,Any}("type" => "null")
    end

    if length(non_null_types) == 1
        schema = _schema_for_type(
            first(non_null_types);
            all_fields_required,
            draft,
        )
        nullable && return _nullable_schema(schema)
        return schema
    end

    alternatives = Any[
        _schema_for_type(t; all_fields_required, draft) for t in non_null_types
    ]
    if nullable
        push!(alternatives, Dict{String,Any}("type" => "null"))
    end
    return Dict{String,Any}("anyOf" => alternatives)
end

function _nullable_schema(schema::AbstractDict)
    schema = deepcopy(schema)
    typ = get(schema, "type", nothing)
    if typ isa AbstractString
        schema["type"] = Any[typ, "null"]
    elseif typ isa AbstractVector
        values = Any[typ...]
        "null" in values || push!(values, "null")
        schema["type"] = values
    else
        schema = Dict{String,Any}(
            "anyOf" => Any[schema, Dict{String,Any}("type" => "null")],
        )
    end
    return schema
end

function _array_schema(
    ::Type{T};
    all_fields_required::Bool,
    draft::AbstractString,
) where {T}
    return Dict{String,Any}(
        "type" => "array",
        "items" => _schema_for_type(T; all_fields_required, draft),
    )
end

function _tuple_schema(
    ::Type{T};
    all_fields_required::Bool,
    draft::AbstractString,
) where {T}
    parameters = collect(T.parameters)
    if _is_unbounded_vararg_tuple(parameters)
        fixed_parameters = parameters[1:end-1]
        vararg_type = getfield(parameters[end], :T)
        if isempty(fixed_parameters)
            return _array_schema(vararg_type; all_fields_required, draft)
        end

        fixed_schemas = Any[
            _schema_for_type(t; all_fields_required, draft) for t in fixed_parameters
        ]
        generated = Dict{String,Any}(
            "type" => "array",
            "minItems" => length(fixed_parameters),
        )
        if _uses_prefix_items(draft)
            generated["prefixItems"] = fixed_schemas
            generated["items"] = _schema_for_type(
                vararg_type;
                all_fields_required,
                draft,
            )
        else
            generated["items"] = fixed_schemas
            generated["additionalItems"] = _schema_for_type(
                vararg_type;
                all_fields_required,
                draft,
            )
        end
        return generated
    end

    tuple_types = fieldtypes(T)
    if isempty(tuple_types)
        return Dict{String,Any}(
            "type" => "array",
            "maxItems" => 0,
        )
    end

    tuple_schemas = Any[
        _schema_for_type(t; all_fields_required, draft) for t in tuple_types
    ]
    generated = Dict{String,Any}(
        "type" => "array",
        "minItems" => length(tuple_types),
        "maxItems" => length(tuple_types),
    )
    if _uses_prefix_items(draft)
        generated["prefixItems"] = tuple_schemas
    else
        generated["items"] = tuple_schemas
        generated["additionalItems"] = false
    end
    return generated
end

function _is_unbounded_vararg_tuple(parameters)
    return !isempty(parameters) &&
           parameters[end] isa Core.TypeofVararg &&
           !isdefined(parameters[end], :N)
end

function _uses_prefix_items(draft::AbstractString)
    return occursin("2019-09", draft) || occursin("2020-12", draft)
end

function _dict_schema(
    ::Type{T};
    all_fields_required::Bool,
    draft::AbstractString,
) where {T}
    value_schema = _schema_for_type(valtype(T); all_fields_required, draft)
    return Dict{String,Any}(
        "type" => "object",
        "additionalProperties" => value_schema,
    )
end

function _object_schema(
    names,
    types::Tuple;
    all_fields_required::Bool,
    draft::AbstractString,
)
    properties = Dict{String,Any}()
    required = String[]
    for (name, type) in zip(names, types)
        field_name = string(name)
        properties[field_name] = _schema_for_type(
            type;
            all_fields_required,
            draft,
        )
        if all_fields_required || _is_required_type(type)
            push!(required, field_name)
        end
    end
    generated = Dict{String,Any}(
        "type" => "object",
        "properties" => properties,
    )
    if !isempty(required)
        generated["required"] = required
    end
    return generated
end

function _is_required_type(::Type{T}) where {T}
    return !(Nothing <: T) && !(Missing <: T)
end

function _set_additional_properties!(schema, value::Bool)
    return schema
end

function _set_additional_properties!(schema::AbstractVector, value::Bool)
    for item in schema
        _set_additional_properties!(item, value)
    end
    return schema
end

function _set_additional_properties!(schema::AbstractDict, value::Bool)
    if haskey(schema, "properties")
        schema["additionalProperties"] = value
    elseif get(schema, "type", nothing) == "object" &&
           !haskey(schema, "additionalProperties")
        schema["additionalProperties"] = value
    end
    for key in ("properties", "\$defs", "definitions")
        children = get(schema, key, nothing)
        if children isa AbstractDict
            for child in values(children)
                _set_additional_properties!(child, value)
            end
        end
    end
    for key in ("items", "additionalProperties")
        child = get(schema, key, nothing)
        _set_additional_properties!(child, value)
    end
    for key in ("prefixItems", "anyOf", "oneOf", "allOf")
        children = get(schema, key, nothing)
        _set_additional_properties!(children, value)
    end
    return schema
end
