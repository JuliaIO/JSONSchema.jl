# Copyright (c) 2018: fredo-dedup and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module JSONSchema

import Downloads
import JSON
import URIs

export Schema, validate

include("schema.jl")
include("validation.jl")

export diagnose
function diagnose(x, schema)
    Base.depwarn(
        "`diagnose(x, schema)` is deprecated. Use `validate(schema, x)` instead.",
        :diagnose,
    )
    ret = validate(schema, x)
    if ret !== nothing
        return sprint(show, ret)
    end
    return
end

end
