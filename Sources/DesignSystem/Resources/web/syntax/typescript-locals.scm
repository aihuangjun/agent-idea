; TypeScript 专有的参数与类型参数。

(required_parameter pattern: (identifier) @def.parameter)
(optional_parameter pattern: (identifier) @def.parameter)
(required_parameter pattern: (rest_pattern (identifier) @def.parameter))
(required_parameter pattern: (object_pattern (shorthand_property_identifier_pattern) @def.parameter))
(required_parameter pattern: (object_pattern (pair_pattern value: (identifier) @def.parameter)))
(required_parameter pattern: (object_pattern (object_assignment_pattern left: (shorthand_property_identifier_pattern) @def.parameter)))
(required_parameter pattern: (array_pattern (identifier) @def.parameter))
(type_parameter name: (type_identifier) @def.typeparam)

(type_identifier) @ref
