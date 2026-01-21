# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# JSON Schema generation from Julia types
# Provides a simple, convenient interface for generating JSON Schema v7 specifications

# Helper functions for $ref support

"""
    defs_key_name(defs_location::Symbol) -> String

Get the proper key name for definitions/defs.
Converts :defs to "\$defs" and :definitions to "definitions".
"""
function defs_key_name(defs_location::Symbol)
    return defs_location == :defs ? "\$defs" : String(defs_location)
end

"""
    type_to_ref_name(::Type{T}) -> String

Generate a reference name for a type. Uses fully qualified names for disambiguation.
"""
function type_to_ref_name(::Type{T}) where {T}
    mod = T.name.module
    typename = nameof(T)

    # Handle parametric types: Vector{Int} -> "Vector_Int"
    if !isempty(T.parameters) && all(x -> x isa Type, T.parameters)
        param_str = join([type_to_ref_name(p) for p in T.parameters], "_")
        typename = "$(typename)_$(param_str)"
    end

    # Create clean reference name
    if mod === Main
        return String(typename)
    else
        # Use module path for disambiguation
        modpath = String(nameof(mod))
        return "$(modpath).$(typename)"
    end
end

"""
    should_use_ref(::Type{T}, ctx::Union{Nothing, SchemaContext}) -> Bool

Determine if a type should be referenced via \$ref instead of inlined.
"""
function should_use_ref(::Type{T}, ctx::Union{Nothing, SchemaContext}) where {T}
    # Never use refs if no context provided
    ctx === nothing && return false

    # Use ref for struct types that:
    # 1. Are concrete types (can be instantiated)
    # 2. Are struct types (not primitives)
    # 3. Are user-defined (not from Base/Core)

    if !isconcretetype(T) || !isstructtype(T)
        return false
    end

    modname = string(T.name.module)
    if modname in ("Core", "Base") || startswith(modname, "Base.")
        return false
    end

    return true
end

"""
    schema(T::Type; title=nothing, description=nothing, id=nothing, draft="https://json-schema.org/draft-07/schema#", all_fields_required=false, additionalProperties=nothing)

Generate a JSON Schema for type `T`. The schema is returned as a JSON-serializable `Object`.

# Keyword Arguments
- `all_fields_required::Bool=false`: If `true`, all fields of object schemas will be added to the required list.
- `additionalProperties::Union{Nothing,Bool}=nothing`: If `true` or `false`, sets `additionalProperties` recursively on the root and all child object schemas. If `nothing`, no additional action is taken.

Field-level schema properties can be specified using StructUtils field tags with the `json` key:

# Example
```julia
@defaults struct User
    id::Int = 0 &(json=(
        description="Unique user identifier",
        minimum=1
    ),)
    name::String = "" &(json=(
        description="User's full name",
        minLength=1,
        maxLength=100
    ),)
    email::Union{String, Nothing} = nothing &(json=(
        description="Email address",
        format="email"
    ),)
    age::Union{Int, Nothing} = nothing &(json=(
        minimum=0,
        maximum=150,
        exclusiveMaximum=false
    ),)
end

schema = JSON.schema(User)
```

# Supported Field Tag Properties

## String validation
- `minLength::Int`: Minimum string length
- `maxLength::Int`: Maximum string length
- `pattern::String`: Regular expression pattern (ECMA-262)
- `format::String`: Format hint (e.g., "email", "uri", "date-time", "uuid")

## Numeric validation
- `minimum::Number`: Minimum value (inclusive)
- `maximum::Number`: Maximum value (inclusive)
- `exclusiveMinimum::Bool|Number`: Exclusive minimum
- `exclusiveMaximum::Bool|Number`: Exclusive maximum
- `multipleOf::Number`: Value must be multiple of this

## Array validation
- `minItems::Int`: Minimum array length
- `maxItems::Int`: Maximum array length
- `uniqueItems::Bool`: All items must be unique

## Object validation
- `minProperties::Int`: Minimum number of properties
- `maxProperties::Int`: Maximum number of properties

## Generic
- `description::String`: Human-readable description
- `title::String`: Short title for the field
- `default::Any`: Default value
- `examples::Vector`: Example values
- `_const::Any`: Field must have this exact value (use `_const` since `const` is a reserved keyword)
- `enum::Vector`: Field must be one of these values
- `required::Bool`: Override required inference (default: true for non-Union{T,Nothing} types)

## Composition
- `allOf::Vector{Type}`: Must validate against all schemas
- `anyOf::Vector{Type}`: Must validate against at least one schema
- `oneOf::Vector{Type}`: Must validate against exactly one schema

The function automatically:
- Maps Julia types to JSON Schema types
- Marks non-`Nothing` union fields as required
- Handles nested types and arrays
- Supports custom types via registered converters

# Returns
A `Schema{T}` object that contains both the type information and the JSON Schema specification.
The schema can be used for validation with `JSON.isvalid(schema, instance)`.
"""
function schema(
        ::Type{T};
        title::Union{String, Nothing} = nothing,
        description::Union{String, Nothing} = nothing,
        id::Union{String, Nothing} = nothing,
        draft::String = "https://json-schema.org/draft-07/schema#",
        refs::Union{Bool, Symbol} = false,
        context::Union{Nothing, SchemaContext} = nothing,
        all_fields_required::Bool = false,
        additionalProperties::Union{Nothing, Bool} = nothing
    ) where {T}

    # Determine context based on parameters
    ctx = if context !== nothing
        context  # Use provided context
    elseif refs !== false
        # Create new context based on refs option
        defs_loc = refs === true ? :definitions : refs
        SchemaContext(defs_loc)
    else
        nothing  # No refs - use current inline behavior
    end

    obj = Object{String, Any}()
    obj["\$schema"] = draft

    if id !== nothing
        obj["\$id"] = id
    end

    if title !== nothing
        obj["title"] = title
    elseif hasproperty(T, :name)
        obj["title"] = string(nameof(T))
    end

    if description !== nothing
        obj["description"] = description
    end

    # Generate the type schema and merge it (pass context and all_fields_required)
    type_schema = _type_to_schema(T, ctx; all_fields_required = all_fields_required)
    for (k, v) in type_schema
        obj[k] = v
    end

    # Add definitions if context was used
    if ctx !== nothing && !isempty(ctx.definitions)
        obj[defs_key_name(ctx.defs_location)] = ctx.definitions
    end

    # Recursively set additionalProperties if specified
    # This will process the root schema and all nested schemas, including definitions
    if additionalProperties !== nothing
        _set_additional_properties_recursive!(obj, additionalProperties, ctx)
    end

    return Schema{T}(T, obj, ctx)
