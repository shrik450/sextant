(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#any-of? @_keyword "defn" "defn-")) @definition.function

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#any-of? @_keyword "defmacro")) @definition.macro

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#any-of? @_keyword "def" "defonce")) @definition.variable

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#eq? @_keyword "defmulti")) @definition.function

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#any-of? @_keyword "defprotocol" "definterface")) @definition.interface

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#any-of? @_keyword "defrecord" "deftype" "defstruct")) @definition.class

(list_lit
  .
  (sym_lit name: (sym_name) @_keyword)
  .
  (sym_lit name: (sym_name) @name)
  (#eq? @_keyword "ns")) @definition.module

(list_lit
  .
  (sym_lit name: (sym_name) @name)
  (#not-any-of? @name "def" "defonce" "defn" "defn-" "defmacro" "defmulti" "defmethod" "defprotocol" "definterface" "defrecord" "deftype" "defstruct" "ns")) @reference.call
