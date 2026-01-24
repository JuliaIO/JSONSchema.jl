# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Validation functionality

# Helper: Resolve a $ref reference
function _resolve_ref(ref_path::String, root_schema::Object{String, Any})
    # Handle JSON Pointer syntax: "#/definitions/User" or "#/$defs/User"
    if startswith(ref_path, "#/")
        parts = split(ref_path[3:end], '/')  # Skip "#/"
        current = root_schema
        for part in parts
            # Convert SubString to String for Object key lookup
            key = String(part)
            if !haskey(current, key)
                error("Reference not found: $ref_path")
            end
            current = current[key]
        end
        return current
    end

    error("External refs not supported: $ref_path")
end

"""
    ValidationResult

Result of a schema validation operation.

# Fields
- `is_valid::Bool`: Whether the validation was successful
- `errors::Vector{String}`: List of validation error messages (empty if valid)
"""
struct ValidationResult
    is_valid::Bool
    errors::Vector{String}
end

"""
    validate(schema::Schema{T}, instance::T) -> Union{Nothing, ValidationResult}

Validate that `instance` satisfies all constraints defined in `schema`.
Returns `nothing` if valid, or a `ValidationResult` containing error messages if invalid.

# Example
```julia
result = validate(schema, instance)
if result !== nothing
    for err in result.errors
        println(err)
    end
end
```
"""
function validate(schema::Schema{T}, instance::T; resolver = nothing) where {T}
    errors = String[]
    # Pass root schema for $ref resolution
    _validate_instance(schema.spec, instance, T, "", errors, false, schema.spec)
    return isempty(errors) ? nothing : ValidationResult(false, errors)
end

# Also support JSON.Schema (which is an alias for JSONSchema.Schema)
# and inverse argument order for v1.5.0 compatibility
function validate(schema, instance; resolver = nothing)
    # Handle JSON.Schema (which is aliased to JSONSchema.Schema)
    if typeof(schema).name.module === JSON && hasfield(typeof(schema), :type) && hasfield(typeof(schema), :spec)
        return validate(Schema{typeof(schema).parameters[1]}(schema.type, schema.spec, nothing), instance; resolver = resolver)
    end
    error("Unsupported schema type: $(typeof(schema))")
end

# Minimal RefResolver for test suite compatibility
mutable struct RefResolver
    root::Any
    store::Dict{String, Any}
    base_map::IdDict{Any, String}
    seen::IdDict{Any, Bool}
    loaded::Dict{String, Bool}
    remote_loader::Union{Nothing, Function}
end

function RefResolver(root; base_uri::AbstractString = "", remote_loader = nothing)
    resolver = RefResolver(
        root,
        Dict{String, Any}(),
        IdDict{Any, String}(),
        IdDict{Any, Bool}(),
        Dict{String, Bool}(),
        remote_loader
    )
    return resolver
end

"""
    Base.isvalid(schema::Schema{T}, instance::T; verbose=false) -> Bool

Validate that `instance` satisfies all constraints defined in `schema`.

This function extends `Base.isvalid` and checks that the instance meets all
validation requirements specified in the schema's field tags, including:
- String constraints (minLength, maxLength, pattern, format)
- Numeric constraints (minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf)
- Array constraints (minItems, maxItems, uniqueItems)
- Enum and const values
- Nested struct validation

# Arguments
- `schema::Schema{T}`: The schema to validate against
- `instance::T`: The instance to validate
- `verbose::Bool=false`: If true, print detailed validation errors to stdout

# Returns
`true` if the instance is valid, `false` otherwise

# Example
```julia
using JSONSchema, StructUtils

@defaults struct User
    name::String = "" &(json=(minLength=1, maxLength=100),)
    age::Int = 0 &(json=(minimum=0, maximum=150),)
end

schema = JSONSchema.schema(User)
user1 = User("Alice", 25)
user2 = User("", 200)  # Invalid: empty name, age too high

isvalid(schema, user1)  # true
isvalid(schema, user2)  # false
isvalid(schema, user2; verbose=true)  # false, with error messages
```
"""
function Base.isvalid(schema::Schema{T}, instance::T; verbose::Bool = false) where {T}
    result = validate(schema, instance)
    is_valid = result === nothing

    if verbose && !is_valid
        for err in result.errors
            println("  x ", err)
        end
    end

    return is_valid
