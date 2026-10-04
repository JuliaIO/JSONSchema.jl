# Copyright (c) 2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

using JSONSchema
using Test
import Downloads
import HTTP
import JSON
import JSON3
import OrderedCollections
import ZipFile

const TEST_SUITE_URL = "https://github.com/json-schema-org/JSON-Schema-Test-Suite/archive/23.1.0.zip"

const SCHEMA_TEST_DIR = let
    dest_dir = mktempdir()
    dest_file = joinpath(dest_dir, "test-suite.zip")
    Downloads.download(TEST_SUITE_URL, dest_file)
    for f in ZipFile.Reader(dest_file).files
        filename = joinpath(dest_dir, "test-suite", f.name)
        if endswith(filename, "/")
            mkpath(filename)
        else
            write(filename, read(f, String))
        end
    end
    joinpath(dest_dir, "test-suite", "JSON-Schema-Test-Suite-23.1.0", "tests")
end

const LOCAL_TEST_DIR = mktempdir(SCHEMA_TEST_DIR)

# Write test files for locally referenced schema files.
#
# These files have the same format as JSON Schema org test files. They are written
# to a sibling directory to JSON-Schema-Test-Suite-master/tests/draft* directories
# so they can be consumed the same way as the draft*/*.json test files.
# sibling directory for testing a relative path containing "../"
const REF_LOCAL_TEST_DIR = mktempdir(SCHEMA_TEST_DIR)

write(
    joinpath(REF_LOCAL_TEST_DIR, "localReferenceSchemaOne.json"),
    """{
    "type": "object",
    "properties": {"localRefOneResult": {"type": "string"}}
}""",
)

write(
    joinpath(REF_LOCAL_TEST_DIR, "localReferenceSchemaTwo.json"),
    """{
    "type": "object",
    "properties": {"localRefTwoResult": {"type": "number"}}
}""",
)

write(
    joinpath(REF_LOCAL_TEST_DIR, "nestedLocalReference.json"),
    """{
    "type": "object",
    "properties": {
        "result": {
            "\$ref": "file:localReferenceSchemaOne.json#/properties/localRefOneResult"
        }
    }
}""",
)

write(
    joinpath(LOCAL_TEST_DIR, "localReferenceTest.json"),
    """[{
    "description": "test locally referenced schemas",
    "schema": {
        "type": "object",
        "properties": {
            "result1": { "\$ref": "file:../$(basename(abspath(REF_LOCAL_TEST_DIR)))/localReferenceSchemaOne.json#/properties/localRefOneResult" },
            "result2": { "\$ref": "../$(basename(abspath(REF_LOCAL_TEST_DIR)))/localReferenceSchemaTwo.json#/properties/localRefTwoResult" }
        },
        "oneOf": [{
            "required": ["result1"]
        }, {
            "required": ["result2"]
        }]
    },
    "tests": [{
        "description": "reference only local schema 1",
        "data": {"result1": "some text"},
        "valid": true
    }, {
        "description": "reference only local schema 2",
        "data": {"result2": 1234},
        "valid": true
    }, {
        "description": "incorrect reference to local schema 1",
        "data": {"result1": true},
        "valid": false
    }, {
        "description": "reference neither local schemas",
        "data": {"result": true},
        "valid": false
    }, {
        "description": "reference both local schemas",
        "data": {"result1": "some text", "result2": 500},
        "valid": false
    }]
}]""",
)

write(
    joinpath(LOCAL_TEST_DIR, "nestedLocalReferenceTest.json"),
    """[{
    "description": "test locally referenced schemas",
    "schema": {
        "type": "object",
        "properties": {
            "result": {
                "\$ref": "file:../$(basename(abspath(REF_LOCAL_TEST_DIR)))/nestedLocalReference.json#/properties/result"
            }
        }
    },
    "tests": [{
        "description": "nested reference, correct type",
        "data": {"result": "some text"},
        "valid": true
    }, {
        "description": "nested reference, incorrect type",
        "data": {"result": 1234},
        "valid": false
    }]
}]""",
)

is_json(n) = endswith(n, ".json")

