; C / C++ 的作用域与定义（syntax.js 的 resolveSemantics 用）。文件与命名空间里的变量是全局变量（命名空间的
; declaration_list 不算作用域）；类体是作用域，类里内联的方法能把成员名解析成字段。声明符可能套着指针 / 引用 / 数组。

[
  (function_definition)
  (compound_statement)
  (for_statement)
  (for_range_loop)
  (lambda_expression)
  (catch_clause)
  (field_declaration_list)
  (if_statement)
  (while_statement)
  (switch_statement)
] @scope

(parameter_declaration declarator: [
  (identifier) @def.parameter
  (pointer_declarator declarator: (identifier) @def.parameter)
  (pointer_declarator declarator: (pointer_declarator declarator: (identifier) @def.parameter))
  (reference_declarator (identifier) @def.parameter)
  (array_declarator declarator: (identifier) @def.parameter)
])
(optional_parameter_declaration declarator: [
  (identifier) @def.parameter
  (pointer_declarator declarator: (identifier) @def.parameter)
  (reference_declarator (identifier) @def.parameter)
])

(declaration declarator: [
  (identifier) @def.local
  (init_declarator declarator: (identifier) @def.local)
  (init_declarator declarator: (pointer_declarator declarator: (identifier) @def.local))
  (init_declarator declarator: (reference_declarator (identifier) @def.local))
  (init_declarator declarator: (array_declarator declarator: (identifier) @def.local))
  (pointer_declarator declarator: (identifier) @def.local)
  (array_declarator declarator: (identifier) @def.local)
])
(for_range_loop declarator: (identifier) @def.local)
(for_range_loop declarator: (reference_declarator (identifier) @def.local))
(structured_binding_declarator (identifier) @def.local)

(field_declaration declarator: [
  (field_identifier) @def.field
  (pointer_declarator declarator: (field_identifier) @def.field)
  (array_declarator declarator: (field_identifier) @def.field)
])
((field_declaration (storage_class_specifier) @_storage declarator: (field_identifier) @def.static)
 (#eq? @_storage "static"))
(enumerator name: (identifier) @def.static)

(template_parameter_list (type_parameter_declaration (type_identifier) @def.typeparam))

(identifier) @ref
(type_identifier) @ref