end

# Internal: Validate an instance against a schema
function _validate_instance(schema_obj, instance, ::Type{T}, path::String, errors::Vector{String}, verbose::Bool, root::Object{String, Any}) where {T}
    # Handle $ref - resolve and validate against resolved schema
    if haskey(schema_obj, "\$ref")
        ref_path = schema_obj["\$ref"]
        try
            resolved_schema = _resolve_ref(ref_path, root)
            return _validate_instance(resolved_schema, instance, T, path, errors, verbose, root)
        catch e
            push!(errors, "$path: error resolving \$ref: $(e.msg)")
            return
        end
    end

    # Handle structs
    if isstructtype(T) && isconcretetype(T) && haskey(schema_obj, "properties")
        properties = schema_obj["properties"]

        style = StructUtils.DefaultStyle()
        all_field_tags = StructUtils.fieldtags(style, T)

        for i in 1:fieldcount(T)
            fname = fieldname(T, i)
            ftype = fieldtype(T, i)
            fvalue = getfield(instance, fname)

            tags = _json_field_tags(all_field_tags, fname)

            # Skip ignored fields
            if _field_ignored(tags)
                continue
            end

            # Get JSON name (may be renamed)
            json_name = _json_field_name(fname, tags)

            # Check if field is in schema
            if haskey(properties, json_name)
                field_schema = properties[json_name]
                field_path = isempty(path) ? json_name : "$path.$json_name"
                # Use actual value type for validation, not field type (handles Union{T, Nothing} properly)
                val_type = fvalue === nothing || fvalue === missing ? ftype : typeof(fvalue)
                _validate_value(field_schema, fvalue, val_type, tags, field_path, errors, verbose, root)
            end
        end

        # Validate propertyNames - property names must match schema
        if haskey(schema_obj, "propertyNames")
            prop_names_schema = schema_obj["propertyNames"]
            for i in 1:fieldcount(T)
                fname = fieldname(T, i)
                tags = _json_field_tags(all_field_tags, fname)

                # Skip ignored fields
                if _field_ignored(tags)
                    continue
                end

                # Get JSON name
                json_name = _json_field_name(fname, tags)

                # Validate the property name itself as a string
                prop_errors = String[]
                _validate_value(prop_names_schema, json_name, String, nothing, path, prop_errors, false, root)
                if !isempty(prop_errors)
                    push!(errors, "$path: property name '$json_name' is invalid")
                end
            end
        end

        # Validate dependencies - if property X exists, properties Y and Z must exist
        if haskey(schema_obj, "dependencies")
            dependencies = schema_obj["dependencies"]
            for i in 1:fieldcount(T)
                fname = fieldname(T, i)
                fvalue = getfield(instance, fname)
                tags = _json_field_tags(all_field_tags, fname)

                # Skip ignored fields
                if _field_ignored(tags)
                    continue
                end

                # Skip fields with nothing/missing values (treat as "not present")
                if fvalue === nothing || fvalue === missing
                    continue
                end

                # Get JSON name
                json_name = _json_field_name(fname, tags)

                # If this property exists in dependencies
                if haskey(dependencies, json_name)
                    dep = dependencies[json_name]

                    # Dependencies can be an array of required properties
                    if dep isa Vector
                        for required_prop in dep
                            # Check if the required property exists in the struct and is not nothing/missing
                            found = false
                            for j in 1:fieldcount(T)
                                other_fname = fieldname(T, j)
                                other_fvalue = getfield(instance, j)
                                other_tags = _json_field_tags(all_field_tags, other_fname)

                                if _field_ignored(other_tags)
                                    continue
                                end

                                other_json_name = _json_field_name(other_fname, other_tags)

                                # Check if name matches and value is not nothing/missing
                                if other_json_name == required_prop && other_fvalue !== nothing && other_fvalue !== missing
                                    found = true
                                    break
                                end
                            end

                            if !found
                                push!(errors, "$path: property '$json_name' requires property '$required_prop' to exist")
                            end
                        end
                        # Dependencies can also be a schema (schema-based dependency)
                    elseif dep isa Object
                        # If the property exists, validate the whole instance against the dependency schema
                        _validate_value(dep, instance, T, nothing, path, errors, verbose, root)
                    end
                end
            end
        end

        # Validate additionalProperties for structs
        # Check if there are fields in the struct not defined in the schema
        if haskey(schema_obj, "additionalProperties")
            additional_allowed = schema_obj["additionalProperties"]

            # If additionalProperties is false, no extra properties allowed
            if additional_allowed === false
                for i in 1:fieldcount(T)
                    fname = fieldname(T, i)
                    tags = _json_field_tags(all_field_tags, fname)

                    # Skip ignored fields
                    if _field_ignored(tags)
                        continue
                    end

                    # Get JSON name
                    json_name = _json_field_name(fname, tags)

                    # Check if this property is defined in the schema
                    if !haskey(properties, json_name)
                        push!(errors, "$path: additional property '$json_name' not allowed")
                    end
                end
                # If additionalProperties is a schema, validate extra properties against it
            elseif additional_allowed isa Object
                for i in 1:fieldcount(T)
                    fname = fieldname(T, i)
                    ftype = fieldtype(T, i)
                    fvalue = getfield(instance, fname)
                    tags = _json_field_tags(all_field_tags, fname)

                    # Skip ignored fields
                    if _field_ignored(tags)
                        continue
                    end

                    # Get JSON name
                    json_name = _json_field_name(fname, tags)

                    # If this property is not in the schema, validate it against additionalProperties
                    if !haskey(properties, json_name)
                        field_path = isempty(path) ? json_name : "$path.$json_name"
                        val_type = fvalue === nothing || fvalue === missing ? ftype : typeof(fvalue)
                        _validate_value(additional_allowed, fvalue, val_type, tags, field_path, errors, verbose, root)
                    end
                end
            end
        end

        return
    end

    # For non-struct types, validate directly
    return _validate_value(schema_obj, instance, T, nothing, path, errors, verbose, root)
