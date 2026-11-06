import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// iptv-org public API (https://iptv-org.github.io/api/channels.json, logos.json, ...). Downloaded at most every
/// `maxAge`, slimmed to `IPTVOrgChannel`, cached on disk ("metadata/iptvorg/channels.json"). When a download fails
/// the cached copy is returned (stale or not); without one the error is thrown.
public struct IPTVOrgClient: Sendable {
    public init(http: HTTPClient, limiter: HostLimiter, files: FileStore) {
        self.fetcher = MetadataSupport.Fetcher(http: http, limiter: limiter)
        self.files = files
    }

    let fetcher: MetadataSupport.Fetcher
    let files: FileStore

    static let host = "iptv-org.github.io"
    static let channelsURL = "https://iptv-org.github.io/api/channels.json"
    static let logosURL = "https://iptv-org.github.io/api/logos.json"
    static let cachePath = "metadata/iptvorg/channels.json"

    public func channels(maxAge: TimeInterval) async throws -> [IPTVOrgChannel] {
        let cached = loadCache()
        if let cached, !cached.isEmpty, let modified = files.modifiedAt(Self.cachePath),
           Date().timeIntervalSince(modified) < maxAge {
            return cached
        }
        do {
            let fresh = try await download(previous: cached ?? [])
            do {
                try files.writeData(try JSONEncoder().encode(fresh), to: Self.cachePath)
            } catch {
                TunaLog.shared.log(MetadataSupport.logCategory, "iptv-org cache write failed: \(error)")
            }
            return fresh
        } catch {
            TunaLog.shared.log(MetadataSupport.logCategory, "iptv-org download failed: \(error)")
            if let cached, !cached.isEmpty { return cached }
            throw error
        }
    }

    /// The cached slim list, if any (no network).
    public func cachedChannels() -> [IPTVOrgChannel]? { loadCache() }

    func loadCache() -> [IPTVOrgChannel]? {
        guard let data = files.readData(Self.cachePath) else { return nil }
        return try? JSONDecoder().decode([IPTVOrgChannel].self, from: data)
    }

    func download(previous: [IPTVOrgChannel]) async throws -> [IPTVOrgChannel] {
        let channelData = try await get(Self.channelsURL)
        let raw = try MetadataSupport.decode(MetadataSupport.Lossy<RawChannel>.self, from: channelData, context: "iptv-org channels").values
        guard !raw.isEmpty else { throw TunaError.decoding("iptv-org channels.json has no channels") }

        var logos: [String: String] = [:]
        var logosLoaded = false
        do {
            let logoData = try await get(Self.logosURL)
            logos = Self.bestLogos(try MetadataSupport.decode(MetadataSupport.Lossy<RawLogo>.self, from: logoData, context: "iptv-org logos").values)
            logosLoaded = true
        } catch {
            TunaLog.shared.log(MetadataSupport.logCategory, "iptv-org logos unavailable: \(error)")
        }
        // Without logos.json keep the logos we knew before (channel lists change far more slowly than logos break).
        var previousLogos: [String: String] = [:]
        if !logosLoaded {
            for channel in previous { if let logo = channel.logoURL { previousLogos[channel.id] = logo } }
        }

        var seen = Set<String>()
        return raw.compactMap { channel in
            guard seen.insert(channel.id).inserted else { return nil }
            return IPTVOrgChannel(id: channel.id, name: channel.name, altNames: channel.altNames, network: channel.network,
                                  owners: channel.owners, country: channel.country, categories: channel.categories,
                                  isNSFW: channel.isNSFW, launched: channel.launched, closed: channel.closed,
                                  replacedBy: channel.replacedBy, website: channel.website,
                                  logoURL: logos[channel.id] ?? channel.legacyLogo ?? previousLogos[channel.id],
                                  languages: channel.languages)
        }
    }

    func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw TunaError.invalidInput("Bad iptv-org URL") }
        let response = try await fetcher.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 120))
        guard response.isSuccess else { throw TunaError.http(status: response.status, host: Self.host) }
        return response.body
    }

    /// One logo URL per channel: in-use first, raster (PNG/JPEG/WebP…) before SVG (ImageIO cannot draw SVG),
    /// channel-wide before feed-specific, then the widest (then tallest).
    static func bestLogos(_ logos: [RawLogo]) -> [String: String] {
        var best: [String: (rank: (Int, Int, Int, Int, Int), url: String)] = [:]
        for logo in logos {
            let lowerURL = logo.url.lowercased()
            let isSVG = (logo.format ?? "").uppercased() == "SVG" || lowerURL.hasSuffix(".svg")
            let rank = (logo.inUse ? 1 : 0, isSVG ? 0 : 1, logo.feed == nil ? 1 : 0, logo.width ?? 0, logo.height ?? 0)
            if let current = best[logo.channel], current.rank >= rank { continue }
            best[logo.channel] = (rank, logo.url)
        }
        return best.mapValues { $0.url }
    }

    // MARK: - Wire format (tolerant: arrays or ";"-lists, booleans as strings, unknown fields ignored)

    struct RawChannel: Decodable {
        let id: String
        let name: String
        let altNames: [String]
        let network: String?
        let owners: [String]
        let country: String
        let categories: [String]
        let isNSFW: Bool
        let launched: String?
        let closed: String?
        let replacedBy: String?
        let website: String?
        /// Older API versions carried the logo on the channel itself.
        let legacyLogo: String?
        /// Older API versions carried ISO 639-3 languages on the channel.
        let languages: [String]

        init(from decoder: Decoder) throws {
            let o = try MetadataSupport.LooseObject(decoder)
            guard let id = o.string("id"), let name = o.string("name") else {
                throw TunaError.decoding("iptv-org channel without id/name")
            }
            self.id = id
            self.name = name
            altNames = o.strings("alt_names")
            network = o.string("network")
            owners = o.strings("owners")
            country = (o.string("country") ?? id.split(separator: ".").last.map(String.init) ?? "").uppercased()
            categories = o.strings("categories").map { $0.lowercased() }
            isNSFW = o.bool("is_nsfw") ?? false
            launched = o.string("launched")
            closed = o.string("closed")
            replacedBy = o.string("replaced_by")
            website = o.string("website")
            legacyLogo = o.string("logo").flatMap { $0.hasPrefix("http") ? $0 : nil }
            languages = o.strings("languages")
        }
    }

    struct RawLogo: Decodable {
        let channel: String
        let feed: String?
        let inUse: Bool
        let width: Int?
        let height: Int?
        let format: String?
        let url: String

        init(from decoder: Decoder) throws {
            let o = try MetadataSupport.LooseObject(decoder)
            guard let channel = o.string("channel"), let url = o.string("url"), url.hasPrefix("http") else {
                throw TunaError.decoding("iptv-org logo without channel/url")
            }
            self.channel = channel
            self.url = url
            feed = o.string("feed")
            inUse = o.bool("in_use") ?? true
            width = o.int("width")
            height = o.int("height")
            format = o.string("format")
        }
    }
}
