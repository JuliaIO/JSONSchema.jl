module JSONSchema

import Downloads
import JSON
import StructUtils
import URIs
using JSON: JSONWriteStyle, Object

export Schema, SchemaContext, ValidationResult, schema, validate

include("schema.jl")

end