end

# Internal: Convert a Julia type to JSON Schema representation
function _type_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    # Handle Any and abstract types specially to avoid infinite recursion
    if T === Any
        return Object{String, Any}()  # Allow any type
    end

    # Handle Union types (including Union{T, Nothing})
    if T isa Union
        return _union_to_schema(T, ctx; all_fields_required = all_fields_required)
    end

    # Primitive types (check Bool first since Bool <: Integer in Julia!)
    if T === Bool
        return Object{String, Any}("type" => "boolean")
    elseif T === Nothing || T === Missing
        return Object{String, Any}("type" => "null")
    elseif T === Int || T === Int64 || T === Int32 || T === Int16 || T === Int8 ||
            T === UInt || T === UInt64 || T === UInt32 || T === UInt16 || T === UInt8 ||
            T <: Integer
        return Object{String, Any}("type" => "integer")
    elseif T === Float64 || T === Float32 || T <: AbstractFloat
        return Object{String, Any}("type" => "number")
    elseif T === String || T <: AbstractString
        return Object{String, Any}("type" => "string")
    end

    # Handle parametric types
    if T <: AbstractVector
        return _array_to_schema(T, ctx; all_fields_required = all_fields_required)
    elseif T <: AbstractDict
        return _dict_to_schema(T, ctx; all_fields_required = all_fields_required)
    elseif T <: AbstractSet
        return _set_to_schema(T, ctx; all_fields_required = all_fields_required)
    elseif T <: Tuple
        return _tuple_to_schema(T, ctx; all_fields_required = all_fields_required)
    end

    # Struct types - try to process user-defined structs
    if isconcretetype(T) && !isabstracttype(T) && isstructtype(T)
        # Avoid processing internal compiler types that could cause issues
        modname = string(T.name.module)
        if (T <: NamedTuple) || (!(modname in ("Core", "Base")) && !startswith(modname, "Base."))
            try
                # Check if we should use $ref for this struct
                if should_use_ref(T, ctx)
                    return _struct_to_schema_with_refs(T, ctx; all_fields_required = all_fields_required)
                else
                    return _struct_to_schema_core(T, ctx; all_fields_required = all_fields_required)
                end
            catch
                # If struct processing fails, fall through to fallback
            end
        end
    end

    # Fallback: allow any type
    return Object{String, Any}()
