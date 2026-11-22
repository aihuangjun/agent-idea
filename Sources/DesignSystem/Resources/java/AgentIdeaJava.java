import com.sun.source.tree.*;
import com.sun.source.util.*;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.regex.Pattern;
import javax.lang.model.element.*;
import javax.lang.model.util.Elements;
import javax.tools.*;

/** Analyze project sources with javac. Never generate classes or run project code or processors. */
public final class AgentIdeaJava {
    private static final Pattern TOKEN = Pattern.compile(
        "//[^\\r\\n]*|/\\*(?s:.*?)\\*/|\"\"\"(?s:.*?)\"\"\"|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|\\p{javaJavaIdentifierStart}\\p{javaJavaIdentifierPart}*|[^\\s]");
    private static final int RESULT_LIMIT = 10_000;

    private record Location(String path, int start, int length, int line, int column) {
        int end() { return start + length; }
        String id() { return path + "\n" + start; }
    }
    private record Hit(Element symbol, Location location, boolean declaration) {}
    private record Call(ExecutableElement caller, ExecutableElement callee, Location site) {}

    private static final class Source extends SimpleJavaFileObject {
        final String path;
        final String text;

        Source(String path, String text, int number) throws Exception {
            super(new URI("source", null, "/" + number + "/" + Path.of(path).getFileName(), null), Kind.SOURCE);
            this.path = path;
            this.text = text;
        }

        @Override public CharSequence getCharContent(boolean ignoreEncodingErrors) { return text; }
    }

    private static final class Index extends TreePathScanner<Void, Void> {
        final Trees trees;
        final SourcePositions positions;
        final Map<URI, Source> sources;
        final List<Hit> hits = new ArrayList<>();
        final Map<Element, Location> declarations = new LinkedHashMap<>();
        final List<Call> calls = new ArrayList<>();
        CompilationUnitTree unit;
        Source source;
        ExecutableElement caller;

        Index(Trees trees, Map<URI, Source> sources) {
            this.trees = trees;
            this.positions = trees.getSourcePositions();
            this.sources = sources;
        }

        void read(CompilationUnitTree unit) {
            this.unit = unit;
            source = sources.get(unit.getSourceFile().toUri());
            if (source != null) scan(unit, null);
        }

        int start(Tree tree) { return tree == null ? -1 : (int) positions.getStartPosition(unit, tree); }
        int end(Tree tree) { return tree == null ? -1 : (int) positions.getEndPosition(unit, tree); }

        Location location(int start, String name) {
            if (start < 0 || name.isEmpty() || !source.text.startsWith(name, start)) return null;
            var map = unit.getLineMap();
            var line = map.getLineNumber(start);
            // LineMap's column expands tabs. The editor uses an ordinary UTF-16 offset.
            int column = start - (int) map.getStartPosition(line);
            return new Location(source.path, start, name.length(), (int) line - 1, column);
        }

        void hit(Element symbol, Location location, boolean declaration) {
            if (symbol == null || location == null || !supported(symbol.getKind())) return;
            hits.add(new Hit(symbol, location, declaration));
            if (declaration) declarations.putIfAbsent(symbol, location);
        }

        static boolean supported(ElementKind kind) {
            return kind.isClass() || kind.isInterface() || kind == ElementKind.METHOD || kind == ElementKind.CONSTRUCTOR
                || kind.isField() || kind == ElementKind.PARAMETER || kind == ElementKind.LOCAL_VARIABLE
                || kind == ElementKind.RESOURCE_VARIABLE || kind == ElementKind.EXCEPTION_PARAMETER
                || kind == ElementKind.BINDING_VARIABLE || kind == ElementKind.RECORD_COMPONENT;
        }

        Element element() { return trees.getElement(getCurrentPath()); }

