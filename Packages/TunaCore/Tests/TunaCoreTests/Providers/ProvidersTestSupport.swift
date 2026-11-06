import XCTest
@testable import TunaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fixtures under Tests/TunaCoreTests/Fixtures/providers.
enum ProvidersFixture {
    static func url(_ name: String, _ ext: String = "json") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/providers"),
                      "missing fixture \(name).\(ext)")
    }

    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        try Data(contentsOf: url(name, ext))
    }
}

/// Records every request, answers from a route table, and measures how many requests were ever in flight at once
/// (each request stays "in flight" for a few ms, so an overlapping caller would be caught).
actor ProvidersFakeHTTPClient: HTTPClient {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private var routes: [String: Reply] = [:]
    private(set) var log: [String] = []
    private(set) var requests: [HTTPRequest] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func set(_ route: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        routes[route] = Reply(status: status, body: body, headers: headers)
    }

    func set(_ route: String, status: Int = 200, text: String) {
        routes[route] = Reply(status: status, body: Data(text.utf8))
    }

    func resetLog() {
        log = []
        requests = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = Self.route(request.url)
        log.append(route)
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        try? await Task.sleep(nanoseconds: 3_000_000)
        inFlight -= 1
        guard let reply = routes[route] else { return HTTPResponse(status: 404, body: Data("no route".utf8), url: request.url) }
        return HTTPResponse(status: reply.status, headers: reply.headers, body: reply.body, url: request.url)
    }

    /// "account" (player_api.php without action), the action name, "xmltv", or the URL path.
    static func route(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.path.hasSuffix("/player_api.php") {
            return components?.queryItems?.first(where: { $0.name == "action" })?.value ?? "account"
        }
        if url.path.hasSuffix("/xmltv.php") { return "xmltv" }
        return url.path
    }
}

/// Thread-safe collector for progress callbacks.
final class ProvidersProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncProgress] = []

    func append(_ progress: SyncProgress) { lock.withLock { items.append(progress) } }
    var all: [SyncProgress] { lock.withLock { items } }
}

/// A session wired to the fake client through a real `RequestGovernor` and a `ManualClock` (pacing sleeps advance the
/// manual clock instead of waiting).
struct ProvidersHarness {
    static let password = "s3cr3t+pass"
    static let xtreamSequence = ["account", "get_live_categories", "get_vod_categories", "get_series_categories",
                                 "get_live_streams", "get_vod_streams", "get_series"]

    let config: ProviderConfig
    let client: ProvidersFakeHTTPClient
    let clock: ManualClock
    let cache: CacheStore
    let governor: RequestGovernor
    let session: ProviderSession

    init(config: ProviderConfig = ProvidersHarness.xtreamConfig(), client: ProvidersFakeHTTPClient = ProvidersFakeHTTPClient(),
         cache: CacheStore = CacheStore(files: FileStore.temporary()), clock: ManualClock = ManualClock()) {
        self.config = config
        self.client = client
        self.clock = clock
        self.cache = cache
        governor = RequestGovernor(providerID: config.id, policy: GovernorPolicy(minInterval: 0.5, jitter: 0), client: client,
                                   clock: clock, persistence: nil, random: { 0 })
        session = ProviderSession(config: config, password: ProvidersHarness.password, governor: governor, cache: cache, clock: clock)
    }

    /// A second session over the same cache (a relaunch), with its own fresh client.
    func relaunched(client newClient: ProvidersFakeHTTPClient = ProvidersFakeHTTPClient()) -> ProvidersHarness {
        ProvidersHarness(config: config, client: newClient, cache: cache, clock: clock)
    }

    static func xtreamConfig(liveFormat: LiveStreamFormat = .auto, userAgent: UserAgentPreset = .vlc) -> ProviderConfig {
        ProviderConfig(id: "prov-1", name: "Test Panel", kind: .xtream, serverURL: "  panel.example.com:8080/player_api.php?username=x ",
                       username: "tuna_user", userAgent: userAgent, liveFormat: liveFormat)
    }

    static func m3uConfig() -> ProviderConfig {
        ProviderConfig(id: "prov-m3u", name: "Test Playlist", kind: .m3u,
                       serverURL: "http://lists.example.net/get.php?username=u&password=p&type=m3u_plus")
    }

    func installXtreamRoutes() async throws {
        await client.set("account", body: try ProvidersFixture.data("xtream_account"))
        await client.set("get_live_categories", body: try ProvidersFixture.data("xtream_live_categories"))
        await client.set("get_vod_categories", body: try ProvidersFixture.data("xtream_vod_categories"))
        await client.set("get_series_categories", body: try ProvidersFixture.data("xtream_series_categories"))
        await client.set("get_live_streams", body: try ProvidersFixture.data("xtream_live_streams"))
        await client.set("get_vod_streams", body: try ProvidersFixture.data("xtream_vod_streams"))
        await client.set("get_series", body: try ProvidersFixture.data("xtream_series"))
        await client.set("get_vod_info", body: try ProvidersFixture.data("xtream_vod_info"))
        await client.set("get_series_info", body: try ProvidersFixture.data("xtream_series_info_dict"))
        await client.set("get_short_epg", body: try ProvidersFixture.data("xtream_short_epg"))
        await client.set("xmltv", body: try ProvidersFixture.data("guide", "xml"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: cache.files.baseURL)
    }
}

/// UTC date helper for expectations.
func providersUTC(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? Date()
}

/// Independent FNV-1a 64 implementation to check M3U stream ids.
func providersFNV1a64Hex(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}
