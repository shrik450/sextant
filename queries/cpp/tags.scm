(namespace_definition name: (namespace_identifier) @name) @definition.module

(function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function

(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function

(function_definition declarator: (reference_declarator (function_declarator declarator: (identifier) @name))) @definition.function

(declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function

(declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function

(declaration declarator: (reference_declarator (function_declarator declarator: (identifier) @name))) @definition.function

(field_declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function

(field_declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function

(field_declaration declarator: (reference_declarator (function_declarator declarator: (identifier) @name))) @definition.function

(function_definition declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name)) @definition.method

(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(function_definition declarator: (reference_declarator (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(declaration declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name)) @definition.method

(declaration declarator: (pointer_declarator declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(declaration declarator: (reference_declarator (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(field_declaration declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name)) @definition.method

(field_declaration declarator: (pointer_declarator declarator: (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(field_declaration declarator: (reference_declarator (function_declarator declarator: [(field_identifier) (destructor_name) (operator_name)] @name))) @definition.method

(function_definition declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))) @definition.method

(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(function_definition declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(declaration declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))) @definition.method

(declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(declaration declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(field_declaration declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))) @definition.method

(field_declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(field_declaration declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(function_definition declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(function_definition declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(declaration declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(declaration declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(field_declaration declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name)))) @definition.method

(field_declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(field_declaration declarator: (reference_declarator (function_declarator declarator: (qualified_identifier name: (qualified_identifier name: [(identifier) (destructor_name) (operator_name)] @name))))) @definition.method

(struct_specifier name: (type_identifier) @name body: (_)) @definition.class

(union_specifier name: (type_identifier) @name body: (_)) @definition.class

(enum_specifier name: (type_identifier) @name body: (_)) @definition.enum

(type_definition declarator: (type_identifier) @name) @definition.type

(class_specifier name: (type_identifier) @name body: (_)) @definition.class

(alias_declaration name: (type_identifier) @name) @definition.type
