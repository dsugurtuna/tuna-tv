import Foundation

/// Implementation behind `XtreamDecoder`: maps already-parsed JSON (see `XtreamJSONKit.parse`) to model types.
/// Field knowledge adapted from IPTVMac's `XtreamClient`/`ItemInfo` (GPL-3.0) and real panel quirks:
/// ids as strings or numbers, `null`/`""`/`false` for "empty", `"info": []` for unknown titles, episodes as a
/// season-keyed object or an array, `backdrop_path` as a string or an array, base64 EPG text.
enum XtreamDecodingKit {
    private typealias J = XtreamJSONKit
    private typealias T = ProviderTextKit

    // MARK: - Account

    static func account(json: Any, now: Date) throws -> AccountInfo {
        guard let root = J.dict(json) else {
            // Some panels answer bad credentials with an empty body, `[]`, `null` or `false`.
            if J.isEmptyValue(json) || json is [Any] { return AccountInfo(isAuthorized: false, fetchedAt: now) }
            throw TunaError.decoding("The provider sent an unexpected account answer.")
        }
        guard let user = J.dict(root["user_info"]) else { return AccountInfo(isAuthorized: false, fetchedAt: now) }
        let server = J.dict(root["server_info"]) ?? [:]
        let status = T.line(J.string(user["status"]), max: 60)
        let timeZoneID = T.line(J.string(server["timezone"]), max: 80)
        let timeZone = timeZoneID.flatMap { TimeZone(identifier: $0) }
        var serverNow = J.double(server["timestamp_now"]).flatMap(T.unixDate)
        if serverNow == nil, let text = J.string(server["time_now"]) { serverNow = T.panelDateTime(text, timeZone: timeZone) }
        return AccountInfo(
            isAuthorized: J.bool(user["auth"]) ?? (status != nil),
            status: status,
            expiresAt: date(user["exp_date"]),
            createdAt: date(user["created_at"]),
            isTrial: J.bool(user["is_trial"]) ?? false,
            activeConnections: J.int(user["active_cons"]).map { max(0, $0) },
            maxConnections: J.int(user["max_connections"]).flatMap { $0 > 0 ? $0 : nil },
            allowedOutputFormats: outputFormats(user["allowed_output_formats"]),
            serverTimezone: timeZoneID,
            serverTimeNow: serverNow,
            serverMessage: T.paragraph(J.string(user["message"]) ?? J.string(server["message"]), max: 1000),
            fetchedAt: now)
    }

    /// The panel's time zone (for timeshift URLs and EPG wall-clock times): `server_info.timezone`, or, when that
    /// name is missing or unknown here, the offset between the panel's wall clock (`time_now`) and `timestamp_now`.
    static func serverTimeZone(json: Any) -> TimeZone? {
        guard let server = J.dict(J.dict(json)?["server_info"]) else { return nil }
        if let name = J.string(server["timezone"]), let zone = TimeZone(identifier: name) { return zone }
        guard let stamp = J.double(server["timestamp_now"]), let text = J.string(server["time_now"]),
              let wall = T.panelDateTime(text, timeZone: nil) else { return nil }
        let offset = Int(((wall.timeIntervalSince1970 - stamp) / 900).rounded()) * 900
        guard abs(offset) <= 14 * 3600 else { return nil }
        return TimeZone(secondsFromGMT: offset)
    }

