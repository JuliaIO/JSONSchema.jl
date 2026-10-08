# Changelog

## 1.6.0 release candidate

- Generate JSON Schema from Julia types with `schema`, including field metadata,
  defaults, and nested definitions.
- Validate integer-valued floating-point inputs, `AbstractString` strings, and
  `AbstractVector` arrays consistently with their concrete equivalents.
- Resolve JSON pointers and array indices strictly, and keep validation of JSON
  nulls, booleans, references, and array equality consistent with the schema.
- Reduce temporary allocations during object and array validation.

The package version is already 1.6.0. Registration and the corresponding tag
remain publication steps after this candidate passes release validation.
