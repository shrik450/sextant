[
  (object_type_definition (name) @name)
  (object_type_extension (name) @name)
  (input_object_type_definition (name) @name)
  (input_object_type_extension (name) @name)
] @definition.class

[
  (interface_type_definition (name) @name)
  (interface_type_extension (name) @name)
] @definition.interface

[
  (enum_type_definition (name) @name)
  (enum_type_extension (name) @name)
] @definition.enum

[
  (union_type_definition (name) @name)
  (union_type_extension (name) @name)
] @definition.union

[
  (scalar_type_definition (name) @name)
  (scalar_type_extension (name) @name)
] @definition.type

(directive_definition
  (name) @name) @definition.directive

(field_definition
  (name) @name) @definition.field

(input_fields_definition
  (input_value_definition
    (name) @name) @definition.field)

(enum_value_definition
  (enum_value (name) @name)) @definition.constant

(operation_definition
  (name) @name) @definition.function

(fragment_definition
  (fragment_name (name) @name)) @definition.fragment

(named_type
  (name) @name) @reference.type

(fragment_spread
  (fragment_name (name) @name)) @reference.fragment
