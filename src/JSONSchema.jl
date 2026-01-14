module JSONSchema

import Downloads
import JSON
import StructUtils
import URIs
using JSON: JSONWriteStyle, Object

export Schema, SchemaContext, ValidationResult, schema, validate
# Backwards compatibility exports (v1.5.0)
export diagnose, SingleIssue

include("schema.jl")
include("compat.jl")

end
