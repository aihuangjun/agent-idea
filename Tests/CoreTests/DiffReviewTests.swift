import Core
import Foundation
import Testing

@Test func diffReviewWhitespaceRulesPreserveLineBoundariesAndMeaningfulChanges() {
    let old = "let a = 1  \n\treturn a\nend\n"
    let new = "let a = 1\n    return a\nEND\n"
    let strict = DiffReviewAnalysis(oldText: old, newText: new)
    #expect(strict.added == 3 && strict.removed == 3)
    let trailing = DiffReviewAnalysis(oldText: old, newText: new, options: .init(whitespace: .trailing))
    #expect(trailing.added == 2 && trailing.removed == 2)
    let all = DiffReviewAnalysis(oldText: old, newText: new, options: .init(whitespace: .all))
    #expect(all.changes.count == 1 && all.changes[0].newStart == 2)
    #expect(all.added == 1 && all.removed == 1)
    #expect(DiffReviewAnalysis(oldText: "a\nb\n", newText: "a b\n", options: .init(whitespace: .all)).changes.count == 1)
    #expect(DiffReviewAnalysis(oldText: "a\n", newText: "a\n\n", options: .init(whitespace: .all)).added == 1)
}

@Test func diffReviewFoldsOnlyUnchangedContextAndRetainsBothEdges() {
    let old = (0..<100).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let new = old.replacingOccurrences(of: "line 20\n", with: "CHANGED 20\n")
        .replacingOccurrences(of: "line 80\n", with: "CHANGED 80\n")
    let analysis = DiffReviewAnalysis(oldText: old, newText: new)
    #expect(analysis.changes.count == 2)
    #expect(analysis.folds.map(\.count) == [10, 39, 9])
    #expect(analysis.folds.map(\.newStart) == [0, 31, 91])
    for fold in analysis.folds {
        #expect(analysis.changes.allSatisfy { $0.newStart < fold.newStart || $0.newStart >= fold.newStart + fold.count })
    }
    let identical = DiffReviewAnalysis(oldText: old, newText: old)
    #expect(identical.changes.isEmpty && identical.folds[0].newStart == 10 && identical.folds[0].count == 80)
}

@Test func diffContextChoicesRetainTheRequestedNumberOfLinesAndMigrateOldSettings() throws {
    #expect(DiffReadingOptions().contextLines == 10)
    #expect(DiffReadingOptions.contextLineChoices == [5, 10, 30])
    let old = (0..<200).map { "line \($0)\n" }.joined()
    let new = old.replacingOccurrences(of: "line 80\n", with: "CHANGED 80\n")
    for context in DiffReadingOptions.contextLineChoices {
        let options = DiffReadingOptions(collapseUnchanged: true, contextLines: context, whitespace: .trailing)
        let restored = try JSONDecoder().decode(DiffReadingOptions.self, from: JSONEncoder().encode(options))
        #expect(restored == options)
        let analysis = DiffReviewAnalysis(oldText: old, newText: new, options: options)
        #expect(analysis.folds.map(\.count) == [80 - context, 119 - context])
        #expect(analysis.folds.map(\.newStart) == [0, 81 + context])
    }
    let legacy = DiffReadingOptions(collapseUnchanged: true, contextLines: 3, whitespace: .all)
    let migrated = try JSONDecoder().decode(DiffReadingOptions.self, from: JSONEncoder().encode(legacy))
    #expect(migrated.contextLines == 10 && migrated.collapseUnchanged && migrated.whitespace == .all)
}

@Test func diffReviewHandlesEmptyFilesEOFNewlineAndShiftedContext() {
    let added = DiffReviewAnalysis(oldText: "", newText: "a\n")
    #expect(added.added == 1 && added.removed == 0 && added.folds.isEmpty)
    let deleted = DiffReviewAnalysis(oldText: "a\n", newText: "")
    #expect(deleted.added == 0 && deleted.removed == 1)
    #expect(DiffReviewAnalysis(oldText: "a", newText: "a\n").changes.count == 1)
    let unterminated = DiffReviewAnalysis(oldText: "a", newText: "a\nb")
    #expect(unterminated.changes[0].oldStart == 0 && unterminated.added == 2 && unterminated.removed == 1)
    let shifted = DiffReviewAnalysis(oldText: "a\nb\nc\nd\n", newText: "a\ninsert\nb\nc\nD\n")
    #expect(shifted.changes.count == 2)
    #expect(shifted.changes[1].oldStart == 3 && shifted.changes[1].newStart == 4)
    #expect(shifted.added == 2 && shifted.removed == 1)
}

@Test func diffReviewBoundsExpensiveComparisonsWithoutDiscardingText() {
    let old = (0..<2100).map { "old \($0)" }.joined(separator: "\n")
    let new = (0..<2100).map { "new \($0)" }.joined(separator: "\n")
    let analysis = DiffReviewAnalysis(oldText: old, newText: new)
    #expect(analysis.simplified && analysis.changes.count == 1)
    #expect(analysis.added == 2100 && analysis.removed == 2100)
    let sparse = (0..<10000).map { "line \($0)" }.joined(separator: "\n")
    let sparseNew = sparse.replacingOccurrences(of: "line 10\n", with: "FIRST\n").replacingOccurrences(of: "line 9900\n", with: "LAST\n")
    let precise = DiffReviewAnalysis(oldText: sparse, newText: sparseNew)
    #expect(!precise.simplified && precise.changes.count == 2 && precise.folds.count == 2)
}

@Test func diffReviewMyersMatchesMinimumEditsForRepeatedLines() {
    var sequences: [[String]] = [[]]
    for length in 1...4 {
        for mask in 0..<(1 << length) { sequences.append((0..<length).map { mask & (1 << $0) == 0 ? "a" : "b" }) }
    }
    for old in sequences {
        for new in sequences {
            let analysis = DiffReviewAnalysis(oldText: old.isEmpty ? "" : old.joined(separator: "\n") + "\n",
                                              newText: new.isEmpty ? "" : new.joined(separator: "\n") + "\n")
            var dp = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
            for i in 0...old.count { dp[i][0] = i }
            for j in 0...new.count { dp[0][j] = j }
            if !old.isEmpty && !new.isEmpty {
                for i in 1...old.count { for j in 1...new.count {
                    dp[i][j] = old[i - 1] == new[j - 1] ? dp[i - 1][j - 1] : min(dp[i - 1][j], dp[i][j - 1]) + 1
                } }
            }
            #expect(analysis.added + analysis.removed == dp[old.count][new.count])
            var restored = old
            for change in analysis.changes.reversed() {
                restored.replaceSubrange(change.oldStart..<(change.oldStart + change.oldCount), with: new[change.newStart..<(change.newStart + change.newCount)])
            }
            #expect(restored == new)
        }
    }
}
