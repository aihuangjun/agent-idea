; Go 的 IDEA（GoLand）式补充：叠在官方 highlights.scm 之后，同一个节点这里的模式赢。

; 声明与调用分开着色
(function_declaration name: (identifier) @function.declaration)
(method_declaration name: (field_identifier) @function.declaration)
(method_elem name: (field_identifier) @function.declaration)
(call_expression function: (identifier) @function.call)
(call_expression function: (selector_expression field: (field_identifier) @function.call))
(call_expression function: (parenthesized_expression (identifier) @function.call))

; 内建函数（写在调用之后才盖得住）
((call_expression function: (identifier) @function.builtin)
 (#match? @function.builtin "^(append|cap|clear|close|complex|copy|delete|imag|len|make|max|min|new|panic|print|println|real|recover)$"))

; 内建类型：GoLand 按关键字色画
((type_identifier) @type.builtin
 (#match? @type.builtin "^(any|bool|byte|comparable|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr)$"))

(type_parameter_declaration name: (identifier) @type.parameter)
(package_identifier) @module
(label_name) @label

[
  "=" ":=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>=" "&^="
  "+" "-" "*" "/" "%" "&" "|" "^" "<<" ">>" "&^" "&&" "||" "!" "<-" "++" "--"
  "==" "!=" "<" "<=" ">" ">=" "..."
] @operator
