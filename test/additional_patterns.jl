@testset "Additional properties with pattern coverage" begin
    properties = Dict("literal" => Dict("type" => "integer"))
    patterns = Dict(
        "^covered_" => Dict("type" => "string"),
        "middle" => Dict("type" => "boolean"),
        "^π" => true,
    )
    for extra in (false, true, Dict("type" => "integer"))
        schema = JSONSchema.Schema(
            Dict(
                "properties" => properties,
                "patternProperties" => patterns,
                "additionalProperties" => extra,
            ),
        )
        for data in (
            Dict{String,Any}(),
            Dict("literal" => 2),
            Dict("covered_name" => "ok"),
            Dict("xmiddley" => true),
            Dict("πname" => nothing),
            Dict{String,Any}(
                "literal" => 2,
                "covered_name" => "ok",
                "xmiddley" => true,
            ),
        )
            @test JSONSchema.validate(schema, data) === nothing
        end
        @test JSONSchema.validate(schema, Dict("covered_middle" => "ok")) isa
              JSONSchema.SingleIssue
        @test JSONSchema.validate(schema, Dict("literal" => false)) isa
              JSONSchema.SingleIssue
        @test isvalid(schema, Dict("unknown" => 2)) == (extra !== false)
        @test isvalid(schema, Dict("unknown" => false)) == (extra === true)
        if extra isa AbstractDict
            issue = JSONSchema.validate(schema, Dict("unknown" => false))
            @test issue.reason == "type"
            @test issue.path == "[unknown]"
            @test JSONSchema.json_pointer(issue) == "#/unknown"
        elseif extra === false
            issue = JSONSchema.validate(schema, Dict("unknown" => 2))
            @test issue.reason == "additionalProperties"
            @test JSONSchema.json_pointer(issue) == "#"
        end
    end

    schema = JSONSchema.Schema(
        Dict(
            "items" => Dict(
                "patternProperties" => Dict("^covered_" => true),
                "additionalProperties" => Dict("type" => "integer"),
            ),
        ),
    )
    @test isvalid(schema, [Dict("covered_name" => nothing), Dict("other" => 3)])
    issue = JSONSchema.validate(
        schema,
        [Dict("covered_name" => nothing), Dict("other" => "bad")],
    )
    @test issue.reason == "type"
    @test JSONSchema.json_pointer(issue) == "#/1/other"

    data = Dict{String,Any}("bucket_$(mod1(i, 5))_$i" => i for i in 1:2500)
    for extra in (false, Dict("type" => "integer"))
        schema = JSONSchema.Schema(
            Dict(
                "patternProperties" =>
                    Dict("^bucket_$(i)_" => true for i in 1:5),
                "additionalProperties" => extra,
            ),
        )
        for _ in 1:3
            @test JSONSchema.validate(schema, data) === nothing
        end
        @test (@allocated JSONSchema.validate(schema, data)) < 800_000
    end
end
