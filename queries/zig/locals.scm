[
  (function_declaration)
  (function_signature)
  (block)
  (for_statement)
  (while_statement)
  (if_statement)
  (else_clause)
  (switch_case)
  (catch_expression)
  (errdefer_statement)
  (labeled_statement)
] @local.scope

(parameter
  name: (identifier) @local.definition.parameter)

(variable_declaration
  ["const" "var"]
  .
  (identifier) @local.definition.var)

(payload
  (identifier) @local.definition.var)

(block_label
  (identifier) @local.definition.label)

(identifier) @local.reference

(field_expression
  member: (identifier) @nonlocal)

(container_field
  name: (identifier) @nonlocal)
