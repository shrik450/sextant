[
  (block)
  (for_statement)
  (function_declaration)
  (function_definition)
] @local.scope

(variable_declaration
  (assignment_statement
    (variable_list
      name: (identifier) @local.definition.var)))

(variable_declaration
  (variable_list
    name: (identifier) @local.definition.var))

(for_generic_clause
  (variable_list
    name: (identifier) @local.definition.var))

(for_numeric_clause
  name: (identifier) @local.definition.var)

(parameters
  name: (identifier) @local.definition.parameter)

((function_declaration
  "local"
  name: (identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

(identifier) @local.reference

(dot_index_expression
  field: (identifier) @nonlocal)

(method_index_expression
  method: (identifier) @nonlocal)

(field
  name: (identifier) @nonlocal)
