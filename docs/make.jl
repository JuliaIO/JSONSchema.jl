# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

using Documenter, JSONSchema

makedocs(
    modules = [JSONSchema],
    sitename = "JSONSchema.jl",
    pages = [
        "Home" => "index.md",
        "JSON Schema" => "schema.md",
        "API Reference" => "reference.md",
        "v2.0 Migration Guide" => "migration.md",
    ],
)

deploydocs(repo = "github.com/JuliaIO/JSONSchema.jl.git", push_preview = true)
