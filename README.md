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
for draft v4 and v6.

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
