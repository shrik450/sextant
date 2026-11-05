(function_definition
  name: (word) @name) @definition.function

(program
  (variable_assignment
    name: (variable_name) @name) @definition.variable)

(program
  (declaration_command
    (variable_assignment
      name: (variable_name) @name)) @definition.variable)

(program
  (declaration_command
    (variable_name) @name) @definition.variable)

(command
  name: (command_name (word) @name)) @reference.call
