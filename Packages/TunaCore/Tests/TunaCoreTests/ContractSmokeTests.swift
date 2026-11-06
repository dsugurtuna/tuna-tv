import XCTest
@testable import TunaCore

final class ContractSmokeTests: XCTestCase {
    func testModelBasics() {
        let ref = StreamRef(providerID: "p", kind: .movie, streamID: "42")
        XCTAssertEqual(ref.id, "p|movie|42")
        XCTAssertEqual(Flags.emoji(for: "TR"), "🇹🇷")
        XCTAssertEqual("Kurtlar Vadisi İstanbul Işık".tunaFolded, "kurtlar vadisi istanbul isik")
        XCTAssertTrue(Quality.uhd > Quality.fhd)
        var state = UserState()
        state.toggleMyList("movie:matrix:1999")
        XCTAssertTrue(state.isInMyList("movie:matrix:1999"))
    }
}
