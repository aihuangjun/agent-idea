; Java 的 IDEA 式补充：叠在官方 highlights.scm 之后，同一个节点这里的模式赢。

; 声明（方法 / 构造器）与调用分开着色
(method_declaration name: (identifier) @function.declaration)
(constructor_declaration name: (identifier) @function.declaration)
(compact_constructor_declaration name: (identifier) @function.declaration)
(method_invocation name: (identifier) @function.call)
(method_reference (identifier) @function.call .)

; 成员访问：obj.field / this.field
(field_access field: (identifier) @property)

; IDEA 里 this / super 是关键字色
(this) @keyword
(super) @keyword

; 注解连同 @ 一起是注解色（含 @a.b.C 这种全名）
(annotation "@" @attribute name: (_) @attribute)
(marker_annotation "@" @attribute name: (_) @attribute)
(annotation_type_declaration "@interface" @keyword)

; 类型参数声明 <T>
(type_parameter (type_identifier) @type.parameter)

; 标签
(labeled_statement (identifier) @label)
(break_statement (identifier) @label)
(continue_statement (identifier) @label)

; 文档注释 /** */
((block_comment) @comment.doc (#match? @comment.doc "^/\\*\\*"))

[
  "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>=" ">>>="
  "+" "-" "*" "/" "%" "++" "--" "!" "~" "&&" "||" "&" "|" "^" "<<" ">>" ">>>"
  "==" "!=" "<" "<=" ">" ">=" "?" ":" "->" "::"
] @operator
