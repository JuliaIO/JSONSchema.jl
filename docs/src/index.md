# JSONSchema.jl

JSONSchema.jl generates JSON Schema (draft-07) from Julia types and validates
instances against those schemas. It also supports validating data against
hand-written JSON Schema objects.

## Installation

```julia
using Pkg
Pkg.add("JSONSchema")
```

## Quick Start

```julia
using JSONSchema
using StructUtils

@defaults struct User
    id::Int = 0
    name::String = "" &(json=(minLength=1,),)
    email::String = "" &(json=(format="email",),)
    age::Union{Int, Nothing} = nothing
end

schema = JSONSchema.schema(User)
user = User(1, "Alice", "alice@example.com", 30)
result = JSONSchema.validate(schema, user)

result.is_valid
```
