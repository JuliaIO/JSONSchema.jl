# Copyright (c) 2018: fredo-dedup and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module JSONSchemaJSON3Ext

import JSONSchema
import JSON3

_to_base_julia(x) = x

_to_base_julia(x::JSON3.Array) = _to_base_julia.(x)

# This method unintentionally allows JSON3.Object{Symbol,Any} objects as both
# data and the schema because it converts to Dict{String,Any}. Because we don't
# similarly convert Base.Dict, Dict{Symbol,Any} results in errors. This can be
# confusing to users.
#
# We can't make this method more restrictive because that would break backwards
# compatibility. For more details, see:
# https://github.com/fredo-dedup/JSONSchema.jl/issues/62
function _to_base_julia(x::JSON3.Object)
    return Dict{String,Any}(string(k) => _to_base_julia(v) for (k, v) in x)
end

function JSONSchema.validate(
    schema::JSONSchema.Schema,
    x::Union{JSON3.Object,JSON3.Array},
)
    return JSONSchema.validate(schema, _to_base_julia(x))
end

function JSONSchema.Schema(schema::JSON3.Object; kwargs...)
    return JSONSchema.Schema(_to_base_julia(schema); kwargs...)
end

end
