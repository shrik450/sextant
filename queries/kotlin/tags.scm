(class_declaration
  "interface"
  (type_identifier) @name) @definition.interface

(class_declaration
  "enum"
  (type_identifier) @name) @definition.enum

(class_declaration
  "class"
  (type_identifier) @name) @definition.class

(object_declaration
  (type_identifier) @name) @definition.object

(companion_object
  (type_identifier) @name) @definition.object

(type_alias
  (type_identifier) @name) @definition.type

(source_file
  (function_declaration
    (simple_identifier) @name) @definition.function)

(class_body
  (function_declaration
    (simple_identifier) @name) @definition.method)

(source_file
  (property_declaration
    (variable_declaration
      (simple_identifier) @name)) @definition.property)

(class_body
  (property_declaration
    (variable_declaration
      (simple_identifier) @name)) @definition.property)

(class_parameter
  (binding_pattern_kind)
  (simple_identifier) @name) @definition.property

(enum_entry
  (simple_identifier) @name) @definition.constant

(call_expression
  [
    (simple_identifier) @name
    (navigation_expression
      (navigation_suffix (simple_identifier) @name) .)
  ]) @reference.call