end

# Internal: Validate a single value against schema constraints
function _validate_value(schema, value, ::Type{T}, tags, path::String, errors::Vector{String}, verbose::Bool, root::Object{String, Any}) where {T}
    # Handle $ref - resolve and validate against resolved schema
    if haskey(schema, "\$ref")
        ref_path = schema["\$ref"]
        try
            resolved_schema = _resolve_ref(ref_path, root)
            # Recursively validate with resolved schema
            return _validate_value(resolved_schema, value, T, tags, path, errors, verbose, root)
        catch e
            push!(errors, "$path: error resolving \$ref: $(e.msg)")
            return
        end
    end

    # Handle Nothing/Missing
    if value === nothing || value === missing
        # Check if null is allowed
        schema_type = get(schema, "type", nothing)
        if schema_type isa Vector && !("null" in schema_type)
            push!(errors, "$path: null value not allowed")
        elseif schema_type isa String && schema_type != "null"
            push!(errors, "$path: null value not allowed")
        end
        return
    end

    # Validate type if specified in schema
    if haskey(schema, "type")
        _validate_type(schema["type"], value, path, errors)
    end

    # String validation
    if value isa AbstractString
        _validate_string(schema, tags, string(value), path, errors)
    end

    # Numeric validation
    if value isa Number
        _validate_number(schema, tags, value, path, errors)
    end

    # Array validation
    if value isa AbstractVector
        _validate_array(schema, tags, value, path, errors, verbose, root)
    end

    # Tuple validation (treat as array for JSON Schema purposes)
    if value isa Tuple
        _validate_array(schema, tags, collect(value), path, errors, verbose, root)
    end

    # Set validation
    if value isa AbstractSet
        _validate_array(schema, tags, collect(value), path, errors, verbose, root)
    end

    # Enum validation
    if haskey(schema, "enum")
        if !(value in schema["enum"])
            push!(errors, "$path: value must be one of $(schema["enum"]), got $(repr(value))")
        end
    end

    # Const validation
    if haskey(schema, "const")
        if value != schema["const"]
            push!(errors, "$path: value must be $(repr(schema["const"])), got $(repr(value))")
        end
    end

    # Nested object validation
    if haskey(schema, "properties") && isstructtype(T) && isconcretetype(T)
        _validate_instance(schema, value, T, path, errors, verbose, root)
    end

    # Dict/Object validation (properties, patternProperties, propertyNames for Dicts)
    if value isa AbstractDict
        # Validate properties for Dict
        if haskey(schema, "properties")
            properties = schema["properties"]
            required = get(() -> String[], schema, "required")

            # Validate each property
            for (prop_name, prop_schema) in properties
                if haskey(value, prop_name) || haskey(value, Symbol(prop_name))
                    prop_value = haskey(value, prop_name) ? value[prop_name] : value[Symbol(prop_name)]
                    val_path = isempty(path) ? string(prop_name) : "$path.$(prop_name)"
                    _validate_value(prop_schema, prop_value, typeof(prop_value), nothing, val_path, errors, verbose, root)
                elseif prop_name in required
                    push!(errors, "$path: required property '$prop_name' is missing")
                end
            end
        end

        # Validate propertyNames for Dict
        if haskey(schema, "propertyNames")
            prop_names_schema = schema["propertyNames"]
            for key in keys(value)
                key_str = string(key)
                prop_errors = String[]
                _validate_value(prop_names_schema, key_str, String, nothing, path, prop_errors, false, root)
                if !isempty(prop_errors)
                    push!(errors, "$path: property name '$key_str' is invalid")
                end
            end
        end

        # Validate patternProperties for Dict
        if haskey(schema, "patternProperties")
            pattern_props = schema["patternProperties"]
            for (pattern_str, prop_schema) in pattern_props
                pattern_regex = Regex(pattern_str)
                for (key, val) in value
                    key_str = string(key)
                    # If key matches the pattern, validate value against the schema
                    if occursin(pattern_regex, key_str)
                        val_path = isempty(path) ? key_str : "$path.$key_str"
                        _validate_value(prop_schema, val, typeof(val), nothing, val_path, errors, verbose, root)
                    end
                end
            end
        end

        # Validate dependencies for Dict
        if haskey(schema, "dependencies")
            dependencies = schema["dependencies"]
            for (prop_name, dep) in dependencies
                # If the property exists in the dict
                if haskey(value, prop_name) || haskey(value, Symbol(prop_name))
                    # Dependencies can be an array of required properties
                    if dep isa Vector
                        for required_prop in dep
                            if !haskey(value, required_prop) && !haskey(value, Symbol(required_prop))
                                push!(errors, "$path: property '$prop_name' requires property '$required_prop' to exist")
                            end
                        end
                        # Dependencies can also be a schema
                    elseif dep isa Object
                        _validate_value(dep, value, T, nothing, path, errors, verbose, root)
                    end
                end
            end
        end
    end

    # Composition validation
    return _validate_composition(schema, value, T, path, errors, verbose, root)
