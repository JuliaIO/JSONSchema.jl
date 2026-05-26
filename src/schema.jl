# Copyright (c) 2018: fredo-dedup and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Transform escaped characters in JPaths back to their original value.
function unescape_jpath(raw::String)
    ret = replace(replace(raw, "~0" => "~"), "~1" => "/")
    m = match(r"%([0-9A-F]{2})", ret)
    if m !== nothing
        for c in m.captures
            ret = replace(ret, "%$(c)" => Char(parse(UInt8, "0x$(c)")))
        end
    end
    return ret
end

function type_to_dict(x)
    return Dict(name => getfield(x, name) for name in fieldnames(typeof(x)))
end

function update_id(uri::URIs.URI, s::String)
    id2 = URIs.URI(s)
    if !isempty(id2.scheme) || (isempty(string(uri)) && startswith(s, "#"))
        return id2
    end
    els = type_to_dict(uri)
    delete!(els, :uri)
    els[:fragment] = id2.fragment
    if !isempty(id2.path)
        if startswith(id2.path, "/")  # Absolute path
            els[:path] = id2.path
        else # Relative path
            old_path = match(r"^(.*/).*$", uri.path)
            if old_path === nothing
                els[:path] = id2.path
            else
                els[:path] = old_path.captures[1] * id2.path
            end
        end
    end
    return URIs.URI(; els...)
end

function get_element(schema, path::AbstractString)
    elements = split(path, "/"; keepempty = true)
    if isempty(first(elements))
        popfirst!(elements)
    end
    for element in elements
        schema = _recurse_get_element(schema, unescape_jpath(String(element)))
    end
    return schema
end

function _recurse_get_element(schema::Any, ::String)
    return error(
        "unmanaged type in ref resolution $(typeof(schema)): $(schema).",
    )
end

function _recurse_get_element(schema::AbstractDict, element::String)
    if !haskey(schema, element)
        error("missing property '$(element)' in $(schema).")
    end
    return schema[element]
end

function _recurse_get_element(schema::AbstractVector, element::String)
    index = tryparse(Int, element)  # Remember that `index` is 0-indexed!
    if index === nothing
        error("expected integer array index instead of '$(element)'.")
    elseif index >= length(schema)
        error("item index $(index) is larger than array $(schema).")
    end
    return schema[index+1]
end

function get_remote_schema(uri::URIs.URI)
    io = IOBuffer()
    r = Downloads.request(string(uri); output = io, throw = false)
    if r isa Downloads.Response && r.status == 200
        return Schema(JSON.parse(seekstart(io)))
    end
    msg = "Unable to get remote schema at $uri"
    if r isa Downloads.RequestError
        msg *= ": " * r.message
    elseif r isa Downloads.Response
        msg *= ": HTTP status code $(r.status)"
    end
    return error(msg)
end

function find_ref(
    uri::URIs.URI,
    id_map::AbstractDict,
    path::String,
    parent_dir::String,
)
    if haskey(id_map, path)
        return id_map[path] # An exact path exists. Get it.
    elseif path == "" || path == "#"  # This path refers to the root schema.
        return id_map[string(uri)]
    elseif startswith(path, "#/")  # This path is a JPointer.
        return get_element(id_map[string(uri)], path[3:end])
    end
    uri = update_id(uri, path)
    els = type_to_dict(uri)
    delete!.(Ref(els), [:uri, :fragment])
    uri2 = URIs.URI(; els...)
    is_file_uri = startswith(uri2.scheme, "file") || isempty(uri2.scheme)
    if is_file_uri && !isabspath(uri2.path)
        # Normalize a file path to an absolute path so creating a key is consistent.
        uri2 = URIs.URI(uri2; path = abspath(joinpath(parent_dir, uri2.path)))
    end
    if !haskey(id_map, string(uri2))
        # id_map doesn't have this key so, fetch the ref and add it to id_map.
        if startswith(uri2.scheme, "http")
            @info("fetching remote ref $(uri2)")
            id_map[string(uri2)] = get_remote_schema(uri2).data
        else
            @assert is_file_uri
            @info("loading local ref $(uri2)")
            local_schema = Schema(
                JSON.parsefile(uri2.path);
                parent_dir = dirname(uri2.path),
            )
            id_map[string(uri2)] = local_schema.data
        end
    end
    return get_element(id_map[string(uri2)], uri.fragment)
end

# Recursively find all "$ref" fields and resolve their path.

resolve_refs!(::Any, ::URIs.URI, ::AbstractDict, ::String) = nothing

