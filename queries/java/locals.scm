[
  (method_declaration)
  (constructor_declaration)
  (lambda_expression)
  (block)
  (for_statement)
  (enhanced_for_statement)
  (catch_clause)
  (try_with_resources_statement)
] @local.scope

(formal_parameter
  name: (identifier) @local.definition.parameter)

(variable_declarator
  name: (identifier) @local.definition.var)

(enhanced_for_statement
  name: (identifier) @local.definition.var)

(catch_formal_parameter
  name: (identifier) @local.definition.var)

(resource
  name: (identifier) @local.definition.var)

(lambda_expression
  parameters: (identifier) @local.definition.parameter)

(inferred_parameters
  (identifier) @local.definition.parameter)

(identifier) @local.reference

(field_access
  field: (identifier) @nonlocal)

(method_invocation
  name: (identifier) @nonlocal)
