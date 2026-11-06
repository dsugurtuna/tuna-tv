import Foundation
import XCTest
@testable import TunaCore

/// Reference values computed with RapidFuzz 3.14 / jellyfish (lowercased inputs).
final class SimilarityTests: XCTestCase {
    func testLevenshtein() {
        XCTAssertEqual(Similarity.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(Similarity.levenshtein("flaw", "lawn"), 2)
        XCTAssertEqual(Similarity.levenshtein("MARTHA", "marhta"), 2)
        XCTAssertEqual(Similarity.levenshtein("DIXON", "DICKSONX"), 4)
        XCTAssertEqual(Similarity.levenshtein("", "abc"), 3)
        XCTAssertEqual(Similarity.levenshtein("abc", ""), 3)
        XCTAssertEqual(Similarity.levenshtein("", ""), 0)
        // Folding: case, diacritics and Turkish dotless/dotted i do not count as edits.
        XCTAssertEqual(Similarity.levenshtein("İstanbul Işık", "istanbul isik"), 0)
        XCTAssertEqual(Similarity.levenshtein("Café Société", "cafe societe"), 0)
    }

    func testJaroWinkler() {
        XCTAssertEqual(Similarity.jaroWinkler("MARTHA", "MARHTA"), 0.9611111111111111, accuracy: 1e-9)
        XCTAssertEqual(Similarity.jaroWinkler("DWAYNE", "DUANE"), 0.84, accuracy: 1e-9)
        XCTAssertEqual(Similarity.jaroWinkler("DIXON", "DICKSONX"), 0.8133333333333332, accuracy: 1e-9)
        XCTAssertEqual(Similarity.jaroWinkler("kitten", "sitting"), 0.746031746031746, accuracy: 1e-9)
        XCTAssertEqual(Similarity.jaroWinkler("crate", "trace"), 0.7333333333333334, accuracy: 1e-9)
        XCTAssertEqual(Similarity.jaroWinkler("Tuna TV", "tuna tv"), 1)
        XCTAssertEqual(Similarity.jaroWinkler("abc", ""), 0)
        XCTAssertEqual(Similarity.jaroWinkler("", ""), 1)
        XCTAssertEqual(Similarity.jaroWinkler("abc", "xyz"), 0)
    }

    func testTokenSetRatio() {
        XCTAssertEqual(Similarity.tokenSetRatio("fuzzy was a bear", "fuzzy fuzzy was a bear"), 1)
        XCTAssertEqual(Similarity.tokenSetRatio("The Matrix (1999)", "Matrix, The 1999"), 1)
        XCTAssertEqual(Similarity.tokenSetRatio("Game of Thrones", "Game of Thrones S01"), 1)
        XCTAssertEqual(Similarity.tokenSetRatio("new york mets", "new york yankees"), 0.7619047619047619, accuracy: 1e-9)
        XCTAssertEqual(Similarity.tokenSetRatio("new york mets", "new york meats"), 0.9629629629629629, accuracy: 1e-9)
        XCTAssertEqual(Similarity.tokenSetRatio("BBC One HD", "BBC Two HD"), 0.8, accuracy: 1e-9)
        XCTAssertEqual(Similarity.tokenSetRatio("Star Wars Episode IV", "Star Trek"), 0.6153846153846154, accuracy: 1e-9)
        XCTAssertEqual(Similarity.tokenSetRatio("abc", "xyz"), 0)
        XCTAssertEqual(Similarity.tokenSetRatio("", "abc"), 0)
        XCTAssertEqual(Similarity.tokenSetRatio("Kurtlar Vadisi", "KURTLAR VADİSİ"), 1)
    }

    func testRatioAndTokens() {
        XCTAssertEqual(Similarity.ratio("MARTHA", "MARHTA"), 0.8333333333333334, accuracy: 1e-9)
        XCTAssertEqual(Similarity.ratio("kitten", "sitting"), 0.6153846153846154, accuracy: 1e-9)
        XCTAssertEqual(Similarity.ratio("", ""), 1)
        XCTAssertEqual(Similarity.tokens("Matrix, The (1999) — 4K"), ["matrix", "the", "1999", "4k"])
        XCTAssertEqual(Similarity.tokens("  "), [])
    }
}