end

# Handle Union types
function _union_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    types = Base.uniontypes(T)

    # Special case: Union{T, Nothing} - make nullable
    if length(types) == 2 && (Nothing in types || Missing in types)
        non_null_type = types[1] === Nothing || types[1] === Missing ? types[2] : types[1]
        schema = _type_to_schema(non_null_type, ctx; all_fields_required = all_fields_required)

        # If the schema is a $ref, we need to use oneOf (can't mix $ref with other properties)
        if haskey(schema, "\$ref")
            obj = Object{String, Any}()
            obj["oneOf"] = [schema, Object{String, Any}("type" => "null")]
            return obj
        end

        # Otherwise, add null as allowed type
        if haskey(schema, "type")
            if schema["type"] isa Vector
                push!(schema["type"], "null")
            else
                schema["type"] = [schema["type"], "null"]
            end
        else
            schema["type"] = "null"
        end

        return schema
    end

    # General union: use oneOf (exactly one must match)
    # Note: We use oneOf instead of anyOf because Julia's Union types
    # require the value to be exactly one of the types, not multiple
    obj = Object{String, Any}()
    obj["oneOf"] = [_type_to_schema(t, ctx; all_fields_required = all_fields_required) for t in types]
    return obj
end

# Handle array types
function _array_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    obj = Object{String, Any}("type" => "array")

    # Get element type
    if T <: AbstractVector
        eltype_t = eltype(T)
        obj["items"] = _type_to_schema(eltype_t, ctx; all_fields_required = all_fields_required)
    end

    return obj
end

# Handle dictionary types
function _dict_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    obj = Object{String, Any}("type" => "object")

    # Get value type for additionalProperties
    if T <: AbstractDict
        valtype_t = valtype(T)
        if valtype_t !== Union{}
            # For Any type, we return an empty schema which means "allow anything"
            obj["additionalProperties"] = _type_to_schema(valtype_t, ctx; all_fields_required = all_fields_required)
        end
    end

    return obj
end

# Handle set types
function _set_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    obj = Object{String, Any}("type" => "array")
    obj["uniqueItems"] = true

    # Get element type
    if T <: AbstractSet
        eltype_t = eltype(T)
        obj["items"] = _type_to_schema(eltype_t, ctx; all_fields_required = all_fields_required)
    end

    return obj
end