function test_draft_directory(server, dir, json_parse_fn::Function)
    @testset "$(file)" for file in filter(is_json, readdir(dir))
        if file == "unknownKeyword.json"
            # This is an optional test, and to be honest, it is pretty minor. It
            # relates to how we handle $id if the user includes part of a schema
            # that we don't know how to parse. As a low priority action item, we
            # could come back to this.
            continue
        end
        file_path = joinpath(dir, file)
        @testset "$(tests["description"])" for tests in json_parse_fn(file_path)
            # TODO(odow): fix this failing test
            fails =
                ["retrieved nested refs resolve relative to their URI not \$id"]
            if file == "refRemote.json" && tests["description"] in fails
                continue
            end
            is_bool = tests["schema"] isa Bool
            parent_dir = ifelse(is_bool, abspath("."), dirname(file_path))
            schema = JSONSchema.Schema(tests["schema"]; parent_dir)
            @testset "$(test["description"])" for test in tests["tests"]
                @test isvalid(schema, test["data"]) == test["valid"]
            end
        end
    end
    return
end

@testset "JSON-Schema-Test-Suite" begin
    GLOBAL_TEST_DIR = Ref{String}("")
    server = HTTP.Sockets.listen(HTTP.ip"127.0.0.1", 1234)
    HTTP.serve!("127.0.0.1", 1234; server = server) do req
        # Make sure to strip first character (`/`) from the target, otherwise it
        # will infer as a file in the root directory.
        file = joinpath(GLOBAL_TEST_DIR[], "../../remotes", req.target[2:end])
        return HTTP.Response(200, read(file, String))
    end
    @testset "$dir" for dir in [
        "draft4",
        "draft6",
        "draft7",
        basename(abspath(LOCAL_TEST_DIR)),
    ]
        GLOBAL_TEST_DIR[] = joinpath(SCHEMA_TEST_DIR, dir)
        @testset "JSON" begin
            test_draft_directory(server, GLOBAL_TEST_DIR[], JSON.parsefile)
        end
        @testset "JSON3" begin
            test_draft_directory(server, GLOBAL_TEST_DIR[], JSON3.read)
        end
    end
    close(server)
end

@testset "Validate and diagnose" begin
    schema = JSONSchema.Schema(
        Dict(
            "properties" => Dict("foo" => Dict(), "bar" => Dict()),
            "required" => ["foo"],
        ),
    )
    data_pass = Dict("foo" => true)
    data_fail = Dict("bar" => 12.5)
    @test JSONSchema.validate(schema, data_pass) === nothing
    ret = JSONSchema.validate(schema, data_fail)
    fail_msg = """Validation failed:
    path:         top-level
    instance:     $(data_fail)
    schema key:   required
    schema value: ["foo"]
    """
    @test ret !== nothing
    @test sprint(show, ret) == fail_msg
    @test JSONSchema.diagnose(data_pass, schema) === nothing
    @test JSONSchema.diagnose(data_fail, schema) == fail_msg
end

@testset "parentFileDirectory deprecation" begin
    schema = JSONSchema.Schema("{}"; parentFileDirectory = ".")
    @test typeof(schema) == Schema
end

@testset "Schemas" begin
    schema = JSONSchema.Schema("""{
        \"properties\": {
        \"foo\": {},
        \"bar\": {}
        },
        \"required\": [\"foo\"]
    }""")
    @test typeof(schema) == Schema
    @test typeof(schema.data) <: AbstractDict{String,Any}
    schema_2 = JSONSchema.Schema(false)
    @test typeof(schema_2) == Schema
    @test typeof(schema_2.data) == Bool

    schema_dict = Dict(
        "properties" =>
            Dict("age" => Dict("\$ref" => "#/\$defs/positiveNumber")),
        "\$defs" => Dict(
            "positiveNumber" => Dict("type" => "number", "minimum" => 0),
        ),
    )
    schema = JSONSchema.Schema(schema_dict)
    @test isvalid(schema, Dict("age" => 1))
    @test !isvalid(schema, Dict("age" => -1))
    @test schema_dict["properties"]["age"]["\$ref"] == "#/\$defs/positiveNumber"
end

@testset "Base.show" begin
    schema = JSONSchema.Schema("{}")
    @test sprint(show, schema) == "A JSONSchema"
end

