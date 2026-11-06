[
  (function_declaration)
  (init_declaration)
  (deinit_declaration)
  (subscript_declaration)
  (lambda_literal)
  (computed_getter)
  (computed_setter)
  (computed_modify)
  (willset_clause)
  (didset_clause)
  (statements)
  (for_statement)
  (while_statement)
  (repeat_while_statement)
  (if_statement)
  (catch_block)
  (switch_entry)
] @local.scope

(parameter
  name: (simple_identifier) @local.definition.parameter)

(lambda_parameter
  name: (simple_identifier) @local.definition.parameter)

(_
  bound_identifier: (simple_identifier) @local.definition.var)

(property_declaration
  name: (pattern
    (pattern
      (simple_identifier) @local.definition.var)))

(for_statement
  item: (pattern
    (simple_identifier) @local.definition.var))

(for_statement
  item: (pattern
    (pattern
      (simple_identifier) @local.definition.var)))

(computed_setter
  (simple_identifier) @local.definition.parameter)

((function_declaration
  name: (simple_identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

(simple_identifier) @local.reference

(navigation_suffix
  suffix: (simple_identifier) @nonlocal)

(value_argument_label
  (simple_identifier) @nonlocal)

(parameter
  external_name: (simple_identifier) @nonlocal)