end

# Validate composition keywords (oneOf, anyOf, allOf)
function _validate_composition(schema, value, ::Type{T}, path::String, errors::Vector{String}, verbose::Bool, root::Object{String, Any}) where {T}
    # Use the actual value's type for validation
    actual_type = typeof(value)

    # oneOf: exactly one schema must validate
    if haskey(schema, "oneOf")
        schemas = schema["oneOf"]
        valid_count = 0

        for sub_schema in schemas
            sub_errors = String[]
            _validate_value(sub_schema, value, actual_type, nothing, path, sub_errors, false, root)
            if isempty(sub_errors)
                valid_count += 1
            end
        end

        if valid_count == 0
            push!(errors, "$path: value does not match any oneOf schemas")
        elseif valid_count > 1
            push!(errors, "$path: value matches multiple oneOf schemas (expected exactly one)")
        end
    end

    # anyOf: at least one schema must validate
    if haskey(schema, "anyOf")
        schemas = schema["anyOf"]
        any_valid = false

        for sub_schema in schemas
            sub_errors = String[]
            _validate_value(sub_schema, value, actual_type, nothing, path, sub_errors, false, root)
            if isempty(sub_errors)
                any_valid = true
                break
            end
        end

        if !any_valid
            push!(errors, "$path: value does not match any anyOf schemas")
        end
    end

    # allOf: all schemas must validate
    if haskey(schema, "allOf")
        schemas = schema["allOf"]

        for sub_schema in schemas
            _validate_value(sub_schema, value, actual_type, nothing, path, errors, verbose, root)
        end
    end

    # not: schema must NOT validate
    if haskey(schema, "not")
        not_schema = schema["not"]
        sub_errors = String[]
        _validate_value(not_schema, value, actual_type, nothing, path, sub_errors, false, root)

        # If validation succeeds (no errors), it means the value DOES match the not schema, which is invalid
        if isempty(sub_errors)
            push!(errors, "$path: value must NOT match the specified schema")
        end
    end

    # Conditional validation: if/then/else
    return if haskey(schema, "if")
        if_schema = schema["if"]
        sub_errors = String[]
        _validate_value(if_schema, value, actual_type, nothing, path, sub_errors, false, root)

        # If the "if" schema is valid, apply "then" schema (if present)
        if isempty(sub_errors)
            if haskey(schema, "then")
                then_schema = schema["then"]
                _validate_value(then_schema, value, actual_type, nothing, path, errors, verbose, root)
            end
            # If the "if" schema is invalid, apply "else" schema (if present)
        else
            if haskey(schema, "else")
                else_schema = schema["else"]
                _validate_value(else_schema, value, actual_type, nothing, path, errors, verbose, root)
            end
        end
    end
