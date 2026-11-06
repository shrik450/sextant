[
  (function_item)
  (closure_expression)
  (block)
  (for_expression)
  (if_expression)
  (while_expression)
  (match_arm)
] @local.scope

(parameter
  pattern: (identifier) @local.definition.parameter)

(closure_parameters
  (identifier) @local.definition.parameter)

(let_declaration
  pattern: (identifier) @local.definition.var)

(let_condition
  pattern: (identifier) @local.definition.var)

(for_expression
  pattern: (identifier) @local.definition.var)

(tuple_pattern
  (identifier) @local.definition.var)

(slice_pattern
  (identifier) @local.definition.var)

(tuple_struct_pattern
  type: (_)
  (identifier) @local.definition.var)

(ref_pattern
  (identifier) @local.definition.var)

(mut_pattern
  (identifier) @local.definition.var)

(reference_pattern
  (identifier) @local.definition.var)

(or_pattern
  (identifier) @local.definition.var)

(captured_pattern
  (identifier) @local.definition.var)

(field_pattern
  name: (shorthand_field_identifier) @local.definition.var)

(field_pattern
  pattern: (identifier) @local.definition.var)

((match_pattern
  (identifier) @local.definition.var)
  (#match? @local.definition.var "^[a-z_]"))

((function_item
  name: (identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

(identifier) @local.reference
