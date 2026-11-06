[
  (function_definition)
  (lambda_expression)
  (compound_statement)
  (for_statement)
  (for_range_loop)
  (if_statement)
  (while_statement)
  (switch_statement)
  (catch_clause)
] @local.scope

(parameter_declaration
  declarator: (identifier) @local.definition.parameter)

(optional_parameter_declaration
  declarator: (identifier) @local.definition.parameter)

(init_declarator
  declarator: (identifier) @local.definition.var)

(declaration
  declarator: (identifier) @local.definition.var)

(pointer_declarator
  declarator: (identifier) @local.definition.var)

(reference_declarator
  (identifier) @local.definition.var)

(array_declarator
  declarator: (identifier) @local.definition.var)

(structured_binding_declarator
  (identifier) @local.definition.var)

(for_range_loop
  declarator: (identifier) @local.definition.var)

(identifier) @local.reference
