import Foundation
import XCTest
@testable import TunaCore

final class AppStateStoreTests: XCTestCase {
    private var files: FileStore!
    private var store: AppStateStore!

    override func setUp() {
        super.setUp()
        files = FileStore.temporary()
        store = AppStateStore(files: files)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: files.baseURL)
        files = nil
        store = nil
        super.tearDown()
    }

    private func write(_ json: String, to path: String) throws {
        try files.writeData(Data(json.utf8), to: path)
    }

    func testDefaultsWhenNothingWasSaved() {
        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertEqual(store.loadProviders(), [])
        XCTAssertEqual(store.loadUserState(), UserState())
        XCTAssertNil(store.load(providerID: "p1"))
    }

    func testDocumentsRoundTrip() {
        var settings = AppSettings(hasCompletedOnboarding: true, onlineMetadata: false)
        settings.content.worlds = WorldSelection.english.adding(country: "TR", language: "tr")
        settings.playback.zapDebounce = 0.8
        store.saveSettings(settings)
        XCTAssertEqual(store.loadSettings(), settings)

        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [
            ProviderConfig(id: "a", name: "Main", kind: .xtream, serverURL: "http://panel.test:8080", username: "alice",
                           userAgent: .custom("MyPlayer/1.0"), pacing: .gentle, createdAt: created),
            ProviderConfig(id: "b", name: "Playlist", kind: .m3u, serverURL: "http://lists.test/x.m3u", createdAt: created),
        ]
        store.saveProviders(providers)
        XCTAssertEqual(store.loadProviders(), providers)

        var state = UserState()
        state.toggleMyList("movie:matrix:1999")
        state.recordChannel("live:bbcone:GB")
        state.progress["movie:matrix:1999"] = WatchProgress(titleID: "movie:matrix:1999", variantID: "a|movie|1",
                                                            position: 120.5, duration: 8160, updatedAt: created)
        state.record(HistoryEntry(kind: .title, itemID: "movie:matrix:1999", watchedAt: created, secondsWatched: 120))
        store.saveUserState(state)
        XCTAssertEqual(store.loadUserState(), state)

        XCTAssertEqual(files.list(""), ["providers.json", "settings.json", "user_state.json"])
    }

    func testGovernorStateRoundTripAndSafeFileNames() {
        var state = GovernorPersistedState(breaker: .open(until: Date(timeIntervalSince1970: 1_800_000_300), reason: "HTTP 429 from panel.test", tripCount: 2),
                                           tripCount: 2, dayStamp: "2027-01-15", requestsToday: 42,
                                           lastRequestAt: Date(timeIntervalSince1970: 1_800_000_000.5))
        state.lastTripAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(state, providerID: "C0FFEE-1234")
        XCTAssertEqual(store.load(providerID: "C0FFEE-1234"), state)
        XCTAssertTrue(files.exists("governor/C0FFEE-1234.json"))

        let blocked = GovernorPersistedState(breaker: .authBlocked(reason: "HTTP 403"), tripCount: 0, dayStamp: "2027-01-15")
        store.save(blocked, providerID: "../../evil/id")
        XCTAssertEqual(store.load(providerID: "../../evil/id"), blocked)
        XCTAssertEqual(files.list("governor").count, 2)
        XCTAssertFalse(files.list("").contains("evil"))
        XCTAssertNotEqual(AppStateStore.Paths.fileName(for: "a/b"), AppStateStore.Paths.fileName(for: "a_b"))
        XCTAssertNil(store.load(providerID: "unknown"))
    }

    func testCorruptDocumentsFallBackToDefaultsAndKeepACopy() throws {
        try write("{ this is not json", to: "settings.json")
        try write("[1, 2", to: "providers.json")
        try write("\u{0}\u{1}garbage", to: "user_state.json")
        try write("nope", to: "governor/p1.json")

        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertEqual(store.loadProviders(), [])
        XCTAssertEqual(store.loadUserState(), UserState())
        XCTAssertNil(store.load(providerID: "p1"))
        XCTAssertEqual(files.readData("settings.json.corrupt"), Data("{ this is not json".utf8))
        XCTAssertTrue(files.exists("providers.json.corrupt"))

        // Saving afterwards works normally.
        var settings = AppSettings()
        settings.reduceMotion = true
        store.saveSettings(settings)
        XCTAssertEqual(store.loadSettings(), settings)
    }

    func testMissingKeysAreFilledFromDefaults() throws {
        // As written by an older version: no "reduceMotion", "playback" lacks "heroTrailers", plus an unknown key.
        try write("""
        {"content":{"worlds":{"languages":["tr","en"],"countries":["TR"]},"showcaseQuality":"fullHDPlus",
         "autoRelaxShowcase":false,"relaxThreshold":10,"hideAdult":true,"preferredAudioLanguages":["tr"],
         "preferredSubtitleLanguages":[],"showLowQuality":false},
         "playback":{"zapDebounce":1.25,"autoplayNextEpisode":false,"upNextCountdown":5,"liveTimeshiftMinutes":60,
         "resumeThresholdSeconds":30},
         "hasCompletedOnboarding":true,"onlineMetadata":false,"futureFeature":{"enabled":true}}
        """, to: "settings.json")

        let settings = store.loadSettings()
        XCTAssertEqual(settings.content.worlds.languages, ["tr", "en"])
        XCTAssertEqual(settings.content.showcaseQuality, .fullHDPlus)
        XCTAssertEqual(settings.playback.zapDebounce, 1.25)
        XCTAssertEqual(settings.playback.upNextCountdown, 5)
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.onlineMetadata)
        XCTAssertEqual(settings.playback.heroTrailers, PlaybackPreferences().heroTrailers)
        XCTAssertEqual(settings.reduceMotion, AppSettings().reduceMotion)
        XCTAssertFalse(files.exists("settings.json.corrupt"))
    }

    func testOneBadProviderDoesNotLoseTheOthers() throws {
        try write("""
        [
         {"id":"good","name":"Main","kind":"xtream","serverURL":"http://panel.test","username":"alice",
          "userAgent":{"vlc":{}},"pacing":"balanced","maxStreams":1,"liveFormat":"auto","syncInterval":86400,
          "isEnabled":true,"createdAt":"2027-01-15T08:00:00Z"},
         {"name":"No id at all","kind":"xtream","serverURL":"http://x.test"},
         {"id":"bad-kind","name":"Broken","kind":"carrier-pigeon","serverURL":"http://y.test"},
         {"id":"old","name":"Old format","kind":"m3u","serverURL":"http://lists.test/a.m3u","userAgent":{"custom":{"_0":"Old/1.0"}}},
         {"id":"good","name":"Duplicate","kind":"xtream","serverURL":"http://dup.test"}
        ]
        """, to: "providers.json")

        let providers = store.loadProviders()
        XCTAssertEqual(providers.map(\.id), ["good", "old"])
        XCTAssertEqual(providers.first?.username, "alice")
        XCTAssertEqual(providers.first?.createdAt, Date(timeIntervalSince1970: 1_800_000_000))
        let old = try XCTUnwrap(providers.last)
        XCTAssertEqual(old.kind, .m3u)
        XCTAssertEqual(old.userAgent, .custom("Old/1.0"))
        XCTAssertEqual(old.pacing, .balanced)
        XCTAssertTrue(files.exists("providers.json.corrupt"))
    }
}
