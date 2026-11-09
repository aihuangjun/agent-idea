; Python 的作用域与定义（syntax.js 的 resolveSemantics 用）。类体是 @scope.isolated：方法里看不见类体里的名字。

[
  (function_definition)
  (lambda)
  (list_comprehension)
  (set_comprehension)
  (dictionary_comprehension)
  (generator_expression)
] @scope
(class_definition) @scope.isolated

; 参数
(parameters (identifier) @def.parameter)
(lambda_parameters (identifier) @def.parameter)
(default_parameter name: (identifier) @def.parameter)
(typed_parameter (identifier) @def.parameter)
(typed_default_parameter name: (identifier) @def.parameter)
(list_splat_pattern (identifier) @def.parameter)
(dictionary_splat_pattern (identifier) @def.parameter)

; 赋值目标（模块里的就是全局变量）
(assignment left: (identifier) @def.local)
(assignment left: (pattern_list (identifier) @def.local))
(assignment left: (tuple_pattern (identifier) @def.local))
(augmented_assignment left: (identifier) @def.local)
(for_statement left: (identifier) @def.local)
(for_statement left: (pattern_list (identifier) @def.local))
(for_statement left: (tuple_pattern (identifier) @def.local))
(for_in_clause left: (identifier) @def.local)
(for_in_clause left: (pattern_list (identifier) @def.local))
(for_in_clause left: (tuple_pattern (identifier) @def.local))
(with_item value: (as_pattern alias: (as_pattern_target (identifier) @def.local)))
(except_clause (as_pattern alias: (as_pattern_target (identifier) @def.local)))
(named_expression name: (identifier) @def.local)

; 类体里的赋值是类属性
(class_definition body: (block (expression_statement (assignment left: (identifier) @def.field))))

(identifier) @ref
