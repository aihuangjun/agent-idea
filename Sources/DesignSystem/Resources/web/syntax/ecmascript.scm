; JavaScript / TypeScript 共用的 IDEA（WebStorm）式补充：叠在官方 highlights.scm 之后，同一个节点这里的模式赢。
; 只能用两种语法都有的节点类型（TypeScript 专有的在 typescript.scm、JSX 在 jsx.scm）。

; 解构出来的名字也要有个捕获，作用域解析才能给它上参数 / 局部 / 全局色
(shorthand_property_identifier) @variable
(shorthand_property_identifier_pattern) @variable
([(shorthand_property_identifier) (shorthand_property_identifier_pattern)] @constant
 (#match? @constant "^[A-Z_][A-Z\\d_]+$"))

(private_property_identifier) @property

; 声明与调用分开着色
(function_declaration name: (identifier) @function.declaration)
(function_expression name: (identifier) @function.declaration)
(generator_function_declaration name: (identifier) @function.declaration)
(generator_function name: (identifier) @function.declaration)
(method_definition name: [(property_identifier) (private_property_identifier)] @function.declaration)
(variable_declarator name: (identifier) @function.declaration value: [(function_expression) (arrow_function)])
(assignment_expression left: (identifier) @function.declaration right: [(function_expression) (arrow_function)])
(pair key: (property_identifier) @function.declaration value: [(function_expression) (arrow_function)])
(assignment_expression
  left: (member_expression property: (property_identifier) @function.declaration)
  right: [(function_expression) (arrow_function)])

(call_expression function: (identifier) @function.call)
(call_expression function: (member_expression property: [(property_identifier) (private_property_identifier)] @function.call))
(new_expression constructor: (identifier) @type)
((call_expression function: (identifier) @function.builtin) (#eq? @function.builtin "require"))

; IDEA 里 this / super 是关键字色
(this) @keyword
(super) @keyword

; 装饰器连同 @ 是注解色
(decorator "@" @attribute)
(decorator (identifier) @attribute)
(decorator (call_expression function: (identifier) @attribute))
(decorator (member_expression property: (property_identifier) @attribute))

(statement_identifier) @label
((comment) @comment.doc (#match? @comment.doc "^/\\*\\*"))
(regex) @string.regex
