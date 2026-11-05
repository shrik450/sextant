(list
  .
  (symbol) @_keyword
  .
  (list
    .
    (symbol) @name)
  (#any-of? @_keyword "define" "define*" "define-public" "define-inline")) @definition.function

(list
  .
  (symbol) @_keyword
  .
  (symbol) @name
  (#any-of? @_keyword "define" "define-public" "define-values")) @definition.variable

(list
  .
  (symbol) @_keyword
  .
  [
    (symbol) @name
    (list . (symbol) @name)
  ]
  (#any-of? @_keyword "define-syntax" "define-macro" "define-syntax-rule")) @definition.macro

(list
  .
  (symbol) @_keyword
  .
  (symbol) @name
  (#eq? @_keyword "define-record-type")) @definition.struct

(list
  .
  (symbol) @_keyword
  .
  (list) @name
  (#any-of? @_keyword "define-module" "define-library")) @definition.module

(list
  .
  (symbol) @name
  (#not-any-of? @name "define" "define*" "define-public" "define-inline" "define-values" "define-syntax" "define-macro" "define-syntax-rule" "define-record-type" "define-module" "define-library")) @reference.call
