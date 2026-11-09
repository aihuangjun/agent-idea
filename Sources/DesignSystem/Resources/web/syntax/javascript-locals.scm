; JavaScript 专有的参数写法（TypeScript 的参数包在 required_parameter 里，见 typescript-locals.scm）。

(formal_parameters (identifier) @def.parameter)
(formal_parameters (assignment_pattern left: (identifier) @def.parameter))
(formal_parameters (rest_pattern (identifier) @def.parameter))
(formal_parameters (object_pattern (shorthand_property_identifier_pattern) @def.parameter))
(formal_parameters (object_pattern (pair_pattern value: (identifier) @def.parameter)))
(formal_parameters (object_pattern (object_assignment_pattern left: (shorthand_property_identifier_pattern) @def.parameter)))
(formal_parameters (array_pattern (identifier) @def.parameter))
