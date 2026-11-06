[
  (function_declaration)
  (method_declaration)
  (func_literal)
  (block)
  (for_statement)
  (if_statement)
  (expression_switch_statement)
  (type_switch_statement)
  (select_statement)
  (expression_case)
  (type_case)
  (default_case)
  (communication_case)
] @local.scope

(parameter_declaration
  name: (identifier) @local.definition.parameter)

(variadic_parameter_declaration
  name: (identifier) @local.definition.parameter)

(short_var_declaration
  left: (expression_list
    (identifier) @local.definition.var))

(var_spec
  name: (identifier) @local.definition.var)

(const_spec
  name: (identifier) @local.definition.constant)

(range_clause
  left: (expression_list
    (identifier) @local.definition.var)
  ":=")

(receive_statement
  left: (expression_list
    (identifier) @local.definition.var)
  ":=")

(type_switch_statement
  alias: (expression_list
    (identifier) @local.definition.var))

(identifier) @local.reference

(keyed_element
  .
  (literal_element
    (identifier) @nonlocal))
