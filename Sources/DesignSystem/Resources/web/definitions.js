/* 定义导航：复用语法着色的作用域查询，另外捕获类型与函数的声明。项目文件只在本地解析。 */
(function (global) {
  "use strict";

  const script = `
    [(function_declaration name: (identifier) @function)
     (generator_function_declaration name: (identifier) @function)
     (method_definition name: (property_identifier) @function)]
  `;
  const typedScript = script + `
    [(class_declaration name: (type_identifier) @type)
     (interface_declaration name: (type_identifier) @type)
     (type_alias_declaration name: (type_identifier) @type)
     (enum_declaration name: (identifier) @type)]
    (public_field_definition name: (property_identifier) @field)
  `;
  const queries = {
    java: `
      [(class_declaration name: (identifier) @type)
       (interface_declaration name: (identifier) @type)
       (enum_declaration name: (identifier) @type)
       (record_declaration name: (identifier) @type)
       (annotation_type_declaration name: (identifier) @type)]
      (method_declaration name: (identifier) @function)
    `,
    python: `
      (class_definition name: (identifier) @type)
      (function_definition name: (identifier) @function)
      ((assignment left: (attribute object: (identifier) @_receiver attribute: (identifier) @field))
       (#eq? @_receiver "self"))
    `,
    javascript: script + `
      (class_declaration name: (identifier) @type)
      (field_definition property: (property_identifier) @field)
    `,
    typescript: typedScript,
    tsx: typedScript,
    go: `
      [(type_spec name: (type_identifier) @type)
       (type_alias name: (type_identifier) @type)]
      [(function_declaration name: (identifier) @function)
       (method_declaration name: (field_identifier) @function)
       (method_elem name: (field_identifier) @function)]
      (field_declaration name: (field_identifier) @field)
    `,
    cpp: `
      [(class_specifier name: (type_identifier) @type)
       (struct_specifier name: (type_identifier) @type)
       (enum_specifier name: (type_identifier) @type)
       (alias_declaration name: (type_identifier) @type)]
      (function_declarator declarator: [
        (identifier) @function
        (field_identifier) @function
        (qualified_identifier name: (identifier) @function)
      ])
    `,
    swift: `
      [(class_declaration name: (type_identifier) @type)
       (protocol_declaration name: (type_identifier) @type)
       (typealias_declaration name: (type_identifier) @type)]
      (function_declaration name: (simple_identifier) @function)
    `,
  };
  const identifierTypes = new Set([
    "identifier", "type_identifier", "simple_identifier", "field_identifier", "property_identifier",
    "namespace_identifier", "shorthand_property_identifier", "shorthand_property_identifier_pattern",
  ]);
  const identifier = /^[$_\p{ID_Start}][$_\p{ID_Continue}]*$/u;
  const typeContainers = new Set([
    "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration",
    "class_definition", "class_specifier", "struct_specifier", "protocol_declaration", "type_spec",
  ]);
  const memberScopes = new Set([
    "class_body", "interface_body", "enum_body", "record_declaration", "annotation_type_body",
    "class_definition", "field_declaration_list", "enum_class_body", "protocol_body",
  ]);
  const typeOf = (node) => {
    if (!node) return null;
    if (identifierTypes.has(node.type)) return node.text;
    const nested = node.childForFieldName("name") || node.childForFieldName("type") || node.firstNamedChild;
    return nested ? typeOf(nested) : null;
  };

  function enclosingType(node) {
    for (let parent = node.parent; parent; parent = parent.parent) {
      if (typeContainers.has(parent.type)) return parent.childForFieldName("name")?.text ?? null;
    }
    return null;
  }

  function scopesFor(node, scopes) {
    const chain = [];
    for (let parent = node; parent; parent = parent.parent) {
      if (scopes.has(parent.id) || !parent.parent) chain.push(parent);
    }
    return chain;
  }

  const declarationQueries = new WeakMap();
  function bindings(rt, spec, tree, name) {
    let query = declarationQueries.get(rt);
    if (!query) {
      query = new rt.TreeSitter.Query(rt.language, queries[spec.id]);
      declarationQueries.set(rt, query);
    }
    const root = tree.rootNode;
    const locals = rt.locals?.captures(root) || [];
    const scopes = new Map(locals.filter(c => c.name.startsWith("scope")).map(c => [c.node.id, c.name]));
    const definitions = new Map();
    for (const capture of locals.concat(query.captures(root))) {
      if (!capture.name.startsWith("def.") && !["type", "function", "field"].includes(capture.name)) continue;
      const node = capture.node;
      if (name !== undefined && node.text !== name) continue;
      const kind = capture.name.replace(/^def\./, "");
      const parent = node.parent;
      const isNamedDeclaration = kind === "function" || kind === "type";
      const declarator = parent.type === "qualified_identifier" ? parent.parent : parent;
      const container = declarator.type === "function_declarator" && declarator.parent.type === "function_definition"
        ? declarator.parent : parent;
      const scope = scopesFor(isNamedDeclaration ? container.parent : parent, scopes)[0];
      const receiver = parent.childForFieldName("receiver")?.firstNamedChild;
      const qualifier = parent.type === "qualified_identifier" ? parent.childForFieldName("scope") : null;
      const owner = typeOf(receiver?.childForFieldName("type") || qualifier)
        || (memberScopes.has(scope.type) || kind === "field" ? enclosingType(node) : null);
      const params = parent.childForFieldName("parameters");
      const arity = spec.id === "java" && kind === "function" && params && !params.namedChildren.some(n => n.type === "spread_parameter")
        ? params.namedChildren.filter(n => n.type === "formal_parameter").length : null;
      definitions.set(node.startIndex, { node, kind, scope, owner, arity });
    }
    return { scopes, definitions: Array.from(definitions.values()) };
  }

  function namespace(root, type) {
    return root.namedChildren.find(node => node.type === type)?.firstNamedChild?.text ?? null;
  }

  function moduleBinding(spec, root, name, receiver) {
    if (["javascript", "typescript", "tsx"].includes(spec.id)) {
      for (const statement of root.namedChildren.filter(n => n.type === "import_statement")) {
        const path = statement.childForFieldName("source")?.firstNamedChild?.text;
        const clause = statement.namedChildren.find(n => n.type === "import_clause");
        if (!path || !clause) continue;
        if (receiver && clause.namedChildren.some(n => n.type === "namespace_import" && n.firstNamedChild?.text === receiver.text)) {
          return { path, name };
        }
        if (receiver) continue;
        const imports = clause.namedChildren.find(n => n.type === "named_imports");
        for (const item of imports?.namedChildren || []) {
          const original = item.childForFieldName("name")?.text;
          if (original && (item.childForFieldName("alias")?.text || original) === name) return { path, name: original };
        }
      }
    } else if (spec.id === "go" && receiver) {
      for (const statement of root.namedChildren.filter(n => n.type === "import_declaration")) {
        const first = statement.firstNamedChild;
        for (const item of first?.type === "import_spec" ? [first] : first?.namedChildren || []) {
          const path = item.childForFieldName("path")?.text.slice(1, -1);
          if (path && (item.childForFieldName("name")?.text || path.split("/").pop()) === receiver.text) return { path, name };
        }
      }
    } else if (spec.id === "python" && !receiver) {
      for (const statement of root.namedChildren.filter(n => n.type === "import_from_statement")) {
        const path = statement.childForFieldName("module_name")?.text;
        if (!path) continue;
        for (const item of statement.childrenForFieldName("name")) {
          const original = (item.childForFieldName("name") || item).text;
          if ((item.childForFieldName("alias")?.text || original) === name) return { path, name: original };
        }
      }
    }
    return null;
  }

  function relativeModule(path, sourcePath) {
    const parts = sourcePath.split("/").slice(0, -1);
    for (const component of path.split("/")) {
      if (component === "..") parts.pop();
      else if (component && component !== ".") parts.push(component);
    }
    return parts.join("/");
  }

  function moduleMatches(module, path) {
    const stem = path.replace(/\.[^/.]+$/, "");
    if (module.language === "go") {
      const directory = path.slice(0, path.lastIndexOf("/"));
      const segments = module.path.split("/");
      return segments.some((_, index) => directory.endsWith("/" + segments.slice(index).join("/")));
    }
    if (module.language === "python") {
      const dots = module.path.match(/^\.+/)?.[0].length || 0;
      const name = module.path.slice(dots).replace(/\./g, "/");
      if (dots) {
        const base = relativeModule("../".repeat(dots - 1) + name, module.sourcePath);
        return stem === base || stem === base + "/__init__";
      }
      return stem.endsWith("/" + name) || stem.endsWith("/" + name + "/__init__");
    }
    const base = module.path.startsWith(".") ? relativeModule(module.path, module.sourcePath) : null;
    return !!base && (path === base || stem === base || stem === base.replace(/\.[cm]?jsx?$/, "") || stem === base + "/index");
  }

  function lookupContext(rt, spec, tree, node, scopes) {
    const parent = node.parent;
    const member = {
      method_invocation: ["name", "object"], field_access: ["field", "object"], attribute: ["attribute", "object"],
      member_expression: ["property", "object"], selector_expression: ["field", "operand"], field_expression: ["field", "argument"],
      qualified_identifier: ["name", "scope"],
    }[parent.type];
    let receiver = member && parent.childForFieldName(member[0])?.id === node.id
      ? parent.childForFieldName(member[1]) : null;
    if (parent.type === "navigation_suffix") receiver = parent.parent.childForFieldName("target");
    const chain = scopesFor(parent, scopes);
    let owner = null;
    if (receiver) {
      if (["this", "self", "cls"].includes(receiver.text)) {
        owner = enclosingType(node);
      } else if (identifier.test(receiver.text)) {
        // 从变量声明的类型或构造表达式推断接收者；未知接收者时只给成员候选。
        const variables = bindings(rt, spec, tree, receiver.text).definitions;
        const binding = lexical(variables, chain, scopes, receiver, spec.id)[0];
        const declaration = binding?.node.parent;
        const typed = declaration?.childForFieldName("type") || declaration?.parent?.childForFieldName("type")
          || declaration?.parent?.namedChildren.find(n => n.type === "type_annotation");
        const value = declaration?.childForFieldName("value") || declaration?.childForFieldName("right") || declaration?.parent?.childForFieldName("value");
        const constructed = value?.childForFieldName("constructor") || value?.childForFieldName("type")
          || (value?.type === "call" || value?.type === "call_expression" ? value.firstNamedChild : null);
        owner = typeOf(typed) || typeOf(constructed) || (/^\p{Lu}/u.test(receiver.text) ? receiver.text : null);
      } else if (receiver.type === "new_expression" || receiver.type === "object_creation_expression") {
        owner = typeOf(receiver.childForFieldName("constructor") || receiver.childForFieldName("type"));
      }
    }
    const java = spec.id === "java";
    const name = node.text;
    const imports = java ? tree.rootNode.namedChildren.filter(n => n.type === "import_declaration").map(n => n.text) : [];
    const importName = owner || name;
    let imported = imports.map(line => /^import\s+([\w.$]+)\s*;$/u.exec(line)?.[1])
      .find(path => path?.endsWith("." + importName));
    if (imported) imported = imported.slice(0, -importName.length - 1);
    if (java && !receiver) {
      const from = imports.map(line => /^import\s+static\s+([\w.$]+)\.([\w$]+)\s*;$/u.exec(line))
        .find(match => match?.[2] === name);
      if (from) {
        const parts = from[1].split(".");
        owner = parts.pop();
        imported = parts.join(".");
      }
      if (parent.type === "scoped_type_identifier" && parent.lastNamedChild?.id === node.id) {
        imported = parent.firstNamedChild?.text;
      }
    }
    const argumentsNode = java && parent.type === "method_invocation" && parent.childForFieldName("name")?.id === node.id
      ? parent.childForFieldName("arguments") : null;
    return {
      name, owner, member: Boolean(receiver) || Boolean(owner), arity: argumentsNode?.namedChildren.filter(n => !n.isExtra).length ?? null,
      kind: node.type === "type_identifier" ? "type" : argumentsNode ? "function"
        : java && parent.type === "field_access" ? "field" : null,
      namespace: java ? namespace(tree.rootNode, "package_declaration") : spec.id === "go" ? namespace(tree.rootNode, "package_clause") : null,
      imported: imported ?? null,
      fromModule: !owner ? moduleBinding(spec, tree.rootNode, name, receiver) : null,
    };
  }

  function matches(binding, context) {
    if (context.kind === "type" && !["type", "typeparam"].includes(binding.kind)) return false;
    if (context.kind === "function" && binding.kind !== "function") return false;
    if (context.kind === "field" && ["function", "type", "typeparam"].includes(binding.kind)) return false;
    if (context.arity != null && binding.arity != null && binding.arity !== context.arity) return false;
    return !context.member || (binding.owner && (!context.owner || binding.owner === context.owner));
  }

  function lexical(definitions, chain, scopes, node, language) {
    for (const scope of chain) {
      if (scopes.get(scope.id) === "scope.isolated" && scope.id !== chain[0].id) continue;
      const found = definitions.filter(binding => binding.scope.id === scope.id && (
        binding.kind !== "local" || binding.owner || binding.node.startIndex <= node.startIndex || language === "python"
      ));
      if (found.length) {
        // Python 的赋值与 C++ 的前向声明可以重复，优先同一作用域里最早的声明；重载函数保留各项。
        return found.some(binding => binding.kind !== "function") ? [found[0]] : found;
      }
    }
    return [];
  }

  function position(binding) {
    const point = binding.node.startPosition;
    return { line: point.row, ch: point.column };
  }

  function identifierAt(tree, index, end) {
    const root = tree.rootNode;
    const at = root.namedDescendantForIndex(index, index + 1);
    const before = end === index && index > 0 ? root.namedDescendantForIndex(index - 1, index) : null;
    return [at, before].find(node => node && identifierTypes.has(node.type) && identifier.test(node.text)
      && node.startIndex <= index && node.endIndex >= end);
  }

  async function lookup(language, path, text, index, end, cm) {
    const spec = global.Syntax.specFor(language, path);
    if (!spec || !queries[spec.id]) return null;
    const rt = await global.Syntax.load(language, path);
    if (!rt) return null;
    return global.Syntax.withTree(rt, text, cm, tree => {
      const node = identifierAt(tree, index, end);
      if (!node) return null;
      const { scopes, definitions } = bindings(rt, spec, tree, node.text);
      const context = lookupContext(rt, spec, tree, node, scopes);
      const candidates = definitions.filter(binding => matches(binding, context));
      const chain = scopesFor(node.parent, scopes);
      const inOtherPackage = context.imported && context.imported !== context.namespace;
      const local = inOtherPackage ? [] : context.member
        ? (context.owner ? candidates : [])
        : lexical(candidates, chain, scopes, node, spec.id);
      // 选的是声明本身时维持原位，避免跳到其它同名符号。
      const declaration = definitions.find(binding => binding.node.id === node.id);
      if (declaration || local.length) return { ...context, fromModule: null, local: declaration ? [position(declaration)] : local.map(position) };
      const fromModule = context.fromModule && { ...context.fromModule, language: spec.id, sourcePath: path };
      return { ...context, name: fromModule?.name || context.name, fromModule, local: [],
        uncertain: context.member && !context.owner && !fromModule,
        sameFileCandidates: context.member && !context.owner && !fromModule ? candidates.map(position) : [] };
    });
  }

  async function findInSources(context, sources) {
    const hits = [];
    for (const source of sources) {
      const spec = global.Syntax.specFor(null, source.path);
      if (!spec || !queries[spec.id]) continue;
      if (context.fromModule && !moduleMatches(context.fromModule, source.path)) continue;
      const rt = await global.Syntax.load(null, source.path);
      if (!rt) continue;
      const result = global.Syntax.withTree(rt, source.text, null, tree => {
        const root = tree.rootNode;
        const pkg = spec.id === "java" ? namespace(root, "package_declaration") : spec.id === "go" ? namespace(root, "package_clause") : null;
        if (context.imported && pkg !== context.imported) return [];
        const matchContext = context.fromModule ? { ...context, member: false } : context;
        return bindings(rt, spec, tree, context.name).definitions
          .filter(binding => matches(binding, matchContext) && (matchContext.member ? binding.owner : !binding.scope.parent && !binding.owner))
          .map(binding => ({ path: source.path, ...position(binding), preferred: !context.fromModule && !!context.namespace && context.namespace === pkg }));
      });
      if (result) hits.push(...result);
    }
    return hits;
  }

  function enclosingTypes(node) {
    const names = [];
    for (let parent = node.parent; parent; parent = parent.parent) {
      if (!typeContainers.has(parent.type)) continue;
      const name = parent.childForFieldName("name");
      if (name && name.id !== node.id) names.unshift(name.text);
    }
    return names;
  }

  const qualified = (...names) => names.filter(Boolean).join(".");
  const javaParts = node => node && (node.type === "scoped_type_identifier" || node.type === "scoped_identifier")
    ? node.namedChildren.filter(child => !child.isExtra).flatMap(javaParts)
    : node ? [node.text] : [];

  function javaName(node) {
    if (node?.type === "generic_type") node = node.firstNamedChild;
    if (node?.type === "annotated_type") return javaName(node.lastNamedChild);
    return javaParts(node).join(".");
  }

  function javaImports(root) {
    return root.namedChildren.filter(node => node.type === "import_declaration").map(node => {
      const parts = node.namedChildren.filter(child => !child.isExtra);
      return qualified(javaName(parts[0]), parts[1]?.type === "asterisk" ? "*" : null);
    }).filter(Boolean);
  }

  function javaContext(root, node) {
    const declaration = root.namedChildren.find(n => n.type === "package_declaration");
    const pkg = javaName(declaration?.namedChildren.find(n => !n.isExtra));
    return { package: pkg, imports: javaImports(root), owner: qualified(pkg, ...enclosingTypes(node)) || null };
  }

  function javaParents(declaration) {
    const base = declaration.childForFieldName("superclass");
    const list = declaration.childForFieldName("interfaces") || declaration.namedChildren.find(n => n.type === "extends_interfaces");
    const parents = list?.namedChildren.find(n => n.type === "type_list")?.namedChildren.filter(n => !n.isExtra) || [];
    return [javaName(base?.namedChildren.find(n => !n.isExtra)), ...parents.map(javaName)].filter(Boolean);
  }

  async function javaTypeReference(language, path, text, index, end, cm) {
    const spec = global.Syntax.specFor(language, path);
    if (spec?.id !== "java") return null;
    const rt = await global.Syntax.load(language, path);
    if (!rt) return null;
    return global.Syntax.withTree(rt, text, cm, tree => {
      const node = identifierAt(tree, index, end);
      if (!node) return null;
      const context = javaContext(tree.rootNode, node);
      const declaration = typeContainers.has(node.parent.type) && node.parent.childForFieldName("name")?.id === node.id;
      if (declaration) return { ...context, name: node.text, declared: qualified(context.owner, node.text) };
      if (node.type !== "type_identifier" && node.parent.type !== "scoped_identifier") return null;
      let type = node;
      // 只有当前 token 是限定名的最后一段时才将其左侧作为限定符。
      for (let parent = node.parent; parent?.type === "scoped_identifier" || parent?.type === "scoped_type_identifier"; parent = parent.parent) {
        if (parent.lastNamedChild?.id !== type.id) break;
        type = parent;
      }
      return { ...context, name: javaName(type) };
    });
  }

  const anonymousClasses = new WeakMap();
  function outline(rt, spec, source, tree) {
    const root = tree.rootNode;
    const java = spec.id === "java" ? { ...javaContext(root, root), types: [] } : null;
    const symbols = [];
    const { definitions } = bindings(rt, spec, tree);
    for (const binding of definitions) {
      const { node } = binding;
      const kind = binding.kind === "type"
        ? (["interface_declaration", "protocol_declaration", "annotation_type_declaration"].includes(node.parent.type) ? "interface" : "type")
        : binding.kind === "function" || (node.parent.type === "variable_declarator"
          && ["arrow_function", "function_expression", "generator_function"].includes(node.parent.childForFieldName("value")?.type))
          ? "function" : "variable";
      if (kind === "variable" && (binding.kind === "parameter" || binding.kind === "typeparam" || (binding.scope.parent && !binding.owner))) continue;
      const owner = qualified(java?.package, ...enclosingTypes(node));
      const symbol = { name: node.text, qualifiedName: qualified(owner, node.text), kind, ...position(binding) };
      symbols.push(symbol);
      if (java && kind !== "function" && kind !== "variable") {
        java.types.push({ symbol, owner: owner || null, parents: javaParents(node.parent) });
      }
    }
    if (java) {
      let query = anonymousClasses.get(rt);
      if (!query) {
        query = new rt.TreeSitter.Query(rt.language, "(object_creation_expression type: (_) @base (class_body))");
        anonymousClasses.set(rt, query);
      }
      for (const { node } of query.captures(root)) {
        const parent = javaName(node);
        if (!parent) continue;
        const name = parent.split(".").pop();
        const owner = qualified(java.package, ...enclosingTypes(node));
        let identifier = node;
        if (identifier.type === "generic_type") identifier = identifier.firstNamedChild;
        while (identifier.type === "annotated_type" || identifier.type === "scoped_type_identifier") identifier = identifier.lastNamedChild;
        const location = position({ node: identifier });
        const symbol = { name, qualifiedName: qualified(owner, name) + "（匿名类，" + (location.line + 1) + " 行）", kind: "type", ...location };
        java.types.push({ symbol, owner: owner || null, parents: [parent] });
      }
    }
    return { path: source.path, symbols, java };
  }

  async function sourceOutlines(sources) {
    const results = [];
    for (const source of sources) {
      const spec = global.Syntax.specFor(null, source.path);
      if (!spec || !queries[spec.id]) continue;
      const rt = await global.Syntax.load(null, source.path);
      if (!rt) continue;
      const result = global.Syntax.withTree(rt, source.text, null, tree => outline(rt, spec, source, tree));
      if (result) results.push(result);
    }
    return results;
  }

  global.Definitions = { lookup, findInSources, javaTypeReference, sourceOutlines };
})(window);
