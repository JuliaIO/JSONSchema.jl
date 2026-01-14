# v2.0 Migration Guide

This guide helps you upgrade from JSONSchema.jl v1.x to v2.0. The v2.0 release is a
complete rewrite that changes the package from a pure validation library to a
schema generation and validation library.

## Overview of Changes

JSONSchema.jl v2.0 introduces:
- **Schema generation** from Julia types via `schema(T)`
- **Type-safe validation** with `Schema{T}`
- **StructUtils integration** for field-level validation rules
- **`$ref` support** for schema deduplication

Most v1.x code will continue to work with minimal changes thanks to our
backwards compatibility layer.

## Breaking Changes

### 1. `parent_dir` Keyword Argument Removed

The `Schema` constructor no longer accepts a `parent_dir` keyword argument for
resolving local file `$ref` references.

**v1.x:**
```julia
schema = Schema(spec; parent_dir="./schemas")
```

**v2.0:** Local file reference resolution is not currently supported. External
`$ref` references should be resolved before creating the schema, or use the new
`refs` keyword argument with `schema()` for type-based deduplication.

### 2. `SingleIssue` Type Replaced by `ValidationResult`

The `SingleIssue` type from v1.x has been removed and replaced by
`ValidationResult`.

**v1.x:**
```julia
result = validate(schema, data)
if result isa SingleIssue
    println(result.x)       # The invalid value
    println(result.path)    # JSON path to the error
end
```

**v2.0:**
```julia
result = validate(schema, data)
if result !== nothing
    for err in result.errors
        println(err)  # Error message with path
    end
end
```

### 3. `diagnose` Function

The previously deprecated `diagnose` function has been removed. Use
`validate(schema, data)` instead.

### 4. Inverse Argument Order

The `validate` and `isvalid` functions where `schema` is the second argument
have been removed. `schema` must be the first argument.
```julia
validate(data, schema)  # old
validate(schema, data)  # new

isvalid(data, schema)  # old
isvalid(schema, data)  # new
```

### 5. `required` Without `properties`

v1.x supported non-standard schemas with `required` field and no `properties`.
In v2.0, you must specify `properties` if `required` is present.
```julia
schema = Schema(Dict("type" => "object", "required" => ["foo"]))  # Not allowed
```

## API Compatibility

The following v1.x patterns are fully supported in v2.0:

### `validate()` Return Type (Unchanged)

The `validate` function returns `nothing` on success and a `ValidationResult`
on failure, matching v1.x behavior:

```julia
result = validate(schema, data)
if result === nothing
    println("Valid!")
else
    for err in result.errors
        println(err)
    end
end
```

### `isvalid()` Function

The `isvalid` function extends `Base.isvalid` and returns a boolean:

```julia
using JSONSchema

isvalid(schema, data)  # Returns true or false
```

### Boolean Schemas

```julia
Schema(true)   # Accepts everything
Schema(false)  # Rejects everything
```

## New Features in v2.0

### Schema Generation from Types

Generate JSON Schema directly from Julia struct definitions:

```julia
using JSONSchema, StructUtils

@defaults struct User
    id::Int = 0 &(json=(minimum=1,),)
    name::String = "" &(json=(minLength=1, maxLength=100),)
    email::String = "" &(json=(format="email",),)
    age::Union{Int, Nothing} = nothing &(json=(minimum=0, maximum=150),)
end

schema = JSONSchema.schema(User)
```

### Type-Safe Validation

Schemas are now parameterized by the type they describe:

```julia
schema = JSONSchema.schema(User)  # Returns Schema{User}
user = User(1, "Alice", "alice@example.com", 30)
isvalid(schema, user)  # Type-safe validation
```

### `$ref` Support for Deduplication

Use `refs=true` to generate schemas with `$ref` for nested types:

```julia
@defaults struct Address
    street::String = ""
    city::String = ""
end

@defaults struct Person
    name::String = ""
    address::Address = Address()
end

schema = JSONSchema.schema(Person, refs=true)
# Generates schema with `$ref` to #/definitions/Address
```

### ValidationResult with Error Details

Get detailed validation errors:

```julia
result = JSONSchema.validate(schema, invalid_data)
if result !== nothing
    for error in result.errors
        println(error)  # e.g., "name: string length 0 is less than minimum 1"
    end
end
```

## Quick Migration Checklist

- [ ] Remove `parent_dir` keyword from `Schema()` calls
- [ ] Update error handling to use `ValidationResult.errors` instead of `SingleIssue` fields
- [ ] Consider using `schema(T)` for type-based schema generation

## Getting Help

If you encounter issues migrating, please [open an issue](https://github.com/JuliaIO/JSONSchema.jl/issues)
with details about your use case.
