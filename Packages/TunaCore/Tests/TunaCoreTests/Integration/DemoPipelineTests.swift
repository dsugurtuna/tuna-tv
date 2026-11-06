import XCTest
@testable import TunaCore

/// End-to-end: demo provider catalog -> Curator -> Library -> metadata, guide, rails, search.
final class DemoPipelineTests: XCTestCase {
    func testDemoPipelineProducesShowcaseVaultRailsAndSearch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = DemoContent.catalog(now: now)
        let curated = Curator(preferences: ContentPreferences()).curate([catalog])
        let library = Library(catalog: curated)
        XCTAssertFalse(library.showcase(.movie).isEmpty, "showcase movies")
        XCTAssertFalse(library.liveShowcase.isEmpty, "showcase channels")
        XCTAssertGreaterThan(library.vaultCounts.values.reduce(0, +), 0, "vault has items")
        XCTAssertGreaterThan(curated.stats.duplicatesMerged, 0)

        let metadata = DemoContent.metadata(for: library)
        XCTAssertFalse(metadata.isEmpty)
        let guide = DemoContent.guide(for: library, now: now)
        let state = DemoContent.userState(for: library, now: now)
        let rails = RailComposer.home(RailContext(library: library, metadata: metadata, userState: state,
                                                  preferences: ContentPreferences(), guide: guide, now: now))
        XCTAssertTrue(rails.contains { $0.style == .hero })
        XCTAssertGreaterThan(rails.count, 4)
        let first = library.showcase(.movie)[0]
        let hits = SearchIndex(library: library, metadata: metadata, guide: guide).search(String(first.name.prefix(5)))
        XCTAssertFalse(hits.isEmpty)
        print("demo pipeline:", library.movies.count, "movies,", library.series.count, "series,",
              library.channels.count, "channels,", rails.count, "rails, vault", library.vaultCounts.count, "shelves")
    }
}
