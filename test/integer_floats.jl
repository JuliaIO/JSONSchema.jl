@testset "Integer-valued floating-point instances" begin
    integer = JSONSchema.Schema(Dict("type" => "integer"))
    nullable = JSONSchema.Schema(Dict("type" => ["integer", "null"]))
    number = JSONSchema.Schema(Dict("type" => "number"))
    object = JSONSchema.Schema(
        Dict("properties" => Dict("count" => Dict("type" => "integer"))),
    )
    array = JSONSchema.Schema(Dict("items" => Dict("type" => "integer")))

    for T in (Float16, Float32, Float64, BigFloat)
        for value in (zero(T), -zero(T), T(7), T(-2))
            @test isvalid(integer, value)
            @test isvalid(nullable, value)
        end
        for value in (T(0.5), T(-2.5), T(NaN), T(Inf), T(-Inf))
            @test !isvalid(integer, value)
            @test !isvalid(nullable, value)
        end
        @test isvalid(number, T(0.5))
        @test isvalid(object, Dict("count" => T(2)))
        issue = JSONSchema.validate(object, Dict("count" => T(0.5)))
        @test issue.reason == "type"
        @test JSONSchema.json_pointer(issue) == "#/count"
        @test isvalid(array, T[1, 2])
        issue = JSONSchema.validate(array, T[1, 1.5])
        @test issue.reason == "type"
        @test JSONSchema.json_pointer(issue) == "#/1"
    end

    @test isvalid(integer, BigFloat(big(2)^200))
    @test isvalid(integer, big(2)^200)
    @test isvalid(integer, 7)
    @test isvalid(nullable, nothing)
    @test isvalid(nullable, missing)
    for value in (true, false, "7", nothing)
        @test !isvalid(integer, value)
    end
    for value in (true, false)
        @test !isvalid(number, value)
    end
end
