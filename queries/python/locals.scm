[
  (function_definition)
  (lambda)
  (list_comprehension)
  (set_comprehension)
  (dictionary_comprehension)
  (generator_expression)
] @local.scope

(parameters
  (identifier) @local.definition.parameter)

(lambda_parameters
  (identifier) @local.definition.parameter)

(default_parameter
  name: (identifier) @local.definition.parameter)

(typed_parameter
  (identifier) @local.definition.parameter)

(typed_default_parameter
  name: (identifier) @local.definition.parameter)

(list_splat_pattern
  (identifier) @local.definition.parameter)

(dictionary_splat_pattern
  (identifier) @local.definition.parameter)

(assignment
  left: (identifier) @local.definition.var)

(pattern_list
  (identifier) @local.definition.var)

(tuple_pattern
  (identifier) @local.definition.var)

(list_pattern
  (identifier) @local.definition.var)

(for_statement
  left: (identifier) @local.definition.var)

(for_in_clause
  left: (identifier) @local.definition.var)

(as_pattern_target
  (identifier) @local.definition.var)

(named_expression
  name: (identifier) @local.definition.var)

((function_definition
  name: (identifier) @local.definition.function)
  (#set! local.definition-scope "parent"))

((class_definition
  name: (identifier) @local.definition.type))

(identifier) @local.reference

(attribute
  attribute: (identifier) @nonlocal)

(keyword_argument
  name: (identifier) @nonlocal)

(global_statement
  (identifier) @nonlocal)