end

# String validation
function _validate_string(schema, tags, value::String, path::String, errors::Vector{String})
    # Check minLength
    min_len = get(schema, "minLength", nothing)
    if min_len !== nothing && length(value) < min_len
        push!(errors, "$path: string length $(length(value)) is less than minimum $min_len")
    end

    # Check maxLength
    max_len = get(schema, "maxLength", nothing)
    if max_len !== nothing && length(value) > max_len
        push!(errors, "$path: string length $(length(value)) exceeds maximum $max_len")
    end

    # Check pattern
    pattern = get(schema, "pattern", nothing)
    if pattern !== nothing
        try
            regex = Regex(pattern)
            if !occursin(regex, value)
                push!(errors, "$path: string does not match pattern $pattern")
            end
        catch e
            # Invalid regex pattern - skip validation
        end
    end

    # Format validation (basic checks)
    format = get(schema, "format", nothing)
    return if format !== nothing
        _validate_format(format, value, path, errors)
    end
end

# Format validation
function _validate_format(format::String, value::String, path::String, errors::Vector{String})
    return if format == "email"
        # RFC 5322 compatible regex (simplified but better than before)
        # Disallows spaces, requires @ and domain part
        if !occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", value)
            push!(errors, "$path: invalid email format")
        end
    elseif format == "uri" || format == "url"
        # URI validation: Scheme required, no whitespace
        # Matches "http://example.com", "ftp://file", "mailto:user@host", "urn:uuid:..."
        if !occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*:[^\s]*$", value)
            push!(errors, "$path: invalid URI format")
        end
    elseif format == "uuid"
        # UUID validation
        if !occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"i, value)
            push!(errors, "$path: invalid UUID format")
        end
    elseif format == "date-time"
        # ISO 8601 date-time check (requires timezone)
        # Matches: YYYY-MM-DDThh:mm:ss[.sss]Z or YYYY-MM-DDThh:mm:ss[.sss]+hh:mm
        if !occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[\+\-]\d{2}:?\d{2})$", value)
            push!(errors, "$path: invalid date-time format (expected ISO 8601 with timezone)")
        end
    end
    # Other formats could be added (ipv4, ipv6, etc.)
end

# Numeric validation
function _validate_number(schema, tags, value::Number, path::String, errors::Vector{String})
    # Check minimum
    min_val = get(schema, "minimum", nothing)
    exclusive_min = get(schema, "exclusiveMinimum", false)
    if min_val !== nothing
        if exclusive_min === true && value <= min_val
            push!(errors, "$path: value $value must be greater than $min_val")
        elseif exclusive_min === false && value < min_val
            push!(errors, "$path: value $value is less than minimum $min_val")
        end
    end

    # Check maximum
    max_val = get(schema, "maximum", nothing)
    exclusive_max = get(schema, "exclusiveMaximum", false)
    if max_val !== nothing
        if exclusive_max === true && value >= max_val
            push!(errors, "$path: value $value must be less than $max_val")
        elseif exclusive_max === false && value > max_val
            push!(errors, "$path: value $value exceeds maximum $max_val")
        end
    end

    # Check multipleOf
    multiple = get(schema, "multipleOf", nothing)
    return if multiple !== nothing
        # Check if value is a multiple of 'multiple'
        if !isapprox(mod(value, multiple), 0.0, atol = 1.0e-10) && !isapprox(mod(value, multiple), multiple, atol = 1.0e-10)
            push!(errors, "$path: value $value is not a multiple of $multiple")
        end
    end