@testset "errors" begin
    @test_throws(
        ErrorException("missing property 'Foo' in $(JSON.parse("{}"))."),
        JSONSchema.Schema("""{
            "type": "object",
            "properties": {"version": {"\$ref": "#/definitions/Foo"}},
            "definitions": {}
        }"""),
    )
    @test_throws(
        ErrorException("unmanaged type in ref resolution $(Int64): 1."),
        JSONSchema.Schema("""{
            "type": "object",
            "properties": {"version": {"\$ref": "#/definitions/Foo"}},
            "definitions": 1
        }""")
    )
    @test_throws(
        ErrorException("expected integer array index instead of 'Foo'."),
        JSONSchema.Schema("""{
            "type": "object",
            "properties": {"version": {"\$ref": "#/definitions/Foo"}},
            "definitions": [1, 2]
        }""")
    )
    @test_throws(
        ErrorException("item index 3 is larger than array $(Any[1, 2])."),
        JSONSchema.Schema("""{
            "type": "object",
            "properties": {"version": {"\$ref": "#/definitions/3"}},
            "definitions": [1, 2]
        }""")
    )
    @test_throws(
        ErrorException("cannot support circular references in schema."),
        JSONSchema.validate(
            JSONSchema.Schema("""{
                "type": "object",
                "properties": {
                    "version": {
                        "\$ref": "#/definitions/Foo"
                    }
                },
                "definitions": {
                    "Foo": {
                        "\$ref": "#/definitions/Foo"
                    }
                }
            }"""),
            Dict("version" => 1),
        )
    )
end

@testset "_is_type" begin
    for (key, val) in Dict(
        :array => [1, 2],
        :boolean => true,
        :integer => 1,
        :number => 1.0,
        :null => nothing,
        :object => Dict(),
        :string => "string",
    )
        @test JSONSchema._is_type(val, Val(Symbol(key)))
        @test !JSONSchema._is_type(:not_a_json_type, Val(Symbol(key)))
    end
    @test JSONSchema._is_type(missing, Val(:null))

    @test !JSONSchema._is_type(true, Val(:number))
    @test !JSONSchema._is_type(true, Val(:integer))
end

@testset "OrderedDict" begin
    schema = JSONSchema.Schema(
        Dict(
            "properties" => Dict("foo" => Dict(), "bar" => Dict()),
            "required" => ["foo"],
        ),
    )
    data_pass = OrderedCollections.OrderedDict("foo" => true)
    data_fail = OrderedCollections.OrderedDict("bar" => 12.5)
    @test JSONSchema.validate(schema, data_pass) === nothing
    @test JSONSchema.validate(schema, data_fail) != nothing
end

@testset "Inverse argument order" begin
    schema = JSONSchema.Schema(
        Dict(
            "properties" => Dict("foo" => Dict(), "bar" => Dict()),
            "required" => ["foo"],
        ),
    )
    data_pass = Dict("foo" => true)
    data_fail = Dict("bar" => 12.5)
    @test JSONSchema.validate(data_pass, schema) === nothing
    @test JSONSchema.validate(data_fail, schema) != nothing
    @test isvalid(data_pass, schema)
    @test !isvalid(data_fail, schema)
end

@testset "exports" begin
    @test Schema === JSONSchema.Schema
    @test validate === JSONSchema.validate
    @test diagnose === JSONSchema.diagnose
    @test !(:schema in names(JSONSchema))
    @test !(:spec in names(JSONSchema))
    @test JSONSchema.schema(@NamedTuple{x::String}) isa JSONSchema.Schema
end

include("generation.jl")

@testset "patternProperties issue paths" begin
    integer_schema = Dict("type" => "integer")
    pattern_schema = Dict("patternProperties" => Dict("^x" => integer_schema))
    schema = JSONSchema.Schema(pattern_schema)
    for key in ("xyz", "x]", "x/y", "xλ")
        issue = JSONSchema.validate(schema, Dict(key => "bad"))
        @test issue.path == "[$(key)]"
        @test issue.reason == "type"
        @test issue.x == "bad"
        @test occursin("path:         [$(key)]\n", sprint(show, issue))
        @test JSONSchema.validate(schema, Dict(key => 1)) === nothing
    end

    schema = JSONSchema.Schema(
        Dict("properties" =>
                Dict("outer" => Dict("items" => pattern_schema))),
    )
    issue = JSONSchema.validate(schema, Dict("outer" => [Dict("xyz" => "bad")]))
    @test issue.path == "[outer][1][xyz]"
    @test issue.reason == "type"
    @test JSONSchema.validate(schema, Dict("outer" => [Dict("xyz" => 1)])) ===
          nothing

    schema = JSONSchema.Schema(
        Dict("patternProperties" => Dict("^outer" => pattern_schema)),
    )
    issue = JSONSchema.validate(schema, Dict("outer" => Dict("xyz" => "bad")))
    @test issue.path == "[outer][xyz]"
    @test issue.reason == "type"
    @test JSONSchema.validate(schema, Dict("outer" => Dict("xyz" => 1))) ===
          nothing

    schema = JSONSchema.Schema(Dict("patternProperties" => Dict("^x" => false)))
    issue = JSONSchema.validate(schema, Dict("xyz" => 1))
    @test issue.path == "[xyz]"
    @test issue.reason == "schema"
    @test issue.val === false
    @test JSONSchema.validate(schema, Dict("other" => "bad")) === nothing
