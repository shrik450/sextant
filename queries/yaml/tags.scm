(block_mapping_pair
  key: (flow_node
    [
      (plain_scalar (string_scalar) @name)
      (double_quote_scalar) @name
      (single_quote_scalar) @name
    ])) @definition.property

(flow_pair
  key: (flow_node
    [
      (plain_scalar (string_scalar) @name)
      (double_quote_scalar) @name
      (single_quote_scalar) @name
    ])) @definition.property

(anchor
  (anchor_name) @name) @definition.anchor

(alias
  (alias_name) @name) @reference.anchor
