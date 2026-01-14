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

deploydocs(repo = "github.com/JuliaServices/JSONSchema.jl.git", push_preview = true)
