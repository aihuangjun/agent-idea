; Java 的作用域与定义（syntax.js 的 resolveSemantics 用）。
; @scope 作用域；@def.parameter / @def.local / @def.field / @def.static / @def.typeparam 定义；@ref 引用。
; 同一个节点后面的定义模式赢：static 字段先被「字段」匹配、再被「静态」匹配。

[
  (class_body)
  (interface_body)
  (enum_body)
  (annotation_type_body)
  (record_declaration)
  (method_declaration)
  (constructor_declaration)
  (compact_constructor_declaration)
  (lambda_expression)
  (block)
  (for_statement)
  (enhanced_for_statement)
  (catch_clause)
  (try_with_resources_statement)
  (switch_block_statement_group)
  (switch_rule)
] @scope

(formal_parameter name: (identifier) @def.parameter)
(spread_parameter (variable_declarator name: (identifier) @def.parameter))
(lambda_expression parameters: (identifier) @def.parameter)
(inferred_parameters (identifier) @def.parameter)
(catch_formal_parameter name: (identifier) @def.parameter)

(local_variable_declaration declarator: (variable_declarator name: (identifier) @def.local))
(enhanced_for_statement name: (identifier) @def.local)
(resource name: (identifier) @def.local)
(instanceof_expression name: (identifier) @def.local)
(record_pattern_component (identifier) @def.local)

(field_declaration declarator: (variable_declarator name: (identifier) @def.field))
(record_declaration parameters: (formal_parameters (formal_parameter name: (identifier) @def.field)))
(field_declaration (modifiers "static") declarator: (variable_declarator name: (identifier) @def.static))
(constant_declaration declarator: (variable_declarator name: (identifier) @def.static))
(enum_constant name: (identifier) @def.static)

(type_parameter (type_identifier) @def.typeparam)

(identifier) @ref
(type_identifier) @ref
