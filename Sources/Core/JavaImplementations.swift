import Foundation

public struct JavaTypeReference: Codable, Sendable {
    public let name: String
    public let package: String
    public let imports: [String]
    public let owner: String?
    /// 光标在声明名上时使用精确的限定名。
    public let declared: String?
}

public struct JavaSource: Codable, Sendable {
    public let package: String
    public let imports: [String]
    public let types: [TypeDeclaration]

    public struct TypeDeclaration: Codable, Sendable {
        public let symbol: SourceSymbol
        public let owner: String?
        public let parents: [String]
    }
}

/// 解析继承边时使用各声明所在文件的包名、导入和外围类型。遍历反向边可找到跨文件的间接实现。
public enum JavaImplementations {
    public struct Match: Identifiable, Sendable {
        public let path: String
        public let symbol: SourceSymbol
        public var id: ProjectSearch.Result.ID { ProjectSearch.Result(path: path, symbol: symbol).id }
    }

    public struct Result: Sendable {
        public let interfaceName: String
        public let matches: [Match]
    }

    public static func find(_ reference: JavaTypeReference, in outlines: [SourceOutline]) -> Result? {
        let units: [(path: String, unit: JavaSource)] = outlines.compactMap { outline in
            outline.java.map { (outline.path, $0) }
        }
        let names = Set(units.flatMap { $0.unit.types.map(\.symbol.qualifiedName) })
        guard let interfaceName = reference.declared ?? resolve(reference.name, package: reference.package, imports: reference.imports, owner: reference.owner, known: names),
              units.contains(where: { $0.unit.types.contains(where: { $0.symbol.kind == .interface && $0.symbol.qualifiedName == interfaceName }) })
        else { return nil }

        var children: [String: [Match]] = [:]
        for (path, unit) in units {
            for type in unit.types {
                for parent in type.parents {
                    guard let resolved = resolve(parent, package: unit.package, imports: unit.imports, owner: type.owner, known: names)
                    else { continue }
                    children[resolved, default: []].append(Match(path: path, symbol: type.symbol))
                }
            }
        }
        var pending = [interfaceName]
        var visited = Set<String>()
        var results: [ProjectSearch.Result.ID: Match] = [:]
        while let name = pending.popLast() {
            guard visited.insert(name).inserted else { continue }
            for child in children[name] ?? [] {
                let symbol = child.symbol
                if symbol.kind != .interface, symbol.qualifiedName != interfaceName { results[child.id] = child }
                if !visited.contains(symbol.qualifiedName) { pending.append(symbol.qualifiedName) }
            }
        }
        return Result(interfaceName: interfaceName, matches: results.values.sorted {
            if $0.symbol.qualifiedName != $1.symbol.qualifiedName { return $0.symbol.qualifiedName < $1.symbol.qualifiedName }
            if $0.path != $1.path { return $0.path < $1.path }
            return ($0.symbol.line, $0.symbol.ch) < ($1.symbol.line, $1.symbol.ch)
        })
    }

    private static func resolve(_ name: String, package: String, imports: [String], owner: String?, known: Set<String>) -> String? {
        var enclosing = owner
        while let scope = enclosing, !scope.isEmpty, scope != package {
            let candidate = scope + "." + name
            if known.contains(candidate) { return candidate }
            enclosing = scope.lastIndex(of: ".").map { String(scope[..<$0]) }
        }
        let head = name.split(separator: ".").first.map(String.init) ?? name
        let suffix = String(name.dropFirst(head.count))
        let explicit = imports.filter { $0.split(separator: ".").last.map(String.init) == head }
        if !explicit.isEmpty {
            let options = Set(explicit.map { $0 + suffix })
            guard options.count == 1, let candidate = options.first, known.contains(candidate) else { return nil }
            return candidate
        }
        let samePackage = package.isEmpty ? name : package + "." + name
        if known.contains(samePackage) { return samePackage }
        if known.contains(name) { return name }
        let wildcard = Set(imports.filter { $0.hasSuffix(".*") }.map { String($0.dropLast()) + name }.filter(known.contains))
        return wildcard.count == 1 ? wildcard.first : nil
    }
}
