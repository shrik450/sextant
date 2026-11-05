(function_def
  (function_command
    (argument_list
      .
      (argument) @name))) @definition.function

(macro_def
  (macro_command
    (argument_list
      .
      (argument) @name))) @definition.macro

(normal_command
  (identifier) @_command
  (argument_list
    .
    (argument) @name)
  (#match? @_command "^(?i)(set|option)$")
  (#not-match? @name "^\\$")) @definition.variable

(normal_command
  (identifier) @_command
  (argument_list
    .
    (argument) @name)
  (#match? @_command "^(?i)(add_executable|add_library|add_custom_target)$")
  (#not-match? @name "^\\$")) @definition.target

(normal_command
  (identifier) @name) @reference.call