        int token(int from, int to, String name, boolean last, boolean followedByParen) {
            if (from < 0 || to < from || to > source.text.length()) return -1;
            var matcher = TOKEN.matcher(source.text).region(from, to);
            int result = -1;
            int candidate = -1;
            while (matcher.find()) {
                var word = matcher.group();
                if (word.startsWith("//") || word.startsWith("/*")) continue;
                if (candidate >= 0 && word.equals("(")) {
                    result = candidate;
                    if (!last) return result;
                }
                candidate = -1;
                if (!word.equals(name)) continue;
                if (followedByParen) candidate = matcher.start();
                else if (!last) return matcher.start();
                else result = matcher.start();
            }
            return result;
        }

        @Override public Void visitClass(ClassTree tree, Void unused) {
            String name = tree.getSimpleName().toString();
            int from = Math.max(start(tree), end(tree.getModifiers()));
            int limit = end(tree);
            if (!tree.getTypeParameters().isEmpty()) limit = start(tree.getTypeParameters().get(0));
            else if (tree.getExtendsClause() != null) limit = start(tree.getExtendsClause());
            else if (!tree.getImplementsClause().isEmpty()) limit = start(tree.getImplementsClause().get(0));
            else if (!tree.getMembers().isEmpty() && start(tree.getMembers().get(0)) > from) limit = start(tree.getMembers().get(0));
            if (!name.isEmpty()) hit(element(), location(token(from, limit, name, false, false), name), true);
            var savedCaller = caller;
            caller = null;
            try { return super.visitClass(tree, unused); } finally { caller = savedCaller; }
        }

        @Override public Void visitMethod(MethodTree tree, Void unused) {
            var symbol = element();
            var method = symbol instanceof ExecutableElement e ? e : null;
            boolean constructor = method != null && method.getKind() == ElementKind.CONSTRUCTOR;
            String name = constructor ? method.getEnclosingElement().getSimpleName().toString() : tree.getName().toString();
            int from = Math.max(start(tree), Math.max(end(tree.getModifiers()), end(tree.getReturnType())));
            int limit = tree.getBody() == null ? end(tree) : start(tree.getBody());
            if (!tree.getParameters().isEmpty() && start(tree.getParameters().get(0)) >= from) {
                limit = Math.min(limit, start(tree.getParameters().get(0)));
            }
            int offset = token(from, limit, name, false, true);
            if (constructor && offset < 0) offset = token(from, limit, name, true, false);
            hit(method, location(offset, name), true);
            var savedCaller = caller;
            caller = method;
            try { return super.visitMethod(tree, unused); } finally { caller = savedCaller; }
        }

        @Override public Void visitVariable(VariableTree tree, Void unused) {
            var name = tree.getName().toString();
            int from = Math.max(start(tree), Math.max(end(tree.getModifiers()), end(tree.getType())));
            int limit = tree.getInitializer() == null ? end(tree) : start(tree.getInitializer());
            hit(element(), location(token(from, limit, name, true, false), name), true);
            return super.visitVariable(tree, unused);
        }

        @Override public Void visitIdentifier(IdentifierTree tree, Void unused) {
            hit(element(), location(start(tree), tree.getName().toString()), false);
            return super.visitIdentifier(tree, unused);
        }

        @Override public Void visitMemberSelect(MemberSelectTree tree, Void unused) {
            var name = tree.getIdentifier().toString();
            hit(element(), location(end(tree) - name.length(), name), false);
            return super.visitMemberSelect(tree, unused);
        }

        @Override public Void visitMemberReference(MemberReferenceTree tree, Void unused) {
            var name = tree.getName().toString();
            var location = location(end(tree) - name.length(), name);
            hit(element(), location, false);
            call(element(), location);
            return super.visitMemberReference(tree, unused);
        }

        void call(Element target, Location site) {
            if (caller != null && target instanceof ExecutableElement method && site != null) calls.add(new Call(caller, method, site));
        }

        @Override public Void visitMethodInvocation(MethodInvocationTree tree, Void unused) {
            var select = tree.getMethodSelect();
            if (select instanceof IdentifierTree id) call(element(), location(start(id), id.getName().toString()));
            if (select instanceof MemberSelectTree member) {
                var name = member.getIdentifier().toString();
                call(element(), location(end(member) - name.length(), name));
            }
            return super.visitMethodInvocation(tree, unused);
        }

