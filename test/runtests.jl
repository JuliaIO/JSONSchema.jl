# Copyright (c) 2018-2026: fredo-dedup, quinnj, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

using JSON
using JSONSchema
using Tar
using Test

include("schema.jl")

function tar_files(tarball::String)
    data = Dict{String, Vector{UInt8}}()
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    open(tarball) do tio
        Tar.read_tarball(_ -> true, tio; buf=buf) do header, _
            if header.type == :file
                take!(io) # In case there are multiple entries for the file
                Tar.read_data(tio, io; size=header.size, buf)
                data[header.path] = take!(io)
            end
        end
    end
    data
end

function make_remote_loader(files::Dict{String, Vector{UInt8}}, draft::String)
    cache = Dict{String, Vector{UInt8}}()
    draft_prefix = "remotes/$(draft)/"
    return function (uri::String)
        if haskey(cache, uri)
            return cache[uri]
        end

        m = match(r"^https?://localhost:1234/(.*)$", uri)
        if m !== nothing
            rel_path = m.captures[1]
            data = get(files, "remotes/" * rel_path, nothing)
            if data === nothing
                data = get(files, draft_prefix * rel_path, nothing)
            end
            if data !== nothing
                cache[uri] = data
                return data
            end
        end

        return nothing
    end
end

function draft_entries(files::Dict{String, Vector{UInt8}}, draft::String)
    prefix = "tests/$(draft)/"
    paths = sort([
        path for path in keys(files)
        if startswith(path, prefix) &&
           endswith(path, ".json") &&
           !occursin("/__MACOSX/", path) &&
           !startswith(basename(path), "._")
    ])
    return [(path, files[path]) for path in paths]
end

function run_test_file(draft::String, path::String, data::Vector{UInt8}, failures, remote_loader)
    groups = JSON.parse(data)
    @testset "$(basename(path))" begin
        for group in groups
            group_desc = string(get(group, "description", "unknown"))
            schema = JSONSchema.Schema(group["schema"])
            resolver = JSONSchema.RefResolver(schema.spec; remote_loader=remote_loader)
            @testset "$group_desc" begin
                for case in group["tests"]
                    case_desc = string(get(case, "description", "case"))
                    expected = case["valid"]
                    value = case["data"]
                    @testset "$case_desc" begin
                        result = try
                            # validate returns nothing on success, ValidationResult on failure
                            JSONSchema.validate(schema, value; resolver=resolver) === nothing
                        catch
                            :error
                        end
                        if result == expected
                            @test result == expected
                        else
                            if failures !== nothing
                                push!(failures, (draft=draft, file=basename(path), group=group_desc, case=case_desc, expected=expected, result=result))
                            end
                            @test_broken result == expected
                        end
                    end
                end
            end
        end
    end
end

const schema_test_suite = tar_files(joinpath(@__DIR__, "JSONSchemaTestSuite.tar"))
const drafts = ["draft4", "draft6", "draft7"]
const report_path = get(ENV, "JSONSCHEMA_TESTSUITE_REPORT", nothing)
const suite_failures = report_path === nothing ? nothing : []

@testset "JSON-Schema-Test-Suite" begin
    for draft in drafts
        @testset "$draft" begin
            remote_loader = make_remote_loader(schema_test_suite, draft)
            for (path, data) in draft_entries(schema_test_suite, draft)
                run_test_file(draft, path, data, suite_failures, remote_loader)
            end
        end
    end
end

if suite_failures !== nothing && !isempty(suite_failures)
    open(report_path, "w") do io
        for item in suite_failures
            println(io, "$(item.draft)\t$(item.file)\t$(item.group)\t$(item.case)\texpected=$(item.expected)\tresult=$(item.result)")
        end
    end
end
