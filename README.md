# JSONSchema.jl

[![CI](https://github.com/JuliaIO/JSONSchema.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/JuliaIO/JSONSchema.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/JuliaIO/JSONSchema.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaIO/JSONSchema.jl)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliaio.github.io/JSONSchema.jl/stable)

## Overview

JSONSchema.jl generates JSON Schema (draft-07) from Julia types and validates
instances against those schemas. It also supports validating data against
hand-written JSON Schema objects. Field-level validation rules are provided via
`StructUtils` tags.

> **Upgrading from v1.x?** See the [v2.0 Migration Guide](https://juliaio.github.io/JSONSchema.jl/stable/migration/) for breaking changes and upgrade instructions.

The test harness is wired to the
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for draft4, draft6, and draft7.

## Installation

```julia
using Pkg
Pkg.add("JSONSchema")
```

## Usage

### Generate a schema from a Julia type

```julia
using JSONSchema, StructUtils

@defaults struct User
    id::Int = 0 &(json=(minimum=1,),)
    name::String = "" &(json=(minLength=1,),)
    email::String = "" &(json=(format="email",),)
end

schema = JSONSchema.schema(User)
user = User(1, "Alice", "alice@example.com")

isvalid(schema, user)  # true
```

### Validate JSON data against a schema object

```julia
using JSON, JSONSchema

schema = JSONSchema.Schema(JSON.parse("""
{
  "type": "object",
  "properties": {"foo": {"type": "integer"}},
  "required": ["foo"]
}
"""))

data = JSON.parse("""{"foo": 1}""")
isvalid(schema, data)  # true
```

## Features

- **Schema Generation**: Automatically generate JSON Schema from Julia struct definitions
- **Type-Safe Validation**: Validate Julia instances against generated schemas
- **StructUtils Integration**: Use field tags for validation rules (min/max, patterns, formats, etc.)
- **Composition Support**: `oneOf`, `anyOf`, `allOf`, `not` combinators
- **Reference Support**: `$ref` with `definitions` for complex/recursive types
- **Format Validation**: Built-in validators for `email`, `uri`, `uuid`, `date-time`

## Documentation

See the [documentation](https://juliaio.github.io/JSONSchema.jl/stable) for:
- Complete API reference
- Validation rules and field tags
- Type mapping reference
- Advanced usage with `$ref` and composition
