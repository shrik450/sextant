(function_definition
  name: (word) @name) @definition.function

(program
  (command
    name: (word) @_command
    .
    argument: (word) @name
    (#eq? @_command "alias")) @definition.function)

(program
  (command
    name: (word) @_command
    .
    argument: (word) @name
    (#eq? @_command "set")
    (#not-match? @name "^-")) @definition.variable)

(program
  (command
    name: (word) @_command
    .
    argument: (word) @_flags
    .
    argument: (word) @name
    (#eq? @_command "set")
    (#match? @_flags "^-")
    (#not-match? @name "^-")) @definition.variable)

(command
  name: (word) @name) @reference.call
