; Python 的 IDEA（PyCharm）式补充：叠在官方 highlights.scm 之后，同一个节点这里的模式赢。

(attribute attribute: (identifier) @property)

; 声明与调用分开着色
(function_definition name: (identifier) @function.declaration)
(class_definition name: (identifier) @type)
(call function: (identifier) @function.call)
(call function: (attribute attribute: (identifier) @function.call))

; 内建函数（写在调用之后才盖得住）
((call function: (identifier) @function.builtin)
 (#match? @function.builtin "^(abs|all|any|ascii|bin|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|complex|delattr|dict|dir|divmod|enumerate|eval|exec|filter|float|format|frozenset|getattr|globals|hasattr|hash|help|hex|id|input|int|isinstance|issubclass|iter|len|list|locals|map|max|memoryview|min|next|object|oct|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip|__import__)$"))
; 类型注解里的内建类型：PyCharm 按内建名的颜色画（不是关键字色）。只认注解位置——调用里的 str(x) 走上面的内建函数
((type (identifier) @builtin)
 (#match? @builtin "^(int|float|complex|str|bool|bytes|bytearray|list|dict|set|frozenset|tuple|object|type|None)$"))
((type (generic_type (identifier) @builtin))
 (#match? @builtin "^(list|dict|set|frozenset|tuple|type)$"))

; self / cls（PyCharm 的 self parameter）
((identifier) @variable.builtin.self (#match? @variable.builtin.self "^(self|cls)$"))

; 关键字参数的名字：PyCharm 按参数色画
(keyword_argument name: (identifier) @variable.parameter)

; 装饰器整个是注解色（连同 @ 和 app.route 这种限定名）
(decorator) @attribute
(decorator "@" @attribute)
(decorator (attribute object: (identifier) @attribute))
(decorator (call function: (attribute object: (identifier) @attribute)))
(decorator (identifier) @attribute)
(decorator (attribute attribute: (identifier) @attribute))
(decorator (call function: (identifier) @attribute))
(decorator (call function: (attribute attribute: (identifier) @attribute)))
; 官方查询把整个装饰器画成函数色：参数部分退回正文色（里面的字符串、名字各自再上色）
(decorator (call arguments: (argument_list) @punctuation))

; 文档字符串
(module . (expression_statement (string) @comment.doc))
(class_definition body: (block . (expression_statement (string) @comment.doc)))
(function_definition body: (block . (expression_statement (string) @comment.doc)))

[
  "=" "+=" "-=" "*=" "/=" "//=" "%=" "**=" "@=" "&=" "|=" "^=" ">>=" "<<=" ":="
  "+" "-" "*" "/" "//" "%" "**" "&" "|" "^" "~" "<<" ">>" "==" "!=" "<" "<=" ">" ">=" "<>" "->"
] @operator

["in" "not" "and" "or" "is"] @keyword