end

function check_pointer(schema, data, path, pointer)
    issue = JSONSchema.validate(JSONSchema.Schema(schema), data)
    @test issue isa JSONSchema.SingleIssue
    @test issue.path == path
    @test JSONSchema.json_pointer(issue) == pointer
    @test occursin(
        "path:         " * (isempty(path) ? "top-level" : path),
        sprint(show, issue),
    )
    return issue
end

@testset "JSON pointers for validation issues" begin
    check_pointer(false, Dict("a" => 1), "", "#")
    check_pointer(Dict("items" => false), [1], "", "#")
    check_pointer(
        Dict("items" => Dict("type" => "integer")),
        [1, "bad"],
        "[2]",
        "#/1",
    )
    check_pointer(Dict("items" => [true, false]), [1, 2], "[2]", "#/1")
    check_pointer(
        Dict("items" => [true], "additionalItems" => Dict("type" => "integer")),
        [1, "bad"],
        "[2]",
        "#/1",
    )

    for (key, pointer) in (
        ("", "#/"),
        ("1", "#/1"),
        ("a/b", "#/a~1b"),
        ("m~n", "#/m~0n"),
        ("~1", "#/~01"),
        ("c%d", "#/c%25d"),
        ("e^f", "#/e%5Ef"),
        ("g|h", "#/g%7Ch"),
        ("i\\j", "#/i%5Cj"),
        ("k\"l", "#/k%22l"),
        (" ", "#/%20"),
        ("a]", "#/a%5D"),
        ("λ", "#/%CE%BB"),
        ("#", "#/%23"),
        ("\0", "#/%00"),
    )
        check_pointer(
            Dict("properties" => Dict(key => false)),
            Dict(key => 1),
            "[$key]",
            pointer,
        )
    end

    nested = Dict(
        "properties" => Dict(
            "foo" => Dict(
                "items" => Dict("properties" => Dict("bar" => false)),
            ),
        ),
    )
    issue = check_pointer(
        nested,
        Dict("foo" => [Dict("bar" => 1)]),
        "[foo][1][bar]",
        "#/foo/0/bar",
    )
    @test JSONSchema.json_pointer(issue) == "#/foo/0/bar"

    recovered = Dict(
        "allOf" => [
            Dict("anyOf" => [nested, true]),
            Dict("properties" => Dict("bar" => false)),
        ],
    )
    check_pointer(
        recovered,
        Dict("foo" => [Dict("bar" => 1)], "bar" => 2),
        "[bar]",
        "#/bar",
    )
    check_pointer(
        Dict("contains" => Dict("properties" => Dict("bar" => false))),
        [Dict("bar" => 1)],
        "",
        "#",
    )
    check_pointer(
        Dict(
            "properties" =>
                Dict("a" => Dict("properties" => Dict("1" => false))),
        ),
        Dict("a" => Dict("1" => 1)),
        "[a][1]",
        "#/a/1",
    )
    check_pointer(
        Dict(
            "properties" =>
                Dict("a" => Dict("items" => Dict("type" => "string"))),
        ),
        Dict("a" => [1]),
        "[a][1]",
        "#/a/0",
    )
    check_pointer(
        Dict(
            "patternProperties" =>
                Dict("^x" => Dict("items" => Dict("type" => "string"))),
        ),
        Dict("x]" => [1]),
        "[x]][1]",
        "#/x%5D/0",
    )
    check_pointer(
        Dict("additionalProperties" => Dict("type" => "integer")),
        Dict("a/b" => "bad"),
        "[a/b]",
        "#/a~1b",
    )

    branches = Dict(
        "properties" => Dict(
            "a" => Dict(
                "anyOf" => [
                    Dict("items" => Dict("type" => "string")),
                    Dict("items" => Dict("type" => "number")),
                ],
            ),
        ),
    )
    first_issue = check_pointer(branches, Dict("a" => [true]), "[a]", "#/a")
    check_pointer(
        Dict("properties" => Dict("b" => false)),
        Dict("b" => 1),
        "[b]",
        "#/b",
    )
    @test JSONSchema.json_pointer(first_issue) == "#/a"
    @test JSONSchema.json_pointer(issue) == "#/foo/0/bar"

    conditional = Dict(
        "properties" => Dict(
            "a" => Dict(
                "if" => Dict("type" => "object"),
                "then" => Dict("properties" => Dict("b" => false)),
            ),
        ),
    )
    check_pointer(conditional, Dict("a" => Dict("b" => 1)), "[a][b]", "#/a/b")
    reference = Dict(
        "definitions" => Dict("bad" => false),
        "properties" => Dict("a" => Dict("\$ref" => "#/definitions/bad")),
    )
    check_pointer(reference, Dict("a" => 1), "[a]", "#/a")
    @test JSONSchema.validate(
        JSONSchema.Schema(Dict("items" => Dict("type" => "integer"))),
        [1, 2],
    ) === nothing

    legacy = JSONSchema.SingleIssue(1, "[1]", "type", "string")
    @test legacy.path == "[1]"
    @test_throws ArgumentError JSONSchema.json_pointer(legacy)
    @test JSONSchema.json_pointer(
        JSONSchema.SingleIssue(1, "", "type", "string"),
    ) == "#"
