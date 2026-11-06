import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OMDb (optional key): IMDb rating/votes, Rotten Tomatoes, Metacritic, awards, box office.
/// `https://www.omdbapi.com/?i=<imdb id>&apikey=<key>`; "N/A" values become nil. An unknown IMDb id yields all-nil
/// values; a rejected key throws `TunaError.unauthorized`, the daily limit throws `TunaError.http(status: 429, …)`.
public struct OMDbClient: Sendable {
    public init(apiKey: String, http: HTTPClient, limiter: HostLimiter) {
        self.apiKey = apiKey.tunaTrimmed
        self.fetcher = MetadataSupport.Fetcher(http: http, limiter: limiter)
        TunaLog.shared.registerSecret(self.apiKey)
    }

    let apiKey: String
    let fetcher: MetadataSupport.Fetcher

    static let host = "www.omdbapi.com"
    static let base = "https://www.omdbapi.com"

    public func ratings(imdbID: String) async throws -> (imdb: Double?, votes: Int?, rottenTomatoes: Int?, metacritic: Int?, awards: String?, boxOffice: String?) {
        guard !apiKey.isEmpty else { throw TunaError.notConfigured("Add an OMDb API key in Settings for IMDb, Rotten Tomatoes and Metacritic ratings.") }
        let id = imdbID.tunaTrimmed.lowercased()
        guard id.count > 2, id.hasPrefix("tt"), id.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw TunaError.invalidInput("Invalid IMDb id")
        }
        guard let url = MetadataSupport.makeURL(Self.base, path: "/", query: [("i", id), ("apikey", apiKey)]) else {
            throw TunaError.invalidInput("Could not build OMDb request")
        }
        let response = try await fetcher.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 15))
        let payload = try? JSONDecoder().decode(Payload.self, from: response.body)
        let message = payload?.error?.lowercased() ?? ""
        guard response.isSuccess else {
            if message.contains("limit") { throw TunaError.http(status: 429, host: Self.host) }
            if response.status == 401 || response.status == 403 { throw TunaError.unauthorized("OMDb key rejected") }
            throw TunaError.http(status: response.status, host: Self.host)
        }
        guard let payload else { throw TunaError.decoding("OMDb: unexpected response") }
        if payload.response?.lowercased() == "false" {
            if message.contains("limit") { throw TunaError.http(status: 429, host: Self.host) }
            if message.contains("api key") || message.contains("apikey") { throw TunaError.unauthorized("OMDb key rejected") }
            return (nil, nil, nil, nil, nil, nil)
        }
        let values = Self.parse(payload)
        return (values.imdb, values.votes, values.rottenTomatoes, values.metacritic, values.awards, values.boxOffice)
    }

    // MARK: - Parsing

    struct Values: Equatable {
        var imdb: Double?
        var votes: Int?
        var rottenTomatoes: Int?
        var metacritic: Int?
        var awards: String?
        var boxOffice: String?
    }

    struct Payload: Decodable {
        struct Rating: Decodable {
            let source: String?
            let value: String?
            enum CodingKeys: String, CodingKey {
                case source = "Source"
                case value = "Value"
            }
        }

        let response: String?
        let error: String?
        let imdbRating: String?
        let imdbVotes: String?
        let metascore: String?
        let awards: String?
        let boxOffice: String?
        let ratings: MetadataSupport.Lossy<Rating>?

        enum CodingKeys: String, CodingKey {
            case imdbRating, imdbVotes
            case response = "Response"
            case error = "Error"
            case metascore = "Metascore"
            case awards = "Awards"
            case boxOffice = "BoxOffice"
            case ratings = "Ratings"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
            response = text(.response)
            error = text(.error)
            imdbRating = text(.imdbRating)
            imdbVotes = text(.imdbVotes)
            metascore = text(.metascore)
            awards = text(.awards)
            boxOffice = text(.boxOffice)
            ratings = (try? c.decodeIfPresent(MetadataSupport.Lossy<Rating>.self, forKey: .ratings)) ?? nil
        }
    }

    /// nil for "N/A", "", whitespace.
    static func available(_ text: String?) -> String? {
        guard let value = text?.tunaTrimmed, !value.isEmpty, value.uppercased() != "N/A" else { return nil }
        return value
    }

    static func parse(_ payload: Payload) -> Values {
        var values = Values()
        let ratings = payload.ratings?.values ?? []
        func rating(_ source: String) -> String? {
            available(ratings.first(where: { ($0.source ?? "").lowercased() == source })?.value)
        }
        values.imdb = available(payload.imdbRating).flatMap(Double.init)
            ?? rating("internet movie database").flatMap { Double($0.split(separator: "/").first.map(String.init) ?? "") }
        values.votes = available(payload.imdbVotes).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        values.rottenTomatoes = rating("rotten tomatoes").flatMap { Int($0.replacingOccurrences(of: "%", with: "").tunaTrimmed) }
        values.metacritic = rating("metacritic").flatMap { Int($0.split(separator: "/").first.map(String.init)?.tunaTrimmed ?? "") }
            ?? available(payload.metascore).flatMap { Int($0) }
        values.awards = available(payload.awards)
        values.boxOffice = available(payload.boxOffice)
        return values
    }
}
