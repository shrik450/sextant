(function_definition
  (function_declaration
    name: (_) @name)) @definition.function

(script_file
  (let_statement
    .
    [(identifier) (scoped_identifier)] @name) @definition.variable)

(command_statement
  name: (command_name) @name) @definition.function

(call_expression
  function: (_) @name) @reference.call
