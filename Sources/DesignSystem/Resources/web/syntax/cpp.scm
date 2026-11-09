; C / C++ 的 IDEA（CLion）式补充：叠在官方 C、C++ 两份 highlights.scm 之后，同一个节点这里的模式赢。

(field_expression field: (field_identifier) @property)
(field_identifier) @property

; 声明与调用分开着色
(function_declarator declarator: (identifier) @function.declaration)
(function_declarator declarator: (field_identifier) @function.declaration)
(function_declarator declarator: (qualified_identifier name: (identifier) @function.declaration))
(function_declarator declarator: (qualified_identifier name: (qualified_identifier name: (identifier) @function.declaration)))
(function_declarator declarator: (destructor_name (identifier) @function.declaration))
(function_declarator declarator: (operator_name) @function.declaration)
(call_expression function: (identifier) @function.call)
(call_expression function: (field_expression field: (field_identifier) @function.call))
(call_expression function: (qualified_identifier name: (identifier) @function.call))
(call_expression function: (template_function name: (identifier) @function.call))
(call_expression function: (qualified_identifier name: (template_function name: (identifier) @function.call)))
(call_expression function: (field_expression field: (template_method name: (field_identifier) @function.call)))

; 宏
(preproc_def name: (identifier) @constant.macro)
(preproc_function_def name: (identifier) @function.macro)

; IDEA 里 this 是关键字色；基本类型也是
(this) @keyword
(primitive_type) @type.builtin
(sized_type_specifier) @type.builtin
(auto) @type.builtin

(template_parameter_list (type_parameter_declaration (type_identifier) @type.parameter))
(namespace_identifier) @namespace
(statement_identifier) @label
(escape_sequence) @string.escape
(char_literal) @string
((comment) @comment.doc (#match? @comment.doc "^(/\\*\\*|///)"))

[
  "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
  "+" "-" "*" "/" "%" "++" "--" "!" "~" "&&" "||" "&" "|" "^" "<<" ">>"
  "==" "!=" "<" "<=" ">" ">=" "?" "->" "::" "<=>"
] @operator
