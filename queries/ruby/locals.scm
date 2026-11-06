((method) @local.scope
  (#set! local.scope-inherits false))

((singleton_method) @local.scope
  (#set! local.scope-inherits false))

[
  (lambda)
  (block)
  (do_block)
] @local.scope

(block_parameter (identifier) @local.definition.parameter)
(block_parameters (identifier) @local.definition.parameter)
(destructured_parameter (identifier) @local.definition.parameter)
(hash_splat_parameter (identifier) @local.definition.parameter)
(lambda_parameters (identifier) @local.definition.parameter)
(method_parameters (identifier) @local.definition.parameter)
(splat_parameter (identifier) @local.definition.parameter)
(keyword_parameter name: (identifier) @local.definition.parameter)
(optional_parameter name: (identifier) @local.definition.parameter)

((assignment
  left: (identifier) @local.definition.var)
  (#set! local.definition-scope "nearest"))

((operator_assignment
  left: (identifier) @local.definition.var)
  (#set! local.definition-scope "nearest"))

((left_assignment_list
  (identifier) @local.definition.var)
  (#set! local.definition-scope "nearest"))

((rest_assignment
  (identifier) @local.definition.var)
  (#set! local.definition-scope "nearest"))

((destructured_left_assignment
  (identifier) @local.definition.var)
  (#set! local.definition-scope "nearest"))

(identifier) @local.reference

(call
  method: (identifier) @nonlocal)
