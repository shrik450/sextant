[
  (function_definition)
  (compound_statement)
  (for_statement)
] @local.scope

(parameter_declaration
  declarator: (identifier) @local.definition.parameter)

(init_declarator
  declarator: (identifier) @local.definition.var)

(declaration
  declarator: (identifier) @local.definition.var)

(pointer_declarator
  declarator: (identifier) @local.definition.var)

(array_declarator
  declarator: (identifier) @local.definition.var)

(identifier) @local.reference
