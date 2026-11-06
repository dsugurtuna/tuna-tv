import Foundation
import XCTest
@testable import TunaCore

/// Developer tool: `TUNA_PARSE_DUMP=<in.tsv>` (lines "kind<TAB>name[<TAB>category]") writes `<in.tsv>.out.jsonl`.
/// Skipped in normal runs.
final class ParserDumpTool: XCTestCase {
    func testDumpParses() throws {
        guard let path = ProcessInfo.processInfo.environment["TUNA_PARSE_DUMP"] else { throw XCTSkip("dump tool") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let kind = StreamKind(rawValue: parts[0]) else { continue }
            let hints = parts.count > 2 && !parts[2].isEmpty ? CategoryParser.parse(parts[2], kind: kind) : nil
            let p = NameParser.parse(parts[1], kind: kind, category: hints)
            out += String(decoding: try encoder.encode(CurationFixtureCase.Expected(p)), as: UTF8.self) + "\n"
        }
        try out.write(toFile: path + ".out.jsonl", atomically: true, encoding: .utf8)
    }
}
