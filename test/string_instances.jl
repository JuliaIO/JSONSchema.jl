@testset "AbstractString instances" begin
    for wrap in (identity, s -> SubString(s), s -> LazyString("", s))
        text = wrap("αβ")
        @test isvalid(JSONSchema.schema(typeof(text)), text)
        @test isvalid(JSONSchema.Schema(Dict("type" => "string")), text)
        nullable = JSONSchema.Schema(Dict("type" => ["string", "null"]))
        @test isvalid(nullable, text)
        @test isvalid(nullable, nothing)

        for (keyword, limit, value, expected) in (
            ("maxLength", 2, "αβ", true),
            ("maxLength", 1, "αβ", false),
            ("maxLength", 0, "", true),
            ("minLength", 1, "", false),
            ("minLength", 2, "αβ", true),
            ("minLength", 3, "αβ", false),
            ("maxLength", 1, "e\u0301", false),
        )
            schema = JSONSchema.Schema(Dict(keyword => limit))
            @test isvalid(schema, wrap(value)) == expected
        end
        for (pattern, value, expected) in (
            (raw"^αβ$", "αβ", true),
            ("^β", "αβ", false),
            ("β", "αβ", true),
            ("", "", true),
        )
            schema = JSONSchema.Schema(Dict("pattern" => pattern))
            @test isvalid(schema, wrap(value)) == expected
        end

        for (rule, bad, reason) in (
            (Dict("maxLength" => 1), "αβ", "maxLength"),
            (Dict("minLength" => 3), "αβ", "minLength"),
            (Dict("pattern" => "^z"), "αβ", "pattern"),
        )
            schema = JSONSchema.Schema(
                Dict("properties" => Dict("names" => Dict("items" => rule))),
            )
            issue = JSONSchema.validate(schema, Dict("names" => [wrap(bad)]))
            @test issue isa JSONSchema.SingleIssue &&
                  issue.reason == reason &&
                  JSONSchema.json_pointer(issue) == "#/names/0"
        end
        typed = JSONSchema.Schema(Dict("type" => "string", "minLength" => 2))
        @test isvalid(typed, text)
        @test !isvalid(typed, wrap("α"))
    end

    for data in (1, true, nothing, ["αβ"])
        @test !isvalid(JSONSchema.Schema(Dict("type" => "string")), data)
        @test isvalid(
            JSONSchema.Schema(Dict("minLength" => 5, "pattern" => "^z")),
            data,
        )
    end
end
