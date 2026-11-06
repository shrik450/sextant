[
  (statement_block)
  (function_declaration)
  (generator_function_declaration)
  (function_expression)
  (generator_function)
  (arrow_function)
  (method_definition)
  (for_statement)
  (for_in_statement)
  (catch_clause)
] @local.scope

(formal_parameters
  (identifier) @local.definition.parameter)

(arrow_function
  parameter: (identifier) @local.definition.parameter)

(variable_declarator
  name: (identifier) @local.definition.var)

(object_pattern
  (shorthand_property_identifier_pattern) @local.definition.var)

(object_assignment_pattern
  left: (shorthand_property_identifier_pattern) @local.definition.var)

(pair_pattern
  value: (identifier) @local.definition.var)

(array_pattern
  (identifier) @local.definition.var)

(rest_pattern
  (identifier) @local.definition.var)

(assignment_pattern
  left: (identifier) @local.definition.var)

(for_in_statement
  kind: _
  left: (identifier) @local.definition.var)

(catch_clause
  parameter: (identifier) @local.definition.var)

((function_declaration
  name: (identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

((generator_function_declaration
  name: (identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

(identifier) @local.reference

(shorthand_property_identifier) @local.reference
