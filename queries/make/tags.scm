(rule
  (targets
    (word) @name)
  (#not-match? @name "^\\.")) @definition.target

(variable_assignment
  name: (word) @name) @definition.variable

(define_directive
  name: (word) @name) @definition.macro

(prerequisites
  (word) @name) @reference.call