function resolve_refs!(
    schema::AbstractVector,
    uri::URIs.URI,
    id_map::AbstractDict,
    parent_dir::String,
)
    for s in schema
        resolve_refs!(s, uri, id_map, parent_dir)
    end
    return
end

function resolve_refs!(
    schema::AbstractDict,
    uri::URIs.URI,
    id_map::AbstractDict,
    parent_dir::String,
)
    # This $ref has not been resolved yet (otherwise it would not be a String).
    # We will replace the path string with the schema element pointed at, thus
    # marking it as resolved. This should prevent infinite recursions caused by
    # self referencing. We also unpack the $ref first so that fields like $id
    # do not interfere with it.
    ref = get(schema, "\$ref", nothing)
    ref_unpacked = false
    if ref isa String
        schema["\$ref"] = find_ref(uri, id_map, ref, parent_dir)
        ref_unpacked = true
    end
    if haskey(schema, "id") && schema["id"] isa String
        # This block is for draft 4.
        uri = update_id(uri, schema["id"])
    end
    if haskey(schema, "\$id") && schema["\$id"] isa String
        # This block is for draft 6+.
        uri = update_id(uri, schema["\$id"])
    end
    for (k, v) in schema
        if k == "\$ref" && ref_unpacked
            continue  # We've already unpacked this ref
        elseif k in ("enum", "const")
            continue  # Don't unpack refs inside const and enum.
        else
            resolve_refs!(v, uri, id_map, parent_dir)
        end
    end
    return
end

function build_id_map(schema::AbstractDict)
    id_map = Dict{String,Any}("" => schema)
    build_id_map!(id_map, schema, URIs.URI())
    return id_map
end

build_id_map!(::AbstractDict, ::Any, ::URIs.URI) = nothing

function build_id_map!(
    id_map::AbstractDict,
    schema::AbstractVector,
    uri::URIs.URI,
)
    build_id_map!.(Ref(id_map), schema, Ref(uri))
    return
end

function build_id_map!(
    id_map::AbstractDict,
    schema::AbstractDict,
    uri::URIs.URI,
)
    if haskey(schema, "id") && schema["id"] isa String
        # This block is for draft 4.
        uri = update_id(uri, schema["id"])
        id_map[string(uri)] = schema
    end
    if haskey(schema, "\$id") && schema["\$id"] isa String
        # This block is for draft 6+.
        uri = update_id(uri, schema["\$id"])
        id_map[string(uri)] = schema
    end
    for (k, value) in schema
        if k == "enum" || k == "const"
            continue
        end
        build_id_map!(id_map, value, uri)
    end
    return
end

"""
    Schema(schema::AbstractDict; parent_dir::String = abspath("."))

Create a schema but with `schema` being a parsed JSON created with `JSON.parse()`
or `JSON.parsefile()`.

`parent_dir` is the path with respect to which references to local schemas are
resolved.

## Examples

```julia
my_schema = Schema(JSON.parsefile(filename))
my_schema = Schema(JSON.parsefile(filename); parent_dir = "~/schemas")
```
"""
struct Schema
    data::Union{AbstractDict,Bool}

    Schema(schema::Bool; kwargs...) = new(schema)

    function Schema(
        schema::AbstractDict;
        parent_dir::String = abspath("."),
        parentFileDirectory = nothing,
    )
        if parentFileDirectory !== nothing
            @warn(
                "kwarg `parentFileDirectory` is deprecated. Use `parent_dir` instead."
            )
            parent_dir = parentFileDirectory
        end
        schema = deepcopy(schema)  # Ensure we don't modify the user's data!
        id_map = build_id_map(schema)
        resolve_refs!(schema, URIs.URI(), id_map, parent_dir)
        return new(schema)
    end
end

"""
    Schema(schema::String; parent_dir::String = abspath("."))

Create a schema for document validation by parsing the string `schema`.

`parent_dir` is the path with respect to which references to local schemas are
resolved.

## Examples

```julia
my_schema = Schema(\"\"\"{
    \"properties\": {
        \"foo\": {},
        \"bar\": {}
    },
    \"required\": [\"foo\"]
}\"\"\")

# Assume there exists `~/schemas/local_file.json`:
my_schema = Schema(
    \"\"\"{
        "\$ref": "local_file.json"
    }\"\"\",
    parent_dir = "~/schemas"
)
```
"""
Schema(schema::String; kwargs...) = Schema(JSON.parse(schema); kwargs...)

Base.show(io::IO, ::Schema) = print(io, "A JSONSchema")
