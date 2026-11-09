; TypeScript 专有的补充（叠在 ecmascript.scm 之后）。

(function_signature name: (identifier) @function.declaration)
(method_signature name: (property_identifier) @function.declaration)
(abstract_method_signature name: (property_identifier) @function.declaration)
(type_parameter name: (type_identifier) @type.parameter)
(enum_body (property_identifier) @constant)
(enum_assignment name: (property_identifier) @constant)
(predefined_type) @type.builtin

; 官方查询把参数里的标识符一律画成参数（连默认值 `x = LIMIT` 里的 LIMIT 也算）、把大写开头的都画成类型：纠正回来
(required_parameter value: (identifier) @variable)
(optional_parameter value: (identifier) @variable)
((identifier) @constant (#match? @constant "^[A-Z_][A-Z\\d_]+$"))