        @Override public Void visitNewClass(NewClassTree tree, Void unused) {
            Tree type = tree.getIdentifier();
            if (type instanceof ParameterizedTypeTree parameterized) type = parameterized.getType();
            if (type instanceof IdentifierTree id) call(element(), location(start(id), id.getName().toString()));
            if (type instanceof MemberSelectTree member) {
                var name = member.getIdentifier().toString();
                call(element(), location(end(member) - name.length(), name));
            }
            return super.visitNewClass(tree, unused);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 5) throw new IllegalArgumentException("expected manifest, action, path, start, end");
        Path manifest = Path.of(args[0]);
        String action = args[1];
        String path = args[2];
        int start = Integer.parseInt(args[3]), end = Integer.parseInt(args[4]);
        var compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) throw new IllegalStateException("JDK compiler unavailable");
        var sources = new LinkedHashMap<URI, Source>();
        for (String line : Files.readAllLines(manifest, StandardCharsets.UTF_8)) {
            var row = line.split("\t", -1);
            var source = new Source(decode(row[0]), Files.readString(manifest.resolveSibling(row[1])), sources.size());
            sources.put(source.toUri(), source);
        }
        if (sources.isEmpty()) return;
        var diagnostics = new DiagnosticCollector<JavaFileObject>();
        try (var manager = compiler.getStandardFileManager(diagnostics, Locale.ROOT, StandardCharsets.UTF_8)) {
            var empty = manifest.getParent().resolve("empty").toString();
            var task = (JavacTask) compiler.getTask(null, manager, diagnostics,
                List.of("-proc:none", "-implicit:none", "-classpath", empty, "-sourcepath", empty), null, sources.values());
            var units = task.parse();
            task.analyze();
            long errors = diagnostics.getDiagnostics().stream().filter(d -> d.getKind() == Diagnostic.Kind.ERROR).count();
            System.out.println("errors\t" + errors);
            var index = new Index(Trees.instance(task), sources);
            for (var unit : units) index.read(unit);
            var selected = pick(index.hits, path, start, end);
            if (selected == null) return;
            var symbol = selected.symbol();
            // Constructor declarations are renamed through their class; constructor calls retain their type usage.
            if (!action.equals("hierarchy") && symbol.getKind() == ElementKind.CONSTRUCTOR) symbol = symbol.getEnclosingElement();
            System.out.println("symbol\t" + encode(symbol.getSimpleName().toString()) + "\t" + encode(label(symbol)));
            if (symbol instanceof TypeElement type && type.getNestingKind() == NestingKind.TOP_LEVEL) {
                System.out.println("topLevelType");
            }
            var declaration = index.declarations.get(symbol);
            if (declaration != null) emitLocation("declaration", declaration, label(symbol));
            switch (action) {
                case "usages" -> usages(index, symbol, false, task.getElements());
                case "rename" -> usages(index, symbol, true, task.getElements());
                case "implementations" -> implementations(index, symbol, task.getElements());
                case "hierarchy" -> hierarchy(index, symbol);
                default -> throw new IllegalArgumentException("unknown action");
            }
        }
    }

    private static Hit pick(List<Hit> hits, String path, int start, int end) {
        return hits.stream().filter(hit -> hit.location.path.equals(path) && hit.location.start <= start && hit.location.end() >= end)
            .min(Comparator.comparingInt((Hit hit) -> hit.location.end() == start ? 1 : 0)
                .thenComparingInt(hit -> hit.location.length).thenComparingInt(hit -> hit.declaration ? 0 : 1)).orElse(null);
    }

    private static void usages(Index index, Element symbol, boolean renaming, Elements elements) {
        Set<Element> family = new LinkedHashSet<>();
        family.add(symbol);
        if (renaming && symbol instanceof ExecutableElement method && method.getKind() == ElementKind.METHOD) {
            var candidates = index.declarations.keySet().stream().filter(ExecutableElement.class::isInstance)
                .map(ExecutableElement.class::cast).filter(e -> e.getKind() == ElementKind.METHOD
                    && e.getSimpleName().contentEquals(method.getSimpleName())).toList();
            var implementations = new HashMap<ExecutableElement, Set<ExecutableElement>>();
            boolean added;
            do {
                added = false;
                for (var executable : candidates) {
                    if (family.contains(executable)) continue;
                    if (family.stream().map(e -> (ExecutableElement) e).anyMatch(member -> overrides(elements, executable, member) || overrides(elements, member, executable))
                        || implementations.computeIfAbsent(executable, e -> implementingMethods(index, e, elements)).stream().anyMatch(family::contains)) {
                        family.add(executable);
                        added = true;
                    }
                }
                for (var member : new ArrayList<>(family)) {
                    if (family.addAll(implementations.computeIfAbsent((ExecutableElement) member, e -> implementingMethods(index, e, elements)))) added = true;
                }
            } while (added);
            for (var member : family) {
                if (overridesExternal((ExecutableElement) member, index.declarations.keySet(), elements)) {
                    System.out.println("externalOverride");
                    return;
                }
            }
        }
        if (renaming && symbol instanceof TypeElement) {
            for (var entry : index.declarations.keySet()) {
                if (entry.getKind() == ElementKind.CONSTRUCTOR && entry.getEnclosingElement().equals(symbol)) family.add(entry);
            }
        }
        var seen = new LinkedHashSet<Location>();
        for (Hit hit : index.hits) {
            if (!family.contains(hit.symbol) || (!renaming && hit.declaration) || !seen.add(hit.location)) continue;
            if (renaming && hit.symbol.getKind() == ElementKind.CONSTRUCTOR && !hit.declaration) continue;
            if (seen.size() > RESULT_LIMIT) { System.out.println("truncated"); break; }
            emitLocation("hit", hit.location, label(hit.symbol));
        }
    }

    private static boolean overrides(Elements elements, ExecutableElement a, ExecutableElement b) {
        return !a.equals(b) && a.getSimpleName().contentEquals(b.getSimpleName())
            && a.getEnclosingElement() instanceof TypeElement owner && elements.overrides(a, b, owner);
    }

    private static boolean overridesExternal(ExecutableElement method, Set<Element> project, Elements elements) {
        var owner = (TypeElement) method.getEnclosingElement();
        var seen = new HashSet<String>();
        var pending = new ArrayDeque<TypeElement>();
        pending.add(owner);
        while (!pending.isEmpty()) {
            var parent = pending.removeFirst();
            if (!seen.add(parent.getQualifiedName().toString())) continue;
            for (var member : parent.getEnclosedElements()) {
                if (member instanceof ExecutableElement e && !project.contains(e) && overrides(elements, method, e)) return true;
            }
            addParent(parent.getSuperclass(), pending);
            for (var type : parent.getInterfaces()) addParent(type, pending);
        }
        return false;
    }

    private static void addParent(javax.lang.model.type.TypeMirror type, ArrayDeque<TypeElement> queue) {
        if (type instanceof javax.lang.model.type.DeclaredType declared && declared.asElement() instanceof TypeElement e) queue.add(e);
    }

    private static void implementations(Index index, Element symbol, Elements elements) {
        if (!(symbol instanceof ExecutableElement method) || method.getKind() != ElementKind.METHOD) return;
        int count = 0;
        for (var candidate : implementingMethods(index, method, elements)) {
            if (candidate.getModifiers().contains(Modifier.ABSTRACT)) continue;
            if (++count > RESULT_LIMIT) { System.out.println("truncated"); break; }
            emitLocation("hit", index.declarations.get(candidate), label(candidate));
        }
    }

    private static Set<ExecutableElement> implementingMethods(Index index, ExecutableElement method, Elements elements) {
        var result = new LinkedHashSet<ExecutableElement>();
        var declaringType = (TypeElement) method.getEnclosingElement();
        for (var entry : index.declarations.keySet()) {
            if (!(entry instanceof TypeElement context) || context.equals(declaringType) || !hasParent(context, declaringType)) continue;
            for (var member : elements.getAllMembers(context)) {
                if (member instanceof ExecutableElement candidate && !candidate.equals(method)
                    && candidate.getSimpleName().contentEquals(method.getSimpleName()) && index.declarations.containsKey(candidate)
                    && elements.overrides(candidate, method, context)) result.add(candidate);
            }
        }
        return result;
    }

    private static boolean hasParent(TypeElement type, TypeElement target) {
        var seen = new HashSet<TypeElement>();
        var pending = new ArrayDeque<TypeElement>();
        pending.add(type);
        while (!pending.isEmpty()) {
            var parent = pending.removeFirst();
            if (!seen.add(parent)) continue;
            if (parent.equals(target)) return true;
            addParent(parent.getSuperclass(), pending);
            for (var interfaceType : parent.getInterfaces()) addParent(interfaceType, pending);
        }
        return false;
    }

    private static void hierarchy(Index index, Element symbol) {
        if (!(symbol instanceof ExecutableElement root)) return;
        if (index.declarations.get(root) == null) return;
        var outgoing = new LinkedHashMap<ExecutableElement, List<Call>>();
        var incoming = new LinkedHashMap<ExecutableElement, List<Call>>();
        for (var call : index.calls) {
            if (index.declarations.containsKey(call.callee) && index.declarations.containsKey(call.caller)) {
                outgoing.computeIfAbsent(call.caller, k -> new ArrayList<>()).add(call);
                incoming.computeIfAbsent(call.callee, k -> new ArrayList<>()).add(call);
            }
        }
        var nodes = new LinkedHashSet<ExecutableElement>();
        var calls = new LinkedHashSet<Call>();
        traverse(root, outgoing, true, nodes, calls);
        traverse(root, incoming, false, nodes, calls);
        for (var node : nodes) emitLocation("node", index.declarations.get(node), label(node));
        for (var call : calls) {
            var from = index.declarations.get(call.caller).id();
            var to = index.declarations.get(call.callee).id();
            emitLocation("edge\t" + encode(from) + "\t" + encode(to), call.site, "");
        }
    }

    private static void traverse(ExecutableElement root, Map<ExecutableElement, List<Call>> edges, boolean outgoing,
                                 Set<ExecutableElement> nodes, Set<Call> calls) {
        var queue = new ArrayDeque<ExecutableElement>();
        var seen = new HashSet<ExecutableElement>();
        queue.add(root);
        while (!queue.isEmpty()) {
            var current = queue.removeFirst();
            if (!seen.add(current)) continue;
            nodes.add(current);
            for (var call : edges.getOrDefault(current, List.of())) {
                var other = outgoing ? call.callee : call.caller;
                nodes.add(other);
                calls.add(call);
                if (calls.size() >= RESULT_LIMIT) { System.out.println("truncated"); return; }
                if (!seen.contains(other)) queue.addLast(other);
            }
        }
    }

    private static String label(Element element) {
        return element instanceof TypeElement type ? type.getQualifiedName().toString()
            : element instanceof ExecutableElement ? element.getEnclosingElement() + "." + element
            : element.getSimpleName().toString();
    }

    private static void emitLocation(String prefix, Location loc, String label) {
        System.out.println(String.join("\t", prefix, encode(loc.path), String.valueOf(loc.start), String.valueOf(loc.length),
            String.valueOf(loc.line), String.valueOf(loc.column), encode(label)));
    }

    private static String encode(String input) { return Base64.getEncoder().encodeToString(input.getBytes(StandardCharsets.UTF_8)); }
    private static String decode(String input) { return new String(Base64.getDecoder().decode(input), StandardCharsets.UTF_8); }
}
