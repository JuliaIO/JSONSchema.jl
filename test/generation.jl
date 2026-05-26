# Copyright (c) 2026: fredo-dedup, quinnj, and contributors
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
        data = JSONSchema.spec(generated)
        @test data === generated.data
        @test data["\$schema"] == JSONSchema.DEFAULT_GENERATED_DRAFT
        @test data["type"] == "object"
        @test data["additionalProperties"] == false

        properties = data["properties"]
        @test properties["path"]["type"] == "string"
        @test properties["recursive"]["type"] == "boolean"
        @test properties["limit"]["type"] == Any["integer", "null"]
        @test properties["tags"]["type"] == "array"
        @test properties["tags"]["items"]["type"] == "string"
        @test properties["metadata"]["type"] == "object"
        @test properties["metadata"]["additionalProperties"] ==
              Dict{String,Any}()

        @test Set(data["required"]) ==
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

        data = JSONSchema.spec(generated)
        @test Set(data["required"]) == Set(["required", "optional"])

        non_nullable = String[]
        for (name, type) in zip(fieldnames(T), fieldtypes(T))
            if !(Nothing <: type)
                push!(non_nullable, string(name))
            end
        end
        data["required"] = non_nullable

        @test Set(data["required"]) == Set(["required"])
    end

    @testset "Union fields" begin
        T = @NamedTuple{
            only_null::Union{Nothing,Missing},
            scalar::Union{String,Int},
            nullable_scalar::Union{Nothing,String,Int},
        }
        generated = JSONSchema.schema(T)
        properties = JSONSchema.spec(generated)["properties"]

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

        @test JSONSchema.spec(generated)["\$schema"] ==
              "https://json-schema.org/draft/2020-12/schema"
        @test !haskey(JSONSchema.spec(generated), "\$defs")
    end

    @testset "Google nullable serialization path" begin
        T = @NamedTuple{optional::Union{Nothing,String}}
        generated = JSONSchema.schema(T; additionalProperties = false)
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
        @test JSONSchema.spec(generated) === generated.data
        @test JSON.lower(generated) === JSONSchema.spec(generated)
        @test JSON.parse(JSON.json(generated))["type"] == "object"
    end

    @testset "Struct parameters" begin
        struct SearchOptions
            query::String
            max_results::Union{Nothing,Int}
        end

        generated =
            JSONSchema.schema(SearchOptions; additionalProperties = false)

        @test typeof(generated) == JSONSchema.Schema
        data = JSONSchema.spec(generated)
        @test data["properties"]["query"]["type"] == "string"
        @test data["properties"]["max_results"]["type"] ==
              Any["integer", "null"]
        @test Set(data["required"]) == Set(["query"])
    end

    @testset "Nested additionalProperties" begin
        T = @NamedTuple{entries::Dict{String,@NamedTuple{enabled::Bool}}}

        generated = JSONSchema.schema(T; additionalProperties = false)
        data = JSONSchema.spec(generated)
        entries = data["properties"]["entries"]
        entry = entries["additionalProperties"]

        @test data["additionalProperties"] == false
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

        repeated_data = JSONSchema.spec(repeated)
        prefixed_data = JSONSchema.spec(prefixed)
        fixed_data = JSONSchema.spec(fixed)
        unbounded_data = JSONSchema.spec(unbounded)

        @test repeated_data["type"] == "array"
        @test repeated_data["items"]["type"] == "string"
        @test prefixed_data["items"][1]["type"] == "string"
        @test prefixed_data["additionalItems"]["type"] == "integer"
        @test fixed_data["items"][1]["type"] == "string"
        @test fixed_data["items"][2]["type"] == "integer"
        @test fixed_data["additionalItems"] == false
        @test unbounded_data["items"] == Dict{String,Any}()
    end

    @testset "Tuple parameters in draft 2020-12" begin
        draft = "https://json-schema.org/draft/2020-12/schema"
        fixed = JSONSchema.schema(Tuple{String,Int}; draft)
        prefixed = JSONSchema.schema(Tuple{String,Vararg{Int}}; draft)
        nested =
            JSONSchema.schema(@NamedTuple{coords::Tuple{String,Int}}; draft)

        fixed_data = JSONSchema.spec(fixed)
        prefixed_data = JSONSchema.spec(prefixed)
        nested_data = JSONSchema.spec(nested)

        @test fixed_data["\$schema"] == draft
        @test fixed_data["prefixItems"][1]["type"] == "string"
        @test fixed_data["prefixItems"][2]["type"] == "integer"
        @test !haskey(fixed_data, "additionalItems")
        @test !haskey(fixed_data, "items")

        @test prefixed_data["prefixItems"][1]["type"] == "string"
        @test prefixed_data["items"]["type"] == "integer"
        @test !haskey(prefixed_data, "additionalItems")

        coords = nested_data["properties"]["coords"]
        @test coords["prefixItems"][1]["type"] == "string"
        @test coords["prefixItems"][2]["type"] == "integer"
    end
end
