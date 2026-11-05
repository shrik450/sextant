(function_declaration
  name: (identifier) @name
  type: (builtin_type) @_type
  (#eq? @_type "type")) @definition.type

(source_file
  (function_declaration
    name: (identifier) @name
    type: (_) @_type
    (#not-eq? @_type "type")) @definition.function)

(struct_declaration
  (function_declaration
    name: (identifier) @name
    type: (_) @_type
    (#not-eq? @_type "type")) @definition.method)

(union_declaration
  (function_declaration
    name: (identifier) @name
    type: (_) @_type
    (#not-eq? @_type "type")) @definition.method)

(enum_declaration
  (function_declaration
    name: (identifier) @name
    type: (_) @_type
    (#not-eq? @_type "type")) @definition.method)

(opaque_declaration
  (function_declaration
    name: (identifier) @name
    type: (_) @_type
    (#not-eq? @_type "type")) @definition.method)

(variable_declaration
  .
  (identifier) @name
  [(struct_declaration) (opaque_declaration)]) @definition.struct

(variable_declaration
  .
  (identifier) @name
  [(enum_declaration) (error_set_declaration)]) @definition.enum

(variable_declaration
  .
  (identifier) @name
  (union_declaration)) @definition.union

(source_file
  (variable_declaration
    "const"
    .
    (identifier) @name
    (_) @_value
    .
    (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")) @definition.constant)

(struct_declaration
  (variable_declaration
    "const"
    .
    (identifier) @name
    (_) @_value
    .
    (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")) @definition.constant)

(union_declaration
  (variable_declaration
    "const"
    .
    (identifier) @name
    (_) @_value
    .
    (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")) @definition.constant)

(enum_declaration
  (variable_declaration
    "const"
    .
    (identifier) @name
    (_) @_value
    .
    (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")) @definition.constant)

(opaque_declaration
  (variable_declaration
    "const"
    .
    (identifier) @name
    (_) @_value
    .
    (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")) @definition.constant)

(source_file
  (variable_declaration
    "var"
    .
    (identifier) @name) @definition.variable)

(struct_declaration
  (variable_declaration
    "var"
    .
    (identifier) @name) @definition.variable)

(container_field
  name: (identifier) @name
  (#match? @name ".")) @definition.field

(test_declaration
  [
    (string (string_content) @name)
    (identifier) @name
  ]) @definition.test

(call_expression
  function: [
    (identifier) @name
    (field_expression member: (identifier) @name)
  ]) @reference.call