end

function scalar_validation_batch(schema)
    for _ in 1:1000
        @assert JSONSchema.validate(schema, 1) === nothing
    end
    return nothing
end

@testset "Reference tracking allocation and behavior" begin
    scalar = JSONSchema.Schema(Dict("type" => "integer"))
    scalar_validation_batch(scalar)
    @test @allocated(scalar_validation_batch(scalar)) <= 80_000
    @test JSONSchema.validate(JSONSchema.Schema(true), 1) === nothing
    issue = JSONSchema.validate(JSONSchema.Schema(false), 1)
    @test issue.x == 1
    @test issue.reason == "schema"
    @test issue.path == ""
    @test JSONSchema.json_pointer(issue) == "#"

    for terminal in (true, false, Dict("type" => "integer"))
        schema = JSONSchema.Schema(
            Dict(
                "definitions" => Dict(
                    "a" => Dict("\$ref" => "#/definitions/b"),
                    "b" => terminal,
                ),
                "\$ref" => "#/definitions/a",
            ),
        )
        result = JSONSchema.validate(schema, 1)
        @test (result === nothing) == (terminal !== false)
        if result !== nothing
            @test result.reason == "schema"
            @test JSONSchema.json_pointer(result) == "#"
        end
    end
    schema = JSONSchema.Schema(
        Dict(
            "definitions" => Dict(
                "a" => Dict("\$ref" => "#/definitions/b"),
                "b" => Dict("type" => "integer"),
            ),
            "\$ref" => "#/definitions/a",
        ),
    )
    issue = JSONSchema.validate(schema, "bad")
    @test issue.reason == "type"
    @test issue.x == "bad"
    @test JSONSchema.json_pointer(issue) == "#"
    @test JSONSchema.validate(schema, 2) === nothing

    for definitions in (
        Dict("a" => Dict("\$ref" => "#/definitions/a")),
        Dict(
            "a" => Dict("\$ref" => "#/definitions/b"),
            "b" => Dict("\$ref" => "#/definitions/a"),
        ),
    )
        schema = JSONSchema.Schema(
            Dict("definitions" => definitions, "\$ref" => "#/definitions/a"),
        )
        @test_throws ErrorException(
            "cannot support circular references in schema.",
        ) JSONSchema.validate(schema, 1)
    end
end

function check_reference_pointer(payload, ref; parent_dir = pwd())
    raw = merge(
        payload,
        Dict("properties" => Dict("value" => Dict("\$ref" => ref))),
    )
    schema = JSONSchema.Schema(raw; parent_dir = parent_dir)
    @test JSONSchema.validate(schema, Dict("value" => 1)) === nothing
    issue = JSONSchema.validate(schema, Dict("value" => "bad"))
    @test issue isa JSONSchema.SingleIssue
    @test issue.reason == "type"
    @test issue.path == "[value]"
    @test JSONSchema.json_pointer(issue) == "#/value"
    @test raw["properties"]["value"]["\$ref"] == ref
