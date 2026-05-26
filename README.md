# JSONSchema.jl

[![Build Status](https://github.com/fredo-dedup/JSONSchema.jl/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/fredo-dedup/JSONSchema.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/fredo-dedup/JSONSchema.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/fredo-dedup/JSONSchema.jl)

## Overview

[JSONSchema.jl](https://github.com/fredo-dedup/JSONSchema.jl) is a JSON
validation package for the [Julia](https://julialang.org/) programming language.
Given a [validation schema](http://json-schema.org/specification.html), this
package can verify if a JSON instance meets all the assertions that define a
valid document.

This package has been tested with the
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for draft v4, v6, and v7.

## API

Create a `Schema` object by passing a string:
```julia
julia> my_schema = Schema("""{
            "properties": {
                "foo": {},
                "bar": {}
            },
            "required": ["foo"]
        }""")
```
passing a dictionary with the same structure as a schema:
```julia
julia> my_schema = Schema(
            Dict(
                "properties" => Dict(
                    "foo" => Dict(),
                    "bar" => Dict()
                ),
                "required" => ["foo"]
            )
        )
```
or by passing a parsed JSON file containing the schema:
```julia
julia> my_schema = Schema(JSON.parsefile(filename))
```

Check the validity of a parsed JSON instance by calling `validate` with the JSON
instance `x` to be tested and the `schema`.

If the validation succeeds, `validate` returns `nothing`:
```julia
julia> document = """{"foo": true}""";

julia> data_pass = JSON.parse(document)
Dict{String,Bool} with 1 entry:
  "foo" => true

julia> validate(my_schema, data_pass)

```

If the validation fails, a struct is returned that, when printed, explains the
reason for the failure:
```julia
julia> data_fail = Dict("bar" => 12.5)
Dict{String,Float64} with 1 entry:
  "bar" => 12.5

julia> validate(my_schema, data_fail)
Validation failed:
path:         top-level
instance:     Dict("bar"=>12.5)
schema key:   required
schema value: ["foo"]
```

As a short-hand for `validate(schema, x) === nothing`, use
`Base.isvalid(schema, x)`

Note that if `x` is a `String` in JSON format, you must use `JSON.parse(x)`
before passing to `validate`, that is, JSONSchema operates on the parsed
representation, not on the underlying `String` representation of the JSON data.

Generate a `Schema` object from a Julia type by calling `JSONSchema.schema`:
```julia
julia> params = JSONSchema.schema(
           @NamedTuple{query::String, limit::Union{Nothing,Int}};
           additionalProperties = false,
       )
A JSONSchema

julia> JSONSchema.spec(params)["required"]
1-element Vector{String}:
 "query"
```

`JSONSchema.schema` is intentionally not exported, to avoid clashing with common
names in user code. The initial generator is intended for simple typed API
parameters. It supports `NamedTuple`s, concrete structs, JSON scalar types,
vectors, dictionaries, tuples, and nullable unions such as
`Union{Nothing,String}`.

The generator emits an inline subset of JSON Schema that is valid for draft v7
by default: `type`, `properties`, `required`, `additionalProperties`, `items`,
`additionalItems`, `anyOf`, and nullable primitive type arrays. Passing `draft`
sets the generated `"$schema"` URI; draft 2019-09 and 2020-12 also use
`prefixItems` for tuple schemas. The generator does not infer validation
constraints such as string patterns, numeric ranges, formats, enums, recursive
references, or schema definitions.

Generated schemas are returned as ordinary `Schema` objects; the underlying
dictionary is available as `.data` or through `JSONSchema.spec(params)`, and
`JSON.json(params)` serializes the generated schema.
