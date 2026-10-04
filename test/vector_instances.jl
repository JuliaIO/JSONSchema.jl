struct _OffsetVector{T} <: AbstractVector{T}
    values::Vector{T}
end
Base.size(x::_OffsetVector) = size(x.values)
Base.axes(x::_OffsetVector) = (0:(length(x.values)-1),)
Base.getindex(x::_OffsetVector, i::Int) = x.values[i+1]
Base.iterate(x::_OffsetVector, state...) = iterate(x.values, state...)

@testset "AbstractVector array instances" begin
    array = JSONSchema.Schema(Dict("type" => "array"))
    nullable = JSONSchema.Schema(Dict("type" => ["array", "null"]))
    vectors = ([1, 2, 3], view([0, 1, 2, 3, 0], 2:4), 1:3)
    for data in (vectors..., BitVector([true, false]))
        @test isvalid(array, data)
        @test isvalid(nullable, data)
        @test isvalid(JSONSchema.schema(typeof(data)), data)
    end
    @test isvalid(nullable, nothing)

    for data in vectors
        for (keyword, constraint, expected) in (
            ("minItems", 3, true),
            ("minItems", 4, false),
            ("maxItems", 3, true),
            ("maxItems", 2, false),
            ("uniqueItems", true, true),
            ("contains", Dict("const" => 2), true),
            ("contains", Dict("const" => 4), false),
            ("items", Dict("type" => "integer"), true),
            ("items", false, false),
        )
            schema = JSONSchema.Schema(
                Dict("type" => "array", keyword => constraint),
            )
            @test isvalid(schema, data) == expected
        end
        object = JSONSchema.Schema(
            Dict(
                "properties" => Dict(
                    "values" => Dict(
                        "type" => "array",
                        "items" => Dict("type" => "integer"),
                    ),
                ),
            ),
        )
        @test isvalid(object, Dict("values" => data))
    end

    integers = JSONSchema.Schema(
        Dict("type" => "array", "items" => Dict("type" => "integer")),
    )
    for data in ([1.0, 1.5, 2.0], view([1.0, 1.5, 2.0], 1:3), 1.0:0.5:2.0)
        issue = JSONSchema.validate(integers, data)
        @test issue isa JSONSchema.SingleIssue &&
              issue.reason == "type" &&
              JSONSchema.json_pointer(issue) == "#/1"
    end
    empty = JSONSchema.Schema(Dict("type" => "array", "maxItems" => 0))
    for data in (Int[], view(Int[], 1:0), 1:0)
        @test isvalid(empty, data)
    end
    booleans = JSONSchema.Schema(
        Dict("type" => "array", "items" => Dict("type" => "boolean")),
    )
    @test isvalid(booleans, BitVector([true, false]))
    @test !isvalid(
        JSONSchema.Schema(Dict("type" => "array", "uniqueItems" => true)),
        BitVector([true, false, true]),
    )

    for data in (1, true, "array", nothing, Dict(), (1, 2))
        @test !isvalid(array, data)
    end
    @test isvalid(array, [1 2; 3 4])
end

@testset "Offset vector additional items use JSON positions" begin
    integer = Dict("type" => "integer")
    raw = Dict{String,Any}("items" => [integer], "additionalItems" => integer)
    for schema in (
        JSONSchema.Schema(raw),
        JSONSchema.Schema(merge(raw, Dict("type" => "array"))),
    )
        @test isvalid(schema, _OffsetVector([1, 2, 3]))
        @test isvalid(schema, _OffsetVector(Int[]))
        issue = JSONSchema.validate(schema, _OffsetVector([1.0, 2.5, 3.0]))
        @test issue isa JSONSchema.SingleIssue
        @test issue.x == 2.5
        @test issue.path == "[2]"
        @test JSONSchema.json_pointer(issue) == "#/1"
        issue = JSONSchema.validate(schema, _OffsetVector([1.5, 2.0]))
        @test JSONSchema.json_pointer(issue) == "#/0"
    end
    @test isvalid(
        JSONSchema.schema(_OffsetVector{Int}),
        _OffsetVector([1, 2, 3]),
    )
end