end

@testset "Reference JSON pointer decoding" begin
    for (key, encoded) in (
        ("~1", "~01"),
        ("~01", "~001"),
        ("~", "~0"),
        ("a/b", "a~1b"),
        ("λ", "%CE%BB"),
        ("λ", "%ce%bb"),
        ("😄", "%F0%9F%98%84"),
        ("a^|b", "a%5E%7Cb"),
        ("a^|b", "a%5e%7cb"),
        ("~1", "%7E01"),
        ("a/b", "a%7E1b"),
        ("%2F", "%252F"),
        ("100%", "100%25"),
        ("+", "+"),
        (" ", "%20"),
        ("\0", "%00"),
        ("", ""),
    )
        @testset "key $key through $encoded" begin
            payload =
                Dict("definitions" => Dict(key => Dict("type" => "integer")))
            check_reference_pointer(payload, "#/definitions/" * encoded)
        end
    end
    @testset "empty root key" begin
        check_reference_pointer(Dict("" => Dict("type" => "integer")), "#/")
    end
    @testset "nested empty root key" begin
        check_reference_pointer(
            Dict("" => Dict("target" => Dict("type" => "integer"))),
            "#//target",
        )
    end
    for ref in (
        "#/definitions%2Ftarget",
        "#%2Fdefinitions%2Ftarget",
        "#%2fdefinitions%2ftarget",
    )
        @testset "encoded separators $ref" begin
            payload = Dict(
                "definitions" =>
                    Dict("target" => Dict("type" => "integer")),
            )
            check_reference_pointer(payload, ref)
        end
    end
    @testset "encoded slash selects separate tokens" begin
        payload = Dict(
            "definitions" => Dict(
                "a/b" => Dict("type" => "string"),
                "a" => Dict("b" => Dict("type" => "integer")),
            ),
        )
        check_reference_pointer(payload, "#/definitions/a%2Fb")
    end
    @testset "local file fragments" begin
        mktempdir() do dir
            payload = Dict(
                "definitions" => Dict(
                    "λ" => Dict("type" => "integer"),
                    "~1" => Dict("type" => "integer"),
                    "a" => Dict("b" => Dict("type" => "integer")),
                ),
                "" => Dict("type" => "integer"),
            )
            write(joinpath(dir, "schema.json"), JSON.json(payload))
            for fragment in (
                "#/definitions/%CE%BB",
                "#/definitions/~01",
                "#%2Fdefinitions%2Fa%2Fb",
                "#/",
            )
                @testset "$fragment" begin
                    check_reference_pointer(
                        Dict{String,Any}(),
                        "schema.json" * fragment;
                        parent_dir = dir,
                    )
                end
            end
        end
    end
end

@testset "Reference array index tokens" begin
    targets = [Dict("type" => "integer"), Dict("type" => "string")]
    for (token, accepted, rejected) in
        (("0", 1, "bad"), ("1", "ok", 1), ("%30", 1, "bad"), ("%31", "ok", 1))
        raw =
            Dict("definitions" => targets, "\$ref" => "#/definitions/" * token)
        schema = JSONSchema.Schema(raw)
        @test JSONSchema.validate(schema, accepted) === nothing
        @test JSONSchema.validate(schema, rejected) isa JSONSchema.SingleIssue
        @test raw["\$ref"] == "#/definitions/" * token
    end

    for token in (
        "",
        "+0",
        "+1",
        "-0",
        "-1",
        "00",
        "01",
        " 0",
        "0 ",
        "0\n",
        "0\r",
        "\t0",
        "0\t",
        "0x0",
        "1e0",
        "０",
        "١",
        "%2B0",
        "%2D0",
        "%30%31",
        "%200",
        "0%0A",
        "-",
    )
        @testset "invalid token $(repr(token))" begin
            @test_throws ErrorException JSONSchema.Schema(
                Dict(
                    "definitions" => targets,
                    "\$ref" => "#/definitions/" * token,
                ),
            )
        end
    end
    for token in ("2", "9223372036854775807", "18446744073709551616")
        @test_throws ErrorException JSONSchema.Schema(
            Dict("definitions" => targets, "\$ref" => "#/definitions/" * token),
        )
    end
    @test_throws ErrorException JSONSchema.Schema(
        Dict("definitions" => Any[], "\$ref" => "#/definitions/0"),
    )

    for (key, token) in (
        ("01", "01"),
        ("+0", "+0"),
        ("-1", "-1"),
        (" 0", "%200"),
        ("0\n", "0%0A"),
        ("０", "%EF%BC%90"),
        ("", ""),
        ("-", "-"),
    )
        raw = Dict(
            "definitions" => Dict(key => Dict("type" => "integer")),
            "\$ref" => "#/definitions/" * token,
        )
        schema = JSONSchema.Schema(raw)
        @test JSONSchema.validate(schema, 1) === nothing
        @test JSONSchema.validate(schema, "bad") isa JSONSchema.SingleIssue
        @test raw["\$ref"] == "#/definitions/" * token
    end
