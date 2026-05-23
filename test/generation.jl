# Copyright (c) 2018: fredo-dedup and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

@testset "Schema generation" begin
    @testset "Agentif-style tool parameters" begin
        T = @NamedTuple{
            path::String,
            recursive::Bool,
            limit::Union{Nothing,Int},
            tags::Vector{String},
            metadata::Dict{String,Any},
        }

        generated = JSONSchema.schema(
            T;
            all_fields_required = false,
            additionalProperties = false,
        )

        @test typeof(generated) == JSONSchema.Schema
        @test generated.spec === generated.data
        @test generated.spec["\$schema"] ==
              JSONSchema.DEFAULT_GENERATED_DRAFT
        @test generated.spec["type"] == "object"
        @test generated.spec["additionalProperties"] == false

        properties = generated.spec["properties"]
        @test properties["path"]["type"] == "string"
        @test properties["recursive"]["type"] == "boolean"
        @test properties["limit"]["type"] == Any["integer", "null"]
        @test properties["tags"]["type"] == "array"
        @test properties["tags"]["items"]["type"] == "string"
        @test properties["metadata"]["type"] == "object"
        @test properties["metadata"]["additionalProperties"] == Dict{String,Any}()

        @test Set(generated.spec["required"]) ==
              Set(["path", "recursive", "tags", "metadata"])
        @test isvalid(
            generated,
            Dict(
                "path" => "README.md",
                "recursive" => false,
                "tags" => ["docs"],
                "metadata" => Dict("source" => "agentif"),
            ),
        )
        @test isvalid(
            generated,
            Dict(
                "path" => "README.md",
                "recursive" => true,
                "limit" => nothing,
                "tags" => String[],
                "metadata" => Dict{String,Any}(),
            ),
        )
        @test !isvalid(
            generated,
            Dict(
                "path" => "README.md",
                "recursive" => false,
                "limit" => "ten",
                "tags" => ["docs"],
                "metadata" => Dict{String,Any}(),
            ),
        )
        @test !isvalid(
            generated,
            Dict(
                "path" => "README.md",
                "recursive" => false,
                "tags" => ["docs"],
                "metadata" => Dict{String,Any}(),
                "extra" => true,
            ),
        )
    end

    @testset "Provider required-field override" begin
        T = @NamedTuple{required::String, optional::Union{Nothing,String}}

        generated = JSONSchema.schema(
            T;
            all_fields_required = true,
            additionalProperties = false,
        )

        @test Set(generated.spec["required"]) == Set(["required", "optional"])

        non_nullable = String[]
        for (name, type) in zip(fieldnames(T), fieldtypes(T))
            if !(Nothing <: type)
                push!(non_nullable, string(name))
            end
        end
        generated.spec["required"] = non_nullable

        @test Set(generated.spec["required"]) == Set(["required"])
    end

    @testset "Union fields" begin
        T = @NamedTuple{
            only_null::Union{Nothing,Missing},
            scalar::Union{String,Int},
            nullable_scalar::Union{Nothing,String,Int},
        }
        generated = JSONSchema.schema(T)
        properties = generated.spec["properties"]

        @test properties["only_null"]["type"] == "null"
        @test Set(s["type"] for s in properties["scalar"]["anyOf"]) ==
              Set(["integer", "string"])
        @test Set(s["type"] for s in properties["nullable_scalar"]["anyOf"]) ==
              Set(["integer", "null", "string"])
    end

    @testset "Anthropic-style draft override" begin
        generated = JSONSchema.schema(
            @NamedTuple{x::String};
            draft = "https://json-schema.org/draft/2020-12/schema",
            refs = :defs,
        )

        @test generated.spec["\$schema"] ==
              "https://json-schema.org/draft/2020-12/schema"
        @test !haskey(generated.spec, "\$defs")
    end

    @testset "Google nullable serialization path" begin
        T = @NamedTuple{optional::Union{Nothing,String}}
        generated = JSONSchema.schema(
            T;
            additionalProperties = false,
        )
        parsed = JSON.parse(JSON.json(generated))
        optional = parsed["properties"]["optional"]

        @test optional["type"] == Any["string", "null"]
    end

    @testset "Generated Schema conveniences" begin
        generated = JSONSchema.schema(@NamedTuple{x::String})

        @test generated["type"] == "object"
        @test haskey(generated, "properties")
        @test get(generated, "missing", 42) == 42
        @test "required" in collect(keys(generated))
        @test JSON.lower(generated) === generated.data
        @test JSON.parse(JSON.json(generated))["type"] == "object"
    end

    @testset "Struct parameters" begin
        struct SearchOptions
            query::String
            max_results::Union{Nothing,Int}
        end

        generated = JSONSchema.schema(SearchOptions; additionalProperties = false)

        @test typeof(generated) == JSONSchema.Schema
        @test generated.spec["properties"]["query"]["type"] == "string"
        @test generated.spec["properties"]["max_results"]["type"] ==
              Any["integer", "null"]
        @test Set(generated.spec["required"]) == Set(["query"])
    end

    @testset "Nested additionalProperties" begin
        T = @NamedTuple{
            entries::Dict{String,@NamedTuple{enabled::Bool}},
        }

        generated = JSONSchema.schema(T; additionalProperties = false)
        entries = generated.spec["properties"]["entries"]
        entry = entries["additionalProperties"]

        @test generated.spec["additionalProperties"] == false
        @test entries["type"] == "object"
        @test entry["type"] == "object"
        @test entry["properties"]["enabled"]["type"] == "boolean"
        @test entry["additionalProperties"] == false
    end

    @testset "Tuple parameters" begin
        repeated = JSONSchema.schema(Tuple{Vararg{String}})
        prefixed = JSONSchema.schema(Tuple{String,Vararg{Int}})
        fixed = JSONSchema.schema(Tuple{String,Int})
        unbounded = JSONSchema.schema(Tuple)

        @test repeated.spec["type"] == "array"
        @test repeated.spec["items"]["type"] == "string"
        @test prefixed.spec["items"][1]["type"] == "string"
        @test prefixed.spec["additionalItems"]["type"] == "integer"
        @test fixed.spec["items"][1]["type"] == "string"
        @test fixed.spec["items"][2]["type"] == "integer"
        @test fixed.spec["additionalItems"] == false
        @test unbounded.spec["items"] == Dict{String,Any}()
    end

    @testset "Tuple parameters in draft 2020-12" begin
        draft = "https://json-schema.org/draft/2020-12/schema"
        fixed = JSONSchema.schema(Tuple{String,Int}; draft)
        prefixed = JSONSchema.schema(Tuple{String,Vararg{Int}}; draft)
        nested = JSONSchema.schema(@NamedTuple{coords::Tuple{String,Int}}; draft)

        @test fixed.spec["\$schema"] == draft
        @test fixed.spec["prefixItems"][1]["type"] == "string"
        @test fixed.spec["prefixItems"][2]["type"] == "integer"
        @test !haskey(fixed.spec, "additionalItems")
        @test !haskey(fixed.spec, "items")

        @test prefixed.spec["prefixItems"][1]["type"] == "string"
        @test prefixed.spec["items"]["type"] == "integer"
        @test !haskey(prefixed.spec, "additionalItems")

        coords = nested.spec["properties"]["coords"]
        @test coords["prefixItems"][1]["type"] == "string"
        @test coords["prefixItems"][2]["type"] == "integer"
    end
end
