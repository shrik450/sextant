(from_instruction
  as: (image_alias) @name) @definition.target

(arg_instruction
  name: (_) @name) @definition.variable

(env_instruction
  (env_pair
    name: (_) @name)) @definition.variable
