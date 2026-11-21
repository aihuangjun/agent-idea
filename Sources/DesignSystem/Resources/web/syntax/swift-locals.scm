; Swift 的定义导航。函数体和 statements 也覆盖 if / for / closure 内部的局部变量。
[
  (class_body)
  (protocol_body)
  (enum_class_body)
  (function_declaration)
  (init_declaration)
  (lambda_literal)
  (statements)
] @scope

(parameter name: (simple_identifier) @def.parameter)
(property_declaration name: (pattern bound_identifier: (simple_identifier) @def.local))
(simple_identifier) @ref
(type_identifier) @ref
