(recipe
  (recipe_header
    name: (identifier) @name)) @definition.function

(alias
  left: (identifier) @name) @definition.function

(assignment
  left: (identifier) @name) @definition.variable

(module
  name: (identifier) @name) @definition.module

(dependency
  name: (identifier) @name) @reference.call

(alias
  right: (identifier) @name) @reference.call
