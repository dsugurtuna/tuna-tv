import Foundation
import XCTest
@testable import TunaCore

final class MetadataTitleMatcherTests: XCTestCase {
    private func candidate(_ id: Int, _ title: String, _ year: Int?, original: String? = nil,
                           popularity: Double = 10, votes: Int = 100) -> TMDBClient.SearchResult {
        TMDBClient.SearchResult(id: id, title: title, originalTitle: original, year: year, popularity: popularity,
                                voteCount: votes, originalLanguage: "en")
    }

    func testAcceptsTheMatrix1999AndRejectsReloaded() {
        let matrix = candidate(603, "The Matrix", 1999, original: "The Matrix", popularity: 81.6, votes: 26412)
        let reloaded = candidate(604, "The Matrix Reloaded", 2003, original: "The Matrix Reloaded", popularity: 40.2, votes: 10512)
        XCTAssertGreaterThanOrEqual(TitleMatcher.score(title: "The Matrix", year: 1999, candidate: matrix), 0.95)
        XCTAssertLessThan(TitleMatcher.score(title: "The Matrix", year: 1999, candidate: reloaded), 0.5)
        XCTAssertEqual(TitleMatcher.best(title: "The Matrix", year: 1999, candidates: [reloaded, matrix])?.id, 603)
        XCTAssertNil(TitleMatcher.best(title: "The Matrix", year: 1999, candidates: [reloaded]))
        XCTAssertNil(TitleMatcher.best(title: "The Matrix", year: nil, candidates: [reloaded]))
    }

    func testYearDelta() {
        let dune = candidate(438631, "Dune", 2021)
        let exact = TitleMatcher.score(title: "Dune", year: 2021, candidate: dune)
        let offByOne = TitleMatcher.score(title: "Dune", year: 2020, candidate: dune)
        let unknown = TitleMatcher.score(title: "Dune", year: nil, candidate: dune)
        let farOff = TitleMatcher.score(title: "Dune", year: 2018, candidate: dune)
        XCTAssertGreaterThan(exact, offByOne)
        XCTAssertGreaterThan(offByOne, unknown)
        XCTAssertGreaterThan(unknown, farOff)
        XCTAssertGreaterThanOrEqual(offByOne, 0.72)
        XCTAssertGreaterThanOrEqual(unknown, 0.72)
        XCTAssertLessThan(farOff, 0.72)
        let noCandidateYear = candidate(1, "Dune", nil)
        XCTAssertEqual(TitleMatcher.score(title: "Dune", year: 2021, candidate: noCandidateYear),
                       TitleMatcher.score(title: "Dune", year: nil, candidate: noCandidateYear), accuracy: 1e-9)
    }

    func testNormalization() {
        XCTAssertEqual(TitleMatcher.normalize("The Lord of the Rings: The Two Towers"), "lord of the rings the two towers")
        XCTAssertEqual(TitleMatcher.normalize("Amélie"), "amelie")
        XCTAssertEqual(TitleMatcher.normalize("Rocky II"), "rocky 2")
        XCTAssertEqual(TitleMatcher.normalize("Fast & Furious"), "fast and furious")
        XCTAssertEqual(TitleMatcher.normalize("Harry Potter and the Philosopher's Stone"), "harry potter and the philosophers stone")
        XCTAssertEqual(TitleMatcher.normalize("L'Odyssée"), "odyssee")
        XCTAssertEqual(TitleMatcher.normalize("Spider-Man: Homecoming"), "spider man homecoming")
        XCTAssertEqual(TitleMatcher.normalize("Kurtlar Vadisi: Pusu"), "kurtlar vadisi pusu")
        XCTAssertEqual(TitleMatcher.normalize("The"), "the")
    }

    func testOriginalTitleAndSpellingVariants() {
        let heist = candidate(71446, "Money Heist", 2017, original: "La casa de papel")
        XCTAssertGreaterThanOrEqual(TitleMatcher.score(title: "La Casa de Papel", year: 2017, candidate: heist), 0.95)
        let spidey = candidate(315635, "Spider-Man: Homecoming", 2017)
        XCTAssertGreaterThanOrEqual(TitleMatcher.score(title: "Spiderman Homecoming", year: 2017, candidate: spidey), 0.9)
        let shawshank = candidate(278, "The Shawshank Redemption", 1994)
        XCTAssertGreaterThanOrEqual(TitleMatcher.score(title: "Shawshank Redemtion", year: 1994, candidate: shawshank), 0.9)
    }

    func testSequelNumbersAreDifferentTitles() {
        let sequel = candidate(863, "Toy Story 2", 1999)
        XCTAssertLessThan(TitleMatcher.score(title: "Toy Story", year: 1995, candidate: sequel), 0.72)
        XCTAssertLessThan(TitleMatcher.score(title: "Toy Story", year: nil, candidate: sequel), 0.72)
        XCTAssertGreaterThanOrEqual(TitleMatcher.score(title: "Rocky 2", year: 1979, candidate: candidate(1367, "Rocky II", 1979)), 0.95)
    }

    func testPopularityBreaksTies() {
        let new = candidate(438631, "Dune", 2021, popularity: 120, votes: 12000)
        let old = candidate(841, "Dune", 1984, popularity: 20, votes: 5000)
        XCTAssertEqual(TitleMatcher.best(title: "Dune", year: nil, candidates: [old, new])?.id, 438631)
        XCTAssertEqual(TitleMatcher.best(title: "Dune", year: 1984, candidates: [new, old])?.id, 841)
    }

    func testThreshold() {
        let it = candidate(1, "It Follows", 2014)
        XCTAssertNil(TitleMatcher.best(title: "It", year: 2014, candidates: [it]))
        XCTAssertEqual(TitleMatcher.best(title: "It", year: 2014, candidates: [it], threshold: 0)?.id, 1)
        XCTAssertNil(TitleMatcher.best(title: "", year: nil, candidates: [it], threshold: 0.01))
    }
}