end

# Array validation
function _validate_array(schema, tags, value::AbstractVector, path::String, errors::Vector{String}, verbose::Bool, root::Object{String, Any})
    # Check minItems
    min_items = get(schema, "minItems", nothing)
    if min_items !== nothing && length(value) < min_items
        push!(errors, "$path: array length $(length(value)) is less than minimum $min_items")
    end

    # Check maxItems
    max_items = get(schema, "maxItems", nothing)
    if max_items !== nothing && length(value) > max_items
        push!(errors, "$path: array length $(length(value)) exceeds maximum $max_items")
    end

    # Check uniqueItems
    unique_items = get(schema, "uniqueItems", false)
    if unique_items && length(value) != length(unique(value))
        push!(errors, "$path: array items must be unique")
    end

    # Check contains: at least one item must match the contains schema
    if haskey(schema, "contains")
        contains_schema = schema["contains"]
        any_match = false

        for item in value
            sub_errors = String[]
            item_type = typeof(item)
            _validate_value(contains_schema, item, item_type, nothing, path, sub_errors, false, root)
            if isempty(sub_errors)
                any_match = true
                break
            end
        end

        if !any_match
            push!(errors, "$path: array must contain at least one item matching the specified schema")
        end
    end

    # Validate each item if items schema is present
    return if haskey(schema, "items")
        items_schema = schema["items"]

        # Check if items is an array (tuple validation) or a single schema
        if items_schema isa AbstractVector
            # Tuple validation: each position has its own schema
            for (i, item) in enumerate(value)
                item_path = "$path[$(i - 1)]"  # 0-indexed for JSON
                item_type = typeof(item)

                # Use the corresponding schema if available
                if i <= length(items_schema)
                    _validate_value(items_schema[i], item, item_type, nothing, item_path, errors, verbose, root)
                    # For items beyond the tuple schemas, check additionalItems
                else
                    if haskey(schema, "additionalItems")
                        additional_items_schema = schema["additionalItems"]
                        # If additionalItems is false, extra items are not allowed
                        if additional_items_schema === false
                            push!(errors, "$path: additional items not allowed at index $(i - 1)")
                            # If additionalItems is a schema, validate against it
                        elseif additional_items_schema isa Object
                            _validate_value(additional_items_schema, item, item_type, nothing, item_path, errors, verbose, root)
                        end
                    end
                end
            end
        else
            # Single schema: applies to all items
            for (i, item) in enumerate(value)
                item_path = "$path[$(i - 1)]"  # 0-indexed for JSON
                item_type = typeof(item)
                _validate_value(items_schema, item, item_type, nothing, item_path, errors, verbose, root)
            end
        end
    end
end

# Validate JSON Schema type
function _validate_type(schema_type, value, path::String, errors::Vector{String})
    # Handle array of types (e.g., ["string", "null"])
    return if schema_type isa Vector
        type_matches = false
        for t in schema_type
            if _matches_type(t, value)
                type_matches = true
                break
            end
        end
        if !type_matches
            push!(errors, "$path: value type $(typeof(value)) does not match any of $schema_type")
        end
    elseif schema_type isa String
        if !_matches_type(schema_type, value)
            push!(errors, "$path: value type $(typeof(value)) does not match expected type $schema_type")
        end
    end
end

# Check if a value matches a JSON Schema type
function _matches_type(json_type::String, value)
    if json_type == "null"
        return value === nothing || value === missing
    elseif json_type == "boolean"
        return value isa Bool
    elseif json_type == "integer"
        # Explicitly exclude Bool since Bool <: Integer in Julia
        return value isa Integer && !(value isa Bool)
    elseif json_type == "number"
        # Explicitly exclude Bool since Bool <: Number in Julia
        return value isa Number && !(value isa Bool)
    elseif json_type == "string"
        return value isa AbstractString
    elseif json_type == "array"
        return value isa AbstractVector || value isa AbstractSet || value isa Tuple
    elseif json_type == "object"
        return value isa AbstractDict || (isstructtype(typeof(value)) && isconcretetype(typeof(value)))
    end
    return false
end
