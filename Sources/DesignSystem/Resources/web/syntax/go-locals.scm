; Go 的作用域与定义（syntax.js 的 resolveSemantics 用）。包级的 var 是全局变量，const 一律按常量画。

[
  (function_declaration)
  (method_declaration)
  (func_literal)
  (block)
  (for_statement)
  (if_statement)
  (expression_switch_statement)
  (type_switch_statement)
  (select_statement)
  (expression_case)
  (type_case)
  (communication_case)
  (default_case)
] @scope

(parameter_declaration name: (identifier) @def.parameter)
(variadic_parameter_declaration name: (identifier) @def.parameter)

(short_var_declaration left: (expression_list (identifier) @def.local))
(var_spec name: (identifier) @def.local)
(range_clause left: (expression_list (identifier) @def.local))
(type_switch_statement alias: (expression_list (identifier) @def.local))
(receive_statement left: (expression_list (identifier) @def.local))
(const_spec name: (identifier) @def.static)

(type_parameter_declaration name: (identifier) @def.typeparam)

(identifier) @ref
(type_identifier) @ref