end

@testset "Reference token escape syntax" begin
    for (key, token) in (
        ("~", "~0"),
        ("~2", "~02"),
        ("a~b", "a~0b"),
        ("~~", "~0~0"),
        ("~/~", "~0~1~0"),
        ("/", "~1"),
        ("~1", "~01"),
        ("~01", "~001"),
        ("λ~2", "%CE%BB~02"),
        ("~", "%7E0"),
        ("~2", "%7e02"),
        ("%7E2", "%257E2"),
    )
        raw = Dict(
            "definitions" => Dict(key => Dict("type" => "integer")),
            "\$ref" => "#/definitions/" * token,
        )
        schema = JSONSchema.Schema(raw)
        @test JSONSchema.validate(schema, 1) === nothing
        @test JSONSchema.validate(schema, "bad") isa JSONSchema.SingleIssue
        @test raw["\$ref"] == "#/definitions/" * token
    end
    for (key, token) in (
        ("~", "~"),
        ("name~", "name~"),
        ("~2", "~2"),
        ("a~b", "a~b"),
        ("~0~", "~00~"),
        ("~1~2", "~01~2"),
        ("~~", "~~0"),
        ("~/", "~~1"),
        ("~~9", "~0~9"),
        ("~\0", "~%00"),
        ("~λ", "~%CE%BB"),
        ("/~", "~1~"),
        ("~", "%7E"),
        ("~2", "%7e2"),
        ("a~b", "a%7Eb"),
        ("~~", "%7E%7E0"),
    )
        @testset "invalid escape $(repr(token))" begin
            raw = Dict(
                "definitions" => Dict(key => Dict("type" => "integer")),
                "\$ref" => "#/definitions/" * token,
            )
            @test_throws ErrorException JSONSchema.Schema(raw)
            @test raw["\$ref"] == "#/definitions/" * token
        end
    end
    mktempdir() do dir
        write(
            joinpath(dir, "targets.json"),
            JSONSchema.JSON.json(
                Dict(
                    "definitions" => Dict("a~2b" => Dict("type" => "integer")),
                ),
            ),
        )
        @test_throws ErrorException JSONSchema.Schema(
            Dict("\$ref" => "targets.json#/definitions/a~2b");
            parent_dir = dir,
        )
        schema = JSONSchema.Schema(
            Dict("\$ref" => "targets.json#/definitions/a~02b");
            parent_dir = dir,
        )
        @test JSONSchema.validate(schema, 1) === nothing
        @test JSONSchema.validate(schema, "bad") isa JSONSchema.SingleIssue
    end
end

