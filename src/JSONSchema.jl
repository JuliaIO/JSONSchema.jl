# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

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