    private static func outputFormats(_ value: Any?) -> [String] {
        var result: [String] = []
        for entry in J.array(value).compactMap({ J.string($0) }) + (value is String ? J.strings(value) : []) {
            for part in entry.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
                let format = part.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if !format.isEmpty && !result.contains(format) { result.append(format) }
            }
        }
        return result
    }

    /// Unix seconds (number or numeric string; ms scaled; 0/"never" nil) or a "yyyy-MM-dd[ HH:mm[:ss]]" text in UTC.
    static func date(_ value: Any?) -> Date? {
        if let seconds = J.double(value) { return T.unixDate(seconds) }
        if let text = J.string(value) { return T.panelDateTime(text, timeZone: nil) }
        return nil
    }

    // MARK: - Lists

    /// Rows of a list endpoint. Arrays and index-keyed objects are lists; `null`/`false`/`""`/`[]` mean "no rows";
    /// the auth object (sent by some panels for any action when credentials fail) is `.unauthorized`; anything
    /// else is `.decoding`.
    static func listRows(_ json: Any, what: String) throws -> [[String: Any]] {
        if let list = json as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        if J.isEmptyValue(json) { return [] }
        if let object = json as? [String: Any] {
            if object.keys.allSatisfy({ Int($0) != nil }) { return J.rows(object) }
            if let user = J.dict(object["user_info"]), J.bool(user["auth"]) != true {
                throw TunaError.unauthorized("The provider did not accept this username and password.")
            }
        }
        throw TunaError.decoding("The provider sent an unexpected \(what) list.")
    }

    static func categories(json: Any, kind: StreamKind) throws -> [RawCategory] {
        var seen = Set<String>()
        var result: [RawCategory] = []
        for row in try listRows(json, what: "category") {
            guard let id = J.firstString(row, ["category_id", "id"]), seen.insert(id).inserted else { continue }
            let name = T.line(J.firstString(row, ["category_name", "name"]), max: 300) ?? id
            let parent = J.string(row["parent_id"]).flatMap { $0 == "0" ? nil : $0 }
            result.append(RawCategory(id: id, name: name, kind: kind, parentID: parent))
        }
        return result
    }

    static func items(json: Any, kind: StreamKind, providerID: ProviderID, categories: [String: String]) throws -> [RawItem] {
        let rows = try listRows(json, what: kind == .live ? "channel" : kind == .movie ? "movie" : "series")
        var seen = Set<String>()
        var result: [RawItem] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            // A panel that lists a stream in two categories repeats its id: the first one wins (ids must be unique).
            guard let item = item(row, kind: kind, providerID: providerID, categories: categories),
                  seen.insert(item.ref.streamID).inserted else { continue }
            result.append(item)
        }
        return result
    }

    static func item(_ row: [String: Any], kind: StreamKind, providerID: ProviderID, categories: [String: String]) -> RawItem? {
        let idKeys = kind == .series ? ["series_id", "id"] : ["stream_id", "id"]
        guard let streamID = J.firstString(row, idKeys) else { return nil }
        let categoryID = J.string(row["category_id"]) ?? J.array(row["category_ids"]).lazy.compactMap({ J.string($0) }).first
        let iconKeys = kind == .series ? ["cover", "stream_icon", "cover_big"] : ["stream_icon", "cover", "movie_image"]
        let addedKeys = kind == .series ? ["last_modified", "added"] : ["added", "last_modified"]
        let releaseDate = T.line(J.firstString(row, ["releaseDate", "release_date", "releasedate"]), max: 40)
        let year = J.int(row["year"]).flatMap { (1900...2100).contains($0) ? $0 : nil } ?? releaseDate.flatMap(T.year(in:))

        var item = RawItem(
            ref: StreamRef(providerID: providerID, kind: kind, streamID: streamID),
            name: T.line(J.firstString(row, ["name", "title"]), max: 500) ?? "",
            categoryID: categoryID,
            categoryName: categoryID.flatMap { categories[$0] },
            iconURL: firstImage(row, iconKeys),
            addedAt: addedKeys.lazy.compactMap({ date(row[$0]) }).first,
            providerRating: rating(row),
            tmdbID: tmdbID(row["tmdb"]) ?? tmdbID(row["tmdb_id"]),
            imdbID: imdbID(row["imdb_id"]) ?? imdbID(row["imdb"]),
            year: year,
            plot: T.paragraph(J.firstString(row, ["plot", "description"])),
            cast: joinedText(row["cast"]) ?? joinedText(row["actors"]),
            director: joinedText(row["director"]),
            genre: joinedText(row["genre"]),
            releaseDate: releaseDate,
            backdropURLs: backdrops(row),
            trailerYouTubeID: T.youTubeID(J.firstString(row, ["youtube_trailer", "trailer"])),
            episodeRunTimeMinutes: J.string(row["episode_run_time"]).flatMap(T.minutes(fromDuration:)).map { Int($0.rounded()) })

        switch kind {
        case .live:
            item.channelNumber = J.int(row["num"]).flatMap { $0 > 0 ? $0 : nil }
            item.epgChannelID = T.line(J.string(row["epg_channel_id"]), max: 200)
            if J.bool(row["tv_archive"]) == true {
                let days = J.int(row["tv_archive_duration"]) ?? 0
                item.catchupDays = days > 0 ? min(days, 365) : 1
            }
        case .movie:
            item.containerExtension = XtreamURLKit.cleanExtension(J.string(row["container_extension"]))
        case .series, .episode:
            break
        }
        return item
    }

    // MARK: - Details

    static func vodInfo(json: Any) throws -> RawItemInfo {
        guard let root = J.dict(json) else {
            // `[]`, `null`, `false`: the panel knows nothing about this title. Not an error.
            if J.isEmptyValue(json) || json is [Any] { return RawItemInfo() }
            throw TunaError.decoding("The provider sent unexpected movie details.")
        }
        let infoObject = J.dict(root["info"]) ?? ((root["info"] == nil && root["movie_data"] == nil) ? root : nil)
        var info = infoObject.map(itemInfo) ?? RawItemInfo()
        if let movie = J.dict(root["movie_data"]) {
            if info.name == nil { info.name = T.line(J.firstString(movie, ["name", "title"]), max: 500) }
            if info.containerExtension == nil {
                info.containerExtension = XtreamURLKit.cleanExtension(J.string(movie["container_extension"]))
            }
            if info.posterURL == nil { info.posterURL = firstImage(movie, ["stream_icon", "cover", "movie_image"]) }
        }
        return info
    }

    static func seriesInfo(json: Any, seriesRef: StreamRef, now: Date) throws -> RawSeriesInfo {
        guard let root = J.dict(json) else {
            if J.isEmptyValue(json) || json is [Any] {
                return RawSeriesInfo(seriesRef: seriesRef, info: nil, seasons: [], episodes: [], fetchedAt: now)
            }
            throw TunaError.decoding("The provider sent unexpected series details.")
        }
        let info = J.dict(root["info"]).flatMap { $0.isEmpty ? nil : itemInfo($0) }

        var episodes: [RawEpisode] = []
        var seen = Set<String>()
        func add(_ row: [String: Any], defaultSeason: Int?, index: Int) {
            guard let id = J.firstString(row, ["id", "stream_id", "episode_id"]), seen.insert(id).inserted else { return }
            let details = J.dict(row["info"]) ?? [:]
            let season = J.int(row["season"]) ?? J.int(details["season"]) ?? defaultSeason ?? 1
            let number = J.int(row["episode_num"]) ?? J.int(row["episode"]) ?? J.int(details["episode_num"]) ?? (index + 1)
            let title = T.line(J.firstString(row, ["title", "name"]) ?? J.string(details["name"]), max: 500) ?? "Episode \(number)"
            episodes.append(RawEpisode(
                ref: StreamRef(providerID: seriesRef.providerID, kind: .episode, streamID: id),
                season: season,
                episode: number,
                title: title,
                containerExtension: XtreamURLKit.cleanExtension(J.string(row["container_extension"])),
                plot: T.paragraph(J.firstString(details, ["plot", "description", "overview"]), max: 4000),
                durationSeconds: durationSeconds(details),
                airDate: T.line(J.firstString(details, ["releasedate", "release_date", "releaseDate", "air_date"]), max: 40),
                stillURL: firstImage(details, ["movie_image", "cover_big", "cover", "still_path"]),
                rating: rating(details),
                tech: tech(details)))
        }

        let rawEpisodes = root["episodes"]
        if let bySeason = rawEpisodes as? [String: Any] {
            let keys = bySeason.keys.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }
            for key in keys {
                for (index, row) in J.rows(bySeason[key]).enumerated() { add(row, defaultSeason: Int(key), index: index) }
            }
        } else if let list = rawEpisodes as? [Any] {
            for (position, element) in list.enumerated() {
                if let group = element as? [Any] {
                    for (index, row) in group.compactMap({ $0 as? [String: Any] }).enumerated() {
                        add(row, defaultSeason: position + 1, index: index)
                    }
                } else if let row = element as? [String: Any] {
                    add(row, defaultSeason: nil, index: position)
                }
            }
        }
        episodes.sort { ($0.season, $0.episode, $0.title) < ($1.season, $1.episode, $1.title) }

        var seasons: [RawSeason] = []
        var listedSeasons = Set<Int>()
        for row in J.rows(root["seasons"]) {
            guard let number = J.firstInt(row, ["season_number", "season", "number"]), listedSeasons.insert(number).inserted else { continue }
            seasons.append(RawSeason(
                number: number,
                name: T.line(J.string(row["name"]), max: 200),
                overview: T.paragraph(J.string(row["overview"]), max: 4000),
                airDate: T.line(J.firstString(row, ["air_date", "airdate", "releaseDate"]), max: 40),
                coverURL: firstImage(row, ["cover_big", "cover", "cover_tmdb"]),
                episodeCount: J.int(row["episode_count"]).flatMap { $0 >= 0 ? $0 : nil }))
        }
        // Panels often send `"seasons": []` while listing episodes: derive the missing seasons from the episodes.
        let counts = Dictionary(grouping: episodes, by: { $0.season }).mapValues { $0.count }
        for (number, count) in counts where !listedSeasons.contains(number) {
            seasons.append(RawSeason(number: number, episodeCount: count))
        }
        for index in seasons.indices where seasons[index].episodeCount == nil {
            seasons[index].episodeCount = counts[seasons[index].number]
        }
        seasons.sort { $0.number < $1.number }
        return RawSeriesInfo(seriesRef: seriesRef, info: info, seasons: seasons, episodes: episodes, fetchedAt: now)
    }

    /// `info` object of `get_vod_info` / `get_series_info`.
    static func itemInfo(_ info: [String: Any]) -> RawItemInfo {
        RawItemInfo(
            tmdbID: tmdbID(info["tmdb_id"]) ?? tmdbID(info["tmdb"]),
            name: T.line(J.firstString(info, ["name", "title"]), max: 500),
            originalName: T.line(J.firstString(info, ["o_name", "original_name", "original_title"]), max: 500),
            plot: T.paragraph(J.firstString(info, ["plot", "description", "overview"])),
            cast: joinedText(info["cast"]) ?? joinedText(info["actors"]),
            director: joinedText(info["director"]),
            genre: joinedText(info["genre"]),
            country: joinedText(info["country"]),
            releaseDate: T.line(J.firstString(info, ["releasedate", "release_date", "releaseDate", "air_date"]), max: 40),
            rating: rating(info),
            durationSeconds: durationSeconds(info),
            posterURL: firstImage(info, ["movie_image", "cover_big", "cover", "stream_icon"]),
            backdropURLs: backdrops(info),
            trailerYouTubeID: T.youTubeID(J.firstString(info, ["youtube_trailer", "trailer"])),
            tech: tech(info),
            containerExtension: XtreamURLKit.cleanExtension(J.string(info["container_extension"])))
    }

    // MARK: - Short EPG

    static func shortEPG(json: Any, channelKey: String, serverTimeZone: TimeZone?) throws -> [Program] {
        let rows: [[String: Any]]
        if let root = J.dict(json) {
            rows = J.rows(root["epg_listings"])
        } else if json is [Any] {
            rows = J.rows(json)
        } else if J.isEmptyValue(json) {
            return []
        } else {
            throw TunaError.decoding("The provider sent an unexpected programme list.")
        }
        var programs: [Program] = []
        var starts = Set<Int>()
        for row in rows {
            guard let start = epgDate(row, stampKey: "start_timestamp", textKeys: ["start"], timeZone: serverTimeZone),
                  let end = epgDate(row, stampKey: "stop_timestamp", textKeys: ["stop", "end"], timeZone: serverTimeZone),
                  end > start else { continue }
            let rawTitle = J.string(row["title"]) ?? ""
            guard let title = T.line(T.base64Text(rawTitle) ?? rawTitle, max: 500),
                  starts.insert(Int(start.timeIntervalSince1970)).inserted else { continue }
            let summary = J.firstString(row, ["description", "desc"]).flatMap { T.paragraph(T.base64Text($0) ?? $0, max: 4000) }
            programs.append(Program(channelKey: channelKey, start: start, end: end, title: title, summary: summary,
                                    isLive: T.looksLive(title), hasArchive: J.bool(row["has_archive"]) ?? false))
        }
        return programs.sorted { $0.start < $1.start }
    }

    private static func epgDate(_ row: [String: Any], stampKey: String, textKeys: [String], timeZone: TimeZone?) -> Date? {
        if let stamp = J.double(row[stampKey]).flatMap(T.unixDate) { return stamp }
        if stampKey == "stop_timestamp", let stamp = J.double(row["end_timestamp"]).flatMap(T.unixDate) { return stamp }
        return J.firstString(row, textKeys).flatMap { T.panelDateTime($0, timeZone: timeZone) }
    }

    // MARK: - Field readers

    /// 0...10, one decimal. `rating` may be 0-10 or 0-100 ("85"); else `rating_5based` × 2. 0 means unrated.
    static func rating(_ object: [String: Any]) -> Double? {
        func number(_ value: Any?) -> Double? { J.double(value) ?? J.string(value).flatMap(T.firstNumber) }
        func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        if let value = number(object["rating"]), value > 0 {
            if value <= 10 { return round1(value) }
            if value <= 100 { return round1(value / 10) }
        }
        if let five = number(object["rating_5based"]), five > 0, five <= 5 { return round1(five * 2) }
        return nil
    }

    static func tmdbID(_ value: Any?) -> Int? {
        if let number = J.int(value) { return number > 0 ? number : nil }
        guard let text = J.string(value) else { return nil }
        // "https://www.themoviedb.org/movie/603-the-matrix" or "603-the-matrix".
        let segment = text.split(separator: "/").last.map(String.init) ?? text
        let digits = segment.prefix { $0.isASCII && $0.isNumber }
        guard let id = Int(digits), id > 0 else { return nil }
        return id
    }

    static func imdbID(_ value: Any?) -> String? {
        guard let text = J.string(value)?.lowercased() else { return nil }
        let digits = text.hasPrefix("tt") ? String(text.dropFirst(2)) : text
        guard (5...10).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "tt" + digits
    }

    /// Text of a field that may be a string, a number or an array of strings (joined with ", ").
    static func joinedText(_ value: Any?, max: Int = 1000) -> String? {
        let parts = J.strings(value)
        guard !parts.isEmpty else { return nil }
        return T.line(parts.joined(separator: ", "), max: max)
    }

    static func firstImage(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            for candidate in J.strings(object[key]) {
                if let url = T.httpURLString(candidate) { return url }
            }
        }
        return nil
    }

    static func backdrops(_ object: [String: Any]) -> [String] {
        var result: [String] = []
        for key in ["backdrop_path", "backdrop"] {
            for candidate in J.strings(object[key]) {
                if let url = T.httpURLString(candidate), !result.contains(url) { result.append(url) }
                if result.count >= 20 { return result }
            }
        }
        return result
    }

    static func durationSeconds(_ object: [String: Any]) -> Int? {
        if let seconds = J.double(object["duration_secs"]), seconds >= 30, seconds <= 86_400 { return Int(seconds.rounded()) }
        for key in ["duration", "runtime", "episode_run_time"] {
            if let text = J.string(object[key]), let minutes = T.minutes(fromDuration: text) { return Int((minutes * 60).rounded()) }
        }
        return nil
    }

    /// ffprobe-style `video` / `audio` objects (or arrays of them, or plain codec strings) plus `bitrate`.
    static func tech(_ object: [String: Any]) -> StreamTechInfo? {
        func firstObject(_ value: Any?) -> [String: Any]? {
            if let dict = value as? [String: Any] { return dict.isEmpty ? nil : dict }
            return (value as? [Any])?.lazy.compactMap({ $0 as? [String: Any] }).first
        }
        var tech = StreamTechInfo()
        if let video = firstObject(object["video"]) {
            tech.videoCodec = T.line(J.string(video["codec_name"]), max: 40)
            tech.width = J.int(video["width"]).flatMap { $0 > 0 ? $0 : nil }
            tech.height = J.int(video["height"]).flatMap { $0 > 0 ? $0 : nil }
        } else {
            tech.videoCodec = T.line(J.strings(object["video"]).first, max: 40)
        }
        if let audio = firstObject(object["audio"]) {
            tech.audioCodec = T.line(J.string(audio["codec_name"]), max: 40)
            tech.audioChannels = J.int(audio["channels"]).flatMap { $0 > 0 ? $0 : nil }
        } else {
            tech.audioCodec = T.line(J.strings(object["audio"]).first, max: 40)
        }
        if let bitrate = J.double(object["bitrate"]), bitrate > 0 {
            tech.bitrateKbps = Int((bitrate > 200_000 ? bitrate / 1000 : bitrate).rounded())
        }
        return tech == StreamTechInfo() ? nil : tech
    }
}
