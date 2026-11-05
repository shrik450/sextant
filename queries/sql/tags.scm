(create_table
  (object_reference
    name: (identifier) @name)) @definition.table

(create_view
  (object_reference
    name: (identifier) @name)) @definition.view

(create_materialized_view
  (object_reference
    name: (identifier) @name)) @definition.view

(create_function
  (object_reference
    name: (identifier) @name)) @definition.function

(create_type
  (object_reference
    name: (identifier) @name)) @definition.type

(create_index
  column: (identifier) @name) @definition.index

(column_definition
  name: (identifier) @name) @definition.field

(relation
  (object_reference
    name: (identifier) @name)) @reference.table

(invocation
  (object_reference
    name: (identifier) @name)) @reference.call
