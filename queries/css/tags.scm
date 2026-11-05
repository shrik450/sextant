(rule_set
  (selectors
    (class_selector (class_name) @name))) @definition.class

(rule_set
  (selectors
    (_ (class_selector (class_name) @name)))) @definition.class

(rule_set
  (selectors
    (_ (_ (class_selector (class_name) @name))))) @definition.class

(rule_set
  (selectors
    (_ (_ (_ (class_selector (class_name) @name)))))) @definition.class

(rule_set
  (selectors
    (_ (_ (_ (_ (class_selector (class_name) @name))))))) @definition.class

(rule_set
  (selectors
    (id_selector (id_name) @name))) @definition.id

(rule_set
  (selectors
    (_ (id_selector (id_name) @name)))) @definition.id

(rule_set
  (selectors
    (_ (_ (id_selector (id_name) @name))))) @definition.id

(rule_set
  (selectors
    (_ (_ (_ (id_selector (id_name) @name)))))) @definition.id

(rule_set
  (selectors
    (_ (_ (_ (_ (id_selector (id_name) @name))))))) @definition.id

(declaration
  (property_name) @name
  (#match? @name "^--")) @definition.variable

(keyframes_statement
  (keyframes_name) @name) @definition.keyframes
