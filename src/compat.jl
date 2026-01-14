# Backwards compatibility layer for JSONSchema v1.5.0 API
# This file provides compatibility shims for code written against the v1.5.0 API

# ============= 1. Support schema.data field access (v1.5.0 pattern) =============
# v1.5.0 used schema.data to access the spec, new API uses schema.spec
function Base.getproperty(s::Schema, name::Symbol)
    if name === :data
        return getfield(s, :spec)  # Map .data -> .spec
    else
        return getfield(s, name)
    end
end

# ============= 2. Support inverse argument order =============
# v1.5.0 supported both validate(schema, x) and validate(x, schema)
# NOTE: This is now handled directly in schema.jl via the generic fallback methods
# that check if the second argument is a Schema and swap arguments accordingly.

# ============= 3. Support boolean schemas =============
# v1.5.0 supported Schema(true) and Schema(false)
# true = accept everything, false = reject everything
function Schema(b::Bool)
    if b
        # true schema accepts everything - empty schema
        return Schema{Any}(Any, Object{String, Any}(), nothing)
    else
        # false schema rejects everything - use "not: {}" pattern
        return Schema{Any}(Any, Object{String, Any}("not" => Object{String, Any}()), nothing)
    end
end

# ============= 4. Fix required validation for Dicts without properties =============
# v1.5.0 validated "required" even when "properties" was not defined
# This is handled by adding a check in _validate_value for AbstractDict
# See _validate_required_for_dict below, called from _validate_value

"""
    _validate_required_for_dict(schema, value::AbstractDict, path, errors)

Validate required fields for Dict values, even when properties is not defined.
This restores v1.5.0 behavior where required was checked independently.
"""
function _validate_required_for_dict(schema, value::AbstractDict, path::String, errors::Vector{String})
    if !haskey(schema, "required")
        return
    end

    required = schema["required"]
    if !(required isa AbstractVector)
        return
    end

    for req_prop in required
        req_str = string(req_prop)
        if !haskey(value, req_str) && !haskey(value, Symbol(req_str))
            push!(errors, "$path: required property '$req_str' is missing")
        end
    end
end

# ============= 5. Provide deprecated diagnose function =============
# diagnose was deprecated in v1.5.0 but still present
"""
    diagnose(x, schema)

!!! warning "Deprecated"
    `diagnose(x, schema)` is deprecated. Use `validate(schema, x)` instead.

Validate `x` against `schema` and return a string description of the first error,
or `nothing` if valid.
"""
function diagnose(x, schema)
    Base.depwarn(
        "`diagnose(x, schema)` is deprecated. Use `validate(schema, x)` instead.",
        :diagnose,
    )
    result = validate(schema, x)
    if !result.is_valid && !isempty(result.errors)
        return join(result.errors, "\n")
    end
    return nothing
end

# ============= Type alias for SingleIssue =============
# v1.5.0 had SingleIssue type for validation errors
# Provide an alias so code checking `result isa SingleIssue` doesn't error
const SingleIssue = ValidationResult
