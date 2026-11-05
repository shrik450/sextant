(header
  module: (module) @name) @definition.module

(data_type
  name: (name) @name) @definition.type

(newtype
  name: (name) @name) @definition.type

(type_synonym
  name: (name) @name) @definition.type

(type_family
  name: (name) @name) @definition.type

(class
  name: (name) @name) @definition.interface

(data_constructor
  constructor: [
    (prefix name: (constructor) @name)
    (record name: (constructor) @name)
    (infix operator: (constructor_operator) @name)
  ]) @definition.constructor

(newtype_constructor
  name: (constructor) @name) @definition.constructor

(field
  name: (field_name (variable) @name)) @definition.field

(class_declarations
  (signature
    name: (variable) @name) @definition.method)

(declarations
  (signature
    name: (variable) @name) @definition.function)

(declarations
  .
  [
    (function name: (variable) @name)
    (bind name: (variable) @name)
  ] @definition.function)

(declarations
  (_ !name)
  .
  [
    (function name: (variable) @name)
    (bind name: (variable) @name)
  ] @definition.function)

(declarations
  (_ name: (_) @_previous)
  .
  [
    (function name: (variable) @name)
    (bind name: (variable) @name)
  ] @definition.function
  (#not-eq? @_previous @name))

(apply
  function: (variable) @name) @reference.call
