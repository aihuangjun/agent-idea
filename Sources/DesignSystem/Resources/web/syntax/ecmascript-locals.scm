; JavaScript / TypeScript 共用的作用域与定义（syntax.js 的 resolveSemantics 用）。根作用域里的变量是全局变量（WebStorm 的 global variable）。

[
  (statement_block)
  (function_declaration)
  (function_expression)
  (generator_function_declaration)
  (generator_function)
  (arrow_function)
  (method_definition)
  (for_statement)
  (for_in_statement)
  (catch_clause)
  (class_body)
] @scope

(variable_declarator name: (identifier) @def.local)
(variable_declarator name: (object_pattern (shorthand_property_identifier_pattern) @def.local))
(variable_declarator name: (object_pattern (pair_pattern value: (identifier) @def.local)))
(variable_declarator name: (array_pattern (identifier) @def.local))
(for_in_statement left: (identifier) @def.local)
(arrow_function parameter: (identifier) @def.parameter)
(catch_clause parameter: (identifier) @def.parameter)

(identifier) @ref
(shorthand_property_identifier) @ref
