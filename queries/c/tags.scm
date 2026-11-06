(function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function

(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function

(function_definition declarator: (pointer_declarator declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name)))) @definition.function

(declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function

(declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function

(declaration declarator: (pointer_declarator declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name)))) @definition.function

(struct_specifier name: (type_identifier) @name body: (_)) @definition.class

(union_specifier name: (type_identifier) @name body: (_)) @definition.class

(enum_specifier name: (type_identifier) @name body: (_)) @definition.enum

(type_definition declarator: (type_identifier) @name) @definition.type
