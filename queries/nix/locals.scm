[
  (let_expression)
  (rec_attrset_expression)
  (function_expression)
] @local.scope

(let_expression
  (binding_set
    binding: (binding
      attrpath: (attrpath
        .
        attr: (identifier) @local.definition.var))))

(rec_attrset_expression
  (binding_set
    binding: (binding
      attrpath: (attrpath
        .
        attr: (identifier) @local.definition.var))))

(let_expression
  (binding_set
    [
      (inherit (inherited_attrs attr: (identifier) @local.definition.var))
      (inherit_from (inherited_attrs attr: (identifier) @local.definition.var))
    ]))

(formal
  name: (identifier) @local.definition.parameter)

(function_expression
  universal: (identifier) @local.definition.parameter)

(variable_expression
  name: (identifier) @local.reference)

(inherit
  (inherited_attrs
    attr: (identifier) @local.reference))
