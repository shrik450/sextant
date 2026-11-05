(package
  (full_ident) @name) @definition.module

(message
  (message_name (identifier) @name)) @definition.class

(enum
  (enum_name (identifier) @name)) @definition.enum

(service
  (service_name (identifier) @name)) @definition.interface

(rpc
  (rpc_name (identifier) @name)) @definition.method

(field
  (identifier) @name) @definition.field

(map_field
  (identifier) @name) @definition.field

(oneof
  (identifier) @name) @definition.field

(oneof_field
  (identifier) @name) @definition.field

(enum_field
  (identifier) @name) @definition.constant

(message_or_enum_type
  (identifier) @name .) @reference.type
