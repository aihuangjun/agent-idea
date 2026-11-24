import Core
import Foundation
import Testing
import TestSupport

@Test func fileImportPreservesTheNamesOfSelectedFilesAndRejectsCollisions() throws {
    try withTemporaryDirectory { directory in
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let one = source.appendingPathComponent("one.txt")
        let two = source.appendingPathComponent("图 片.png")
        try Data([1]).write(to: one)
        try Data([2]).write(to: two)

        let items = try FileImport.plan([one, two], into: target)
        #expect(items.map(\.source) == [one, two])
        #expect(items.map(\.destination) == [target.appendingPathComponent("one.txt"), target.appendingPathComponent("图 片.png")])
        #expect(throws: FileImport.Problem.self) { try FileImport.plan([source], into: target) }
        #expect(throws: FileImport.Problem.self) { try FileImport.plan([two, two], into: target) }

        try fileManager.createSymbolicLink(at: items[1].destination, withDestinationURL: target.appendingPathComponent("missing"))
        #expect(throws: FileImport.Problem.self) { try FileImport.plan([one, two], into: target) }
    }
}