@testset "Boolean instances ignore numeric assertions" begin
    cases = (
        ("multipleOf", 2, 4, 3),
        ("maximum", 0, 0, 1),
        ("minimum", 1, 1, 0),
        ("exclusiveMaximum", 1, 0, 1),
        ("exclusiveMinimum", 0, 1, 0),
    )
    for (keyword, limit, good, bad) in cases
        raw = Dict(keyword => limit)
        schema = JSONSchema.Schema(raw)
        for value in (true, false)
            @test JSONSchema.validate(schema, value) === nothing
            @test isvalid(schema, value)
            typed =
                JSONSchema.Schema(Dict("type" => "boolean", keyword => limit))
            @test JSONSchema.validate(typed, value) === nothing
            array = JSONSchema.Schema(Dict("items" => raw))
            @test JSONSchema.validate(array, [value]) === nothing
            object =
                JSONSchema.Schema(Dict("properties" => Dict("flag" => raw)))
            @test JSONSchema.validate(object, Dict("flag" => value)) === nothing
        end
        @test JSONSchema.validate(schema, good) === nothing
        issue = JSONSchema.validate(schema, bad)
        @test issue isa JSONSchema.SingleIssue
        @test issue.reason == keyword
        @test issue.path == ""
        @test JSONSchema.validate(schema, Float64(good)) === nothing
        @test JSONSchema.validate(schema, Float64(bad)) isa
              JSONSchema.SingleIssue
        for value in ("text", nothing, [], Dict("a" => 1))
            @test JSONSchema.validate(schema, value) === nothing
        end
    end
    for (keyword, boundkey, bound) in (
            ("exclusiveMaximum", "maximum", 0),
            ("exclusiveMinimum", "minimum", 1),
        ),
        exclusive in (true, false)

        schema =
            JSONSchema.Schema(Dict(keyword => exclusive, boundkey => bound))
        for value in (true, false)
            @test JSONSchema.validate(schema, value) === nothing
        end
        @test (JSONSchema.validate(schema, bound) === nothing) == !exclusive
    end
    for typ in ("number", "integer"), value in (true, false)
        @test JSONSchema.validate(
            JSONSchema.Schema(Dict("type" => typ)),
            value,
        ) isa JSONSchema.SingleIssue
    end
    for value in (true, false)
        schema = JSONSchema.Schema(
            Dict(
                "anyOf" => [
                    Dict("type" => "boolean", "minimum" => 2),
                    Dict("type" => "integer", "minimum" => 2),
                ],
            ),
        )
        @test JSONSchema.validate(schema, value) === nothing
    end
end

@testset "JSON null equality" begin
    cases = Any[
        (nothing, nothing, true),
        (missing, missing, true),
        (nothing, missing, true),
        (missing, nothing, true),
        ([nothing], [missing], true),
        (Any[missing, nothing], Any[nothing, missing], true),
        (Dict("a" => missing), Dict("a" => nothing), true),
        ([Dict("a" => missing)], [Dict("a" => nothing)], true),
        (Dict("a" => [missing]), Dict("a" => [nothing]), true),
        ([missing], [nothing, nothing], false),
        (Dict("a" => missing), Dict("b" => nothing), false),
        (0, 0.0, true),
        (1, 1.0, true),
        (false, 0, false),
        (true, 1, false),
        ([false], [0], false),
        (Dict("a" => true), Dict("a" => 1), false),
    ]
    for null in (nothing, missing),
        other in
        (false, true, 0, 1, 0.0, 1.0, "", "null", Int[], Dict("a" => nothing))

        push!(cases, (null, other, false))
    end
    for (x, y, equal) in cases
        for (instance, expected) in ((x, y), (y, x))
            for (keyword, constraint) in
                (("const", expected), ("enum", Any[expected]))
                @test begin
                    result = JSONSchema.validate(
                        JSONSchema.Schema(Dict(keyword => constraint)),
                        instance,
                    )
                    equal ? result === nothing :
                    result isa JSONSchema.SingleIssue
                end
            end
        end
        @test begin
            result = JSONSchema.validate(
                JSONSchema.Schema(Dict("uniqueItems" => true)),
                Any[x, y],
            )
            equal ? result isa JSONSchema.SingleIssue : result === nothing
        end
    end
    for null in (nothing, missing)
        @test isvalid(JSONSchema.Schema(Dict("type" => "null")), null)
        raw = Dict("enum" => Any[null])
        JSONSchema.Schema(raw)
        @test raw["enum"][1] === null
        for (data, schema, path, pointer) in (
            (
                Dict("flag" => null),
                Dict("properties" => Dict("flag" => Dict("const" => 0))),
                "[flag]",
                "#/flag",
            ),
            (Any[null], Dict("items" => Dict("enum" => Any[0])), "[1]", "#/0"),
        )
            @testset "null at $pointer" begin
                parsed_schema = JSONSchema.Schema(schema)
                @test JSONSchema.validate(parsed_schema, data) isa
                      JSONSchema.SingleIssue
                @test JSONSchema.validate(parsed_schema, data).x === null
                @test JSONSchema.validate(parsed_schema, data).path == path
                @test JSONSchema.json_pointer(
                    JSONSchema.validate(parsed_schema, data),
                ) == pointer
            end
        end
    end
end
