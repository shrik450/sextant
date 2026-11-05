(module_definition
  name: (identifier) @name) @definition.module

(function_definition
  (signature
    [
      (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
      (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
      (where_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
      (where_expression . (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)])))
    ])) @definition.function

(assignment
  .
  [
    (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
    (where_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
  ]) @definition.function

(macro_definition
  (signature
    (call_expression . (identifier) @name))) @definition.macro

(struct_definition
  (type_head
    [
      (identifier) @name
      (parametrized_type_expression . (identifier) @name)
      (binary_expression . [(identifier) @name (parametrized_type_expression . (identifier) @name)])
    ])) @definition.struct

(abstract_definition
  (type_head
    [
      (identifier) @name
      (parametrized_type_expression . (identifier) @name)
      (binary_expression . [(identifier) @name (parametrized_type_expression . (identifier) @name)])
    ])) @definition.type

(primitive_definition
  (type_head
    [
      (identifier) @name
      (binary_expression . (identifier) @name)
    ])) @definition.type

(const_statement
  (assignment . (identifier) @name)) @definition.constant

(call_expression
  .
  [(identifier) @name (field_expression (identifier) @name .)]) @reference.call

(macrocall_expression
  (macro_identifier (identifier) @name)) @reference.call
