(module_attribute
  name: (atom) @name) @definition.module

(source_file
  .
  (fun_decl
    .
    (function_clause
      name: (atom) @name)) @definition.function)

((_ !clause)
  .
  (fun_decl
    .
    (function_clause
      name: (atom) @name)) @definition.function)

((fun_decl
  .
  (function_clause
    name: (atom) @_previous))
  .
  (fun_decl
    .
    (function_clause
      name: (atom) @name)) @definition.function
  (#not-eq? @_previous @name))

(record_decl
  name: (atom) @name) @definition.struct

(type_alias
  name: (type_name name: (atom) @name)) @definition.type

(opaque
  name: (type_name name: (atom) @name)) @definition.type

(pp_define
  lhs: (macro_lhs name: (_) @name)) @definition.macro

(call
  expr: (atom) @name) @reference.call

(internal_fun
  fun: (atom) @name) @reference.call

(macro_call_expr
  name: (_) @name) @reference.macro