# Handle tuple types
function _tuple_to_schema(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    obj = Object{String, Any}("type" => "array")

    # Tuples have fixed-length items with specific types
    # JSON Schema Draft 7 uses "items" as an array for tuple validation
    if T.parameters !== () && all(x -> x isa Type, T.parameters)
        obj["items"] = [_type_to_schema(t, ctx; all_fields_required = all_fields_required) for t in T.parameters]
        obj["minItems"] = length(T.parameters)
        obj["maxItems"] = length(T.parameters)
    end

    return obj
end

# Handle struct types with $ref support (circular reference detection)
function _struct_to_schema_with_refs(::Type{T}, ctx::SchemaContext; all_fields_required::Bool = false) where {T}
    # Get the proper key name for definitions
    defs_key = defs_key_name(ctx.defs_location)

    # Check if we're already generating this type (circular reference!)
    if T in ctx.generation_stack
        # Generate $ref immediately - definition will be completed later
        ref_name = type_to_ref_name(T)
        ctx.type_names[T] = ref_name
        return Object{String, Any}("\$ref" => "#/$(defs_key)/$(ref_name)")
    end

    # Check if already defined (deduplication)
    if haskey(ctx.type_names, T)
        ref_name = ctx.type_names[T]
        return Object{String, Any}("\$ref" => "#/$(defs_key)/$(ref_name)")
    end

    # Mark as being generated (prevents infinite recursion)
    push!(ctx.generation_stack, T)
    ref_name = type_to_ref_name(T)
    ctx.type_names[T] = ref_name

    try
        # Generate the actual schema (may recursively call this function)
        schema_obj = _struct_to_schema_core(T, ctx; all_fields_required = all_fields_required)

        # Store in definitions
        ctx.definitions[ref_name] = schema_obj

        # Return a reference
        return Object{String, Any}("\$ref" => "#/$(defs_key)/$(ref_name)")
    finally
        # Always pop from stack, even if error occurs
        pop!(ctx.generation_stack)
    end
end

# Handle struct types (core logic without ref handling)
function _struct_to_schema_core(::Type{T}, ctx::Union{Nothing, SchemaContext} = nothing; all_fields_required::Bool = false) where {T}
    obj = Object{String, Any}("type" => "object")
    properties = Object{String, Any}()
    required = String[]

    # Iterate over fields
    if fieldcount(T) == 0
        obj["properties"] = properties
        return obj
    end

    style = StructUtils.DefaultStyle()
    # Get all field tags at once (returns NamedTuple with field names as keys)
    all_field_tags = StructUtils.fieldtags(style, T)

    for i in 1:fieldcount(T)
        fname = fieldname(T, i)
        ftype = fieldtype(T, i)

        # Get field tags for this specific field
        tags = _json_field_tags(all_field_tags, fname)

        # Skip ignored fields
        if _field_ignored(tags)
            continue
        end

        # Determine JSON key name (may be renamed via tags)
        json_name = _json_field_name(fname, tags)

        # Generate schema for this field (pass context for ref support)
        field_schema = _type_to_schema(ftype, ctx; all_fields_required = all_fields_required)

        # Apply field tags to schema
        if tags isa NamedTuple
            _apply_field_tags!(field_schema, tags, ftype)
        end

        # Check if field should be required
        is_required = all_fields_required || _is_required_field(ftype, tags)
        if is_required
            push!(required, json_name)
        end

        properties[json_name] = field_schema
    end

    if length(properties) > 0
        obj["properties"] = properties
    end

    if length(required) > 0
        obj["required"] = required
    end

    return obj
end

# Determine if a field is required
function _is_required_field(::Type{T}, tags) where {T}
    # Check explicit required tag
    if tags isa NamedTuple && haskey(tags, :required)
        return Bool(tags.required)
    end

    # By default, Union{T, Nothing} fields are optional
    if T isa Union
        types = Base.uniontypes(T)
        if Nothing in types || Missing in types
            return false
        end
    end

    # All other fields are required by default
    return true
end

# Recursively set additionalProperties on all object schemas
function _set_additional_properties_recursive!(schema_obj::Object{String, Any}, value::Bool, ctx::Union{Nothing, SchemaContext})
    # Skip $ref schemas - they're references, not actual schemas
    if haskey(schema_obj, "\$ref")
        return
    end

    # Set additionalProperties on object schemas
    # Check if it's an object type or has properties (which indicates an object schema)
    if (haskey(schema_obj, "type") && schema_obj["type"] == "object") || haskey(schema_obj, "properties")
        schema_obj["additionalProperties"] = value
    end

    # Recursively process nested schemas
    # Properties
    if haskey(schema_obj, "properties")
        for (_, prop_schema) in schema_obj["properties"]
            if prop_schema isa Object{String, Any}
                _set_additional_properties_recursive!(prop_schema, value, ctx)
            end
        end
    end

    # Items (for arrays)
    if haskey(schema_obj, "items")
        items = schema_obj["items"]
        if items isa Object{String, Any}
            _set_additional_properties_recursive!(items, value, ctx)
        elseif items isa AbstractVector
            for item_schema in items
                if item_schema isa Object{String, Any}
                    _set_additional_properties_recursive!(item_schema, value, ctx)
                end
            end
        end
    end

    # Composition schemas
    for key in ["allOf", "anyOf", "oneOf"]
        if haskey(schema_obj, key) && schema_obj[key] isa AbstractVector
            for sub_schema in schema_obj[key]
                if sub_schema isa Object{String, Any}
                    _set_additional_properties_recursive!(sub_schema, value, ctx)
                end
            end
        end
    end

    # Conditional schemas
    for key in ["if", "then", "else"]
        if haskey(schema_obj, key) && schema_obj[key] isa Object{String, Any}
            _set_additional_properties_recursive!(schema_obj[key], value, ctx)
        end
    end

    # Not schema
    if haskey(schema_obj, "not") && schema_obj["not"] isa Object{String, Any}
        _set_additional_properties_recursive!(schema_obj["not"], value, ctx)
    end

    # Contains schema (for arrays)
    if haskey(schema_obj, "contains") && schema_obj["contains"] isa Object{String, Any}
        _set_additional_properties_recursive!(schema_obj["contains"], value, ctx)
    end

    # Pattern properties
    if haskey(schema_obj, "patternProperties")
        for (_, pattern_schema) in schema_obj["patternProperties"]
            if pattern_schema isa Object{String, Any}
                _set_additional_properties_recursive!(pattern_schema, value, ctx)
            end
        end
    end

    # Property names schema
    if haskey(schema_obj, "propertyNames") && schema_obj["propertyNames"] isa Object{String, Any}
        _set_additional_properties_recursive!(schema_obj["propertyNames"], value, ctx)
    end

    # Additional items (for tuples)
    if haskey(schema_obj, "additionalItems") && schema_obj["additionalItems"] isa Object{String, Any}
        _set_additional_properties_recursive!(schema_obj["additionalItems"], value, ctx)
    end

    # Dependencies (schema-based)
    if haskey(schema_obj, "dependencies")
        for (_, dep) in schema_obj["dependencies"]
            if dep isa Object{String, Any}
                _set_additional_properties_recursive!(dep, value, ctx)
            end
        end
    end

    # Definitions/$defs (process all definitions recursively)
    for defs_key in ["definitions", "\$defs"]
        if haskey(schema_obj, defs_key) && schema_obj[defs_key] isa Object{String, Any}
            for (_, def_schema) in schema_obj[defs_key]
                if def_schema isa Object{String, Any}
                    _set_additional_properties_recursive!(def_schema, value, ctx)
                end
            end
        end
    end
    return
end

# Apply field tags to a schema object
function _apply_field_tags!(schema::Object{String, Any}, tags::NamedTuple, ftype::Type)
    # String validation
    haskey(tags, :minLength) && (schema["minLength"] = tags.minLength)
    haskey(tags, :maxLength) && (schema["maxLength"] = tags.maxLength)
    haskey(tags, :pattern) && (schema["pattern"] = tags.pattern)
    haskey(tags, :format) && (schema["format"] = string(tags.format))

    # Numeric validation
    haskey(tags, :minimum) && (schema["minimum"] = tags.minimum)
    haskey(tags, :maximum) && (schema["maximum"] = tags.maximum)
    haskey(tags, :exclusiveMinimum) && (schema["exclusiveMinimum"] = tags.exclusiveMinimum)
    haskey(tags, :exclusiveMaximum) && (schema["exclusiveMaximum"] = tags.exclusiveMaximum)
    haskey(tags, :multipleOf) && (schema["multipleOf"] = tags.multipleOf)

    # Array validation
    haskey(tags, :minItems) && (schema["minItems"] = tags.minItems)
    haskey(tags, :maxItems) && (schema["maxItems"] = tags.maxItems)
    haskey(tags, :uniqueItems) && (schema["uniqueItems"] = tags.uniqueItems)

    # Items schema (can be single schema or array for tuple validation)
    if haskey(tags, :items)
        items = tags.items
        if items isa AbstractVector
            # Tuple validation: array of schemas
            schema["items"] = [item isa Type ? _type_to_schema(item) : item for item in items]
        else
            # Single schema applies to all items
            schema["items"] = items isa Type ? _type_to_schema(items) : items
        end
    end

    # Object validation
    haskey(tags, :minProperties) && (schema["minProperties"] = tags.minProperties)
    haskey(tags, :maxProperties) && (schema["maxProperties"] = tags.maxProperties)

    # Generic properties
    haskey(tags, :description) && (schema["description"] = string(tags.description))
    haskey(tags, :title) && (schema["title"] = string(tags.title))
    haskey(tags, :examples) && (schema["examples"] = collect(tags.examples))
    (haskey(tags, :_const) || haskey(tags, Symbol("const"))) && (schema["const"] = get(tags, :_const, get(tags, Symbol("const"), nothing)))
    haskey(tags, :enum) && (schema["enum"] = collect(tags.enum))

    # Default value
    if haskey(tags, :default)
        schema["default"] = tags.default
    end

    # Composition (allOf, anyOf, oneOf)
    # These can be either Type objects or Dict/Object schemas
    if haskey(tags, :allOf) && tags.allOf isa Vector
        schema["allOf"] = [t isa Type ? _type_to_schema(t) : t for t in tags.allOf]
    end
    if haskey(tags, :anyOf) && tags.anyOf isa Vector
        schema["anyOf"] = [t isa Type ? _type_to_schema(t) : t for t in tags.anyOf]
    end
    if haskey(tags, :oneOf) && tags.oneOf isa Vector
        schema["oneOf"] = [t isa Type ? _type_to_schema(t) : t for t in tags.oneOf]
    end

    # Negation (not)
    if haskey(tags, :not)
        schema["not"] = tags.not isa Type ? _type_to_schema(tags.not) : tags.not
    end

    # Array contains
    return if haskey(tags, :contains)
        schema["contains"] = tags.contains isa Type ? _type_to_schema(tags.contains) : tags.contains
    end
end
