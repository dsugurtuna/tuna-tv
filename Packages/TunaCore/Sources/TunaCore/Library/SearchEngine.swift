import Foundation

/// Search engine behind `SearchIndex` (owner: Library).
///
/// Index: every folded token (see `TextTokens`) is stored once in a byte-sorted flat buffer; each token owns a slice
/// of postings (document, field) in CSR layout. A query word matches the exact token (1.0), every token it prefixes
/// (0.75...0.95, closer lengths score higher; found by binary search) and, for words of 4+ characters without an
/// exact match, up to 10 tokens within an optimal-string-alignment distance of 1 (2 for 8+ characters) that share
/// the first or second character (0.6 / 0.45). Multi-word queries are AND-ed. Relevance = mean over words of
/// (match quality × field weight) + 0.5 for an exact full-name match + 0.15 when the name starts with the first
/// word + 0.1 × Ranker score. Results are ordered showcase (and people/programmes) first, then Vault, then by
/// relevance, then by Ranker score. All buffers are raw allocations so the hot loops stay fast in debug builds.
final class SearchEngine: @unchecked Sendable {
    enum Field: UInt8 {
        case name = 0, original, cast, director, keyword, channel, program, person
    }

    enum DocKind: UInt8 {
        case movie = 0, series, channel, person, program
    }

    private struct Doc {
        let target: SearchHit.Target
        let primary: String
        let secondary: String
    }

    private struct Candidate {
        let doc: Int32
        let score: Float
        let group: UInt8
        let rank: Float
    }

    static let firstWordFlag: UInt8 = 0x80
    static let maxPrefixPostings = 400_000
    static let maxFuzzyTokens = 10

    private let docs: [Doc]
    private let docCount: Int
    private let tokenCount: Int
    private let tokenBytes: UnsafeMutableBufferPointer<UInt8>
    private let tokenOffsets: UnsafeMutableBufferPointer<Int32>
    private let postingOffsets: UnsafeMutableBufferPointer<Int32>
    private let postingDocs: UnsafeMutableBufferPointer<Int32>
    private let postingFields: UnsafeMutableBufferPointer<UInt8>
    private let fieldWeights: UnsafeMutableBufferPointer<Float>
    private let docRank: UnsafeMutableBufferPointer<Float>
    /// 0 = showcase, people, programmes; 1 = Vault.
    private let docGroup: UnsafeMutableBufferPointer<UInt8>
    private let docKind: UnsafeMutableBufferPointer<UInt8>
    /// Word count of the document's primary name (for the exact-name bonus).
    private let docNameWords: UnsafeMutableBufferPointer<UInt8>

    // Scratch, guarded by `lock`.
    private let lock = NSLock()
    private var generation: UInt32 = 0
    private let wordStamp: UnsafeMutableBufferPointer<UInt32>
    private let wordBest: UnsafeMutableBufferPointer<Float>
    private let wordFlags: UnsafeMutableBufferPointer<UInt8>
    private let wordTouched: UnsafeMutableBufferPointer<Int32>
    private let queryStamp: UnsafeMutableBufferPointer<UInt32>
    private let queryScore: UnsafeMutableBufferPointer<Float>
    private let queryMatched: UnsafeMutableBufferPointer<UInt8>
    private let queryNameExact: UnsafeMutableBufferPointer<UInt8>
    private let queryStarts: UnsafeMutableBufferPointer<UInt8>
    private let queryTouched: UnsafeMutableBufferPointer<Int32>
    private let editRows: UnsafeMutableBufferPointer<Int32>

    // MARK: Build

    private struct Builder {
        var docs: [Doc] = []
        var rank: [Float] = []
        var group: [UInt8] = []
        var kind: [UInt8] = []
        var nameWords: [UInt8] = []
        var postings: [String: [UInt64]] = [:]

        mutating func addDoc(_ doc: Doc, rank value: Double, vault: Bool, kind docKind: DocKind) -> Int {
            docs.append(doc)
            rank.append(Float(min(1, max(0, value))))
            group.append(vault ? 1 : 0)
            kind.append(docKind.rawValue)
            nameWords.append(0)
            return docs.count - 1
        }

        /// Indexes `text` for `doc`; returns the folded words (the first one carries the first-word flag).
        @discardableResult
        mutating func index(_ text: String, doc: Int, field: Field, primary: Bool = false) -> [String] {
            let split = TextTokens.split(text)
            for (position, word) in split.words.enumerated() {
                add(word, doc: doc, field: field.rawValue | (position == 0 ? SearchEngine.firstWordFlag : 0))
            }
            for compound in split.compounds { add(compound, doc: doc, field: field.rawValue) }
            if primary { nameWords[doc] = UInt8(min(255, split.words.count)) }
            return split.words
        }

        private mutating func add(_ token: String, doc: Int, field: UInt8) {
            postings[token, default: []].append(UInt64(doc) << 8 | UInt64(field))
        }
    }

    private struct PersonAccumulator {
        var name: String
        var profileURL: String?
        var titles = 0
        var bestRank = -1.0
        var bestTitle = ""
        var acting = false
    }

    init(library: Library, metadata: [String: MediaMetadata], guide: Guide?, includeAdult: Bool, now: Date) {
        var builder = Builder()
        var people: [Int: PersonAccumulator] = [:]

        func notePerson(_ id: Int, name: String, profileURL: String?, acting: Bool, title: Title, rank: Double) {
            guard id != 0, !name.isEmpty else { return }
            var person = people[id] ?? PersonAccumulator(name: name, profileURL: profileURL)
            person.titles += 1
            if person.profileURL == nil { person.profileURL = profileURL }
            if acting { person.acting = true }
            if rank > person.bestRank { person.bestRank = rank; person.bestTitle = title.name }
            people[id] = person
        }

        for list in [library.movies, library.series] {
            for title in list where includeAdult || !title.isAdult {
                let md = metadata[title.id]
                let rank = Ranker.score(title, metadata: md, now: now)
                let vault = !title.libraryPlacement.isShowcase
                let doc = builder.addDoc(Doc(target: .title(title.id), primary: title.name,
                                             secondary: SearchEngine.secondaryLine(title, md)),
                                         rank: rank, vault: vault, kind: title.kind == .movie ? .movie : .series)
                let nameKey = builder.index(title.name, doc: doc, field: .name, primary: true).joined(separator: " ")
                guard let md else { continue }
                var alternates = Set([nameKey])
                for alternate in [md.title, md.originalTitle ?? ""] where !alternate.isEmpty {
                    let key = TextTokens.words(alternate).joined(separator: " ")
                    if alternates.insert(key).inserted { builder.index(alternate, doc: doc, field: .original) }
                }
                for member in md.cast.sorted(by: { $0.order < $1.order }).prefix(10) {
                    builder.index(member.name, doc: doc, field: .cast)
                    notePerson(member.personID, name: member.name, profileURL: member.profileURL, acting: true, title: title, rank: rank)
                }
                for director in md.directors.prefix(3) { builder.index(director, doc: doc, field: .director) }
                for member in md.crew where member.job == "Director" {
                    notePerson(member.personID, name: member.name, profileURL: member.profileURL, acting: false, title: title, rank: rank)
                }
                for keyword in md.keywords.prefix(15) { builder.index(keyword, doc: doc, field: .keyword) }
            }
        }

        for id in people.keys.sorted() {
            guard let person = people[id] else { continue }
            let presence = min(1, log2(1 + Double(person.titles)) / 4)
            let rank = 0.7 * max(0, person.bestRank) + 0.3 * presence
            let role = person.acting ? "Known for" : "Director of"
            let doc = builder.addDoc(Doc(target: .person(id: id, name: person.name, profileURL: person.profileURL),
                                         primary: person.name, secondary: "\(role) \(person.bestTitle)"),
                                     rank: rank, vault: false, kind: .person)
            builder.index(person.name, doc: doc, field: .person, primary: true)
        }

        for channel in library.channels where includeAdult || !channel.isAdult {
            let secondary = channel.groupName?.nonEmpty ?? channel.categories.first?.title ?? "Live TV"
            let doc = builder.addDoc(Doc(target: .channel(channel.id), primary: channel.name, secondary: secondary),
                                     rank: 0.3 + 0.5 * RankMath.qualityBonus(channel.bestQuality),
                                     vault: !channel.libraryPlacement.isShowcase, kind: .channel)
            builder.index(channel.name, doc: doc, field: .channel, primary: true)
        }

        if let guide {
            for channel in library.channels where channel.isLibraryShowcase {
                var entries: [(program: Program, line: String)] = []
                for key in [channel.epgChannelID, channel.iptvOrgID] {
                    guard let key = key?.nonEmpty, guide.channelKeys.contains(key) else { continue }
                    if let current = guide.now(key, at: now) { entries.append((current, "Now on \(channel.name)")) }
                    if let upcoming = guide.next(key, after: now) { entries.append((upcoming, "Next on \(channel.name)")) }
                    break
                }
                for entry in entries {
                    let live = LiveEventRules.isLiveEvent(entry.program)
                    let doc = builder.addDoc(Doc(target: .program(channelID: channel.id, program: entry.program),
                                                 primary: entry.program.title, secondary: entry.line),
                                             rank: live ? 0.8 : 0.5, vault: false, kind: .program)
                    builder.index(entry.program.title, doc: doc, field: .program, primary: true)
                }
            }
        }

        // Sort the vocabulary by UTF-8 bytes and lay out CSR buffers.
        let keys = Array(builder.postings.keys)
        let keyBytes = keys.map { Array($0.utf8) }
        let order = keys.indices.sorted { SearchEngine.bytesLess(keyBytes[$0], keyBytes[$1]) }
        var bytes: [UInt8] = []
        var offsets: [Int32] = [0]
        var postingStarts: [Int32] = [0]
        var postingDocList: [Int32] = []
        var postingFieldList: [UInt8] = []
        offsets.reserveCapacity(keys.count + 1)
        postingStarts.reserveCapacity(keys.count + 1)
        for index in order {
            bytes.append(contentsOf: keyBytes[index])
            offsets.append(Int32(bytes.count))
            for value in builder.postings[keys[index]] ?? [] {
                postingDocList.append(Int32(truncatingIfNeeded: value >> 8))
                postingFieldList.append(UInt8(truncatingIfNeeded: value & 0xFF))
            }
            postingStarts.append(Int32(postingDocList.count))
        }

        docs = builder.docs
        docCount = builder.docs.count
        tokenCount = keys.count
        tokenBytes = SearchEngine.copy(bytes, pad: 0)
        tokenOffsets = SearchEngine.copy(offsets, pad: 0)
        postingOffsets = SearchEngine.copy(postingStarts, pad: 0)
        postingDocs = SearchEngine.copy(postingDocList, pad: 0)
        postingFields = SearchEngine.copy(postingFieldList, pad: 0)
        fieldWeights = SearchEngine.copy([1.0, 0.85, 0.45, 0.45, 0.35, 1.0, 0.8, 0.95], pad: 0)
        docRank = SearchEngine.copy(builder.rank, pad: 0)
        docGroup = SearchEngine.copy(builder.group, pad: 0)
        docKind = SearchEngine.copy(builder.kind, pad: 0)
        docNameWords = SearchEngine.copy(builder.nameWords, pad: 0)
        wordStamp = SearchEngine.filled(docCount, 0)
        wordBest = SearchEngine.filled(docCount, 0)
        wordFlags = SearchEngine.filled(docCount, 0)
        wordTouched = SearchEngine.filled(docCount, 0)
        queryStamp = SearchEngine.filled(docCount, 0)
        queryScore = SearchEngine.filled(docCount, 0)
        queryMatched = SearchEngine.filled(docCount, 0)
        queryNameExact = SearchEngine.filled(docCount, 0)
        queryStarts = SearchEngine.filled(docCount, 0)
        queryTouched = SearchEngine.filled(docCount, 0)
        editRows = SearchEngine.filled(3 * 64, 0)
    }

    deinit {
        tokenBytes.deallocate(); tokenOffsets.deallocate(); postingOffsets.deallocate(); postingDocs.deallocate()
        postingFields.deallocate(); fieldWeights.deallocate(); docRank.deallocate(); docGroup.deallocate()
        docKind.deallocate(); docNameWords.deallocate(); wordStamp.deallocate(); wordBest.deallocate()
        wordFlags.deallocate(); wordTouched.deallocate(); queryStamp.deallocate(); queryScore.deallocate()
        queryMatched.deallocate(); queryNameExact.deallocate(); queryStarts.deallocate(); queryTouched.deallocate()
        editRows.deallocate()
    }

    private static func copy<T>(_ array: [T], pad: T) -> UnsafeMutableBufferPointer<T> {
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: max(1, array.count))
        if array.isEmpty { buffer.initialize(repeating: pad) } else { _ = buffer.initialize(from: array) }
        return buffer
    }

    private static func filled<T>(_ count: Int, _ value: T) -> UnsafeMutableBufferPointer<T> {
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: max(1, count))
        buffer.initialize(repeating: value)
        return buffer
    }

    static func bytesLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let common = min(a.count, b.count)
        var index = 0
        while index < common {
            let x = a[index], y = b[index]
            if x != y { return x < y }
            index += 1
        }
        return a.count < b.count
    }

    static func secondaryLine(_ title: Title, _ metadata: MediaMetadata?) -> String {
        var parts = [title.kind == .movie ? "Movie" : "Series"]
        if let year = RankMath.year(title, metadata: metadata) { parts.append(String(year)) }
        if title.bestQuality != .unknown { parts.append(title.bestQuality.label) }
        if case .vault(let shelf) = title.libraryPlacement { parts.append("The Vault: \(shelf.title)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Query

extension SearchEngine {
    func search(_ query: String, scope: TitleKind?, includeChannels: Bool, limit: Int) -> [SearchHit] {
        guard limit > 0, docCount > 0, tokenCount > 0 else { return [] }
        var words: [[UInt8]] = []
        for word in TextTokens.words(query) {
            let bytes = Array(word.utf8)
            if !words.contains(bytes) { words.append(bytes) }
            if words.count == 8 { break }
        }
        guard !words.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }
        let queryGeneration = nextGeneration()
        var queryCount = 0
        for (position, word) in words.enumerated() {
            let matches = word.withUnsafeBufferPointer { expand($0) }
            if matches.isEmpty { return [] }
            let wordGeneration = nextGeneration()
            let touched = accumulate(matches, generation: wordGeneration)
            if position == 0 {
                for slot in 0..<touched {
                    let doc = Int(wordTouched[slot])
                    queryStamp[doc] = queryGeneration
                    queryScore[doc] = wordBest[doc]
                    queryMatched[doc] = 1
                    queryNameExact[doc] = wordFlags[doc] & 1
                    queryStarts[doc] = (wordFlags[doc] >> 1) & 1
                    queryTouched[queryCount] = Int32(doc)
                    queryCount += 1
                }
            } else {
                let required = UInt8(position)
                for slot in 0..<touched {
                    let doc = Int(wordTouched[slot])
                    guard queryStamp[doc] == queryGeneration, queryMatched[doc] == required else { continue }
                    queryScore[doc] += wordBest[doc]
                    queryMatched[doc] = required + 1
                    queryNameExact[doc] += wordFlags[doc] & 1
                }
                // Keep only documents that matched every word so far.
                var kept = 0
                for slot in 0..<queryCount {
                    let doc = Int(queryTouched[slot])
                    if queryMatched[doc] == required + 1 { queryTouched[kept] = Int32(doc); kept += 1 }
                }
                queryCount = kept
            }
            if queryCount == 0 { return [] }
        }
        return select(count: queryCount, words: words.count, scope: scope, includeChannels: includeChannels, limit: limit)
    }

    private func nextGeneration() -> UInt32 {
        if generation == UInt32.max {
            for doc in 0..<docCount { wordStamp[doc] = 0; queryStamp[doc] = 0 }
            generation = 0
        }
        generation += 1
        return generation
    }

    /// Best (quality × field weight) per document for one query word; returns how many documents were touched.
    private func accumulate(_ matches: [(token: Int, quality: Float)], generation stamp: UInt32) -> Int {
        var touched = 0
        for match in matches {
            var posting = Int(postingOffsets[match.token])
            let end = Int(postingOffsets[match.token + 1])
            let exact = match.quality >= 1
            while posting < end {
                let doc = Int(postingDocs[posting])
                let fieldByte = postingFields[posting]
                let field = Int(fieldByte & 0x7F)
                let score = match.quality * fieldWeights[field]
                // Primary name fields: title name, channel, programme, person.
                let primary = field == 0 || field == 5 || field == 6 || field == 7
                var flags: UInt8 = 0
                if primary && exact { flags = 1 }
                if primary && (fieldByte & SearchEngine.firstWordFlag) != 0 { flags |= 2 }
                if wordStamp[doc] != stamp {
                    wordStamp[doc] = stamp
                    wordBest[doc] = score
                    wordFlags[doc] = flags
                    wordTouched[touched] = Int32(doc)
                    touched += 1
                } else {
                    if score > wordBest[doc] { wordBest[doc] = score }
                    wordFlags[doc] |= flags
                }
                posting += 1
            }
        }
        return touched
    }

    /// Exact token, prefixed tokens, then (no exact match, 4+ characters) close misspellings.
    private func expand(_ word: UnsafeBufferPointer<UInt8>) -> [(token: Int, quality: Float)] {
        var out: [(token: Int, quality: Float)] = []
        let start = lowerBound(word)
        var token = start
        var exact = false
        var postings = 0
        while token < tokenCount && hasPrefix(token, word) {
            let length = tokenLength(token)
            if length == word.count {
                exact = true
                out.append((token, 1))
            } else {
                if postings > SearchEngine.maxPrefixPostings { break }
                out.append((token, 0.75 + 0.2 * Float(word.count) / Float(length)))
            }
            postings += Int(postingOffsets[token + 1] - postingOffsets[token])
            token += 1
        }
        if !exact && word.count >= 4 && out.count < 25 {
            out.append(contentsOf: fuzzy(word, skipping: start..<token))
        }
        return out
    }

    private func fuzzy(_ word: UnsafeBufferPointer<UInt8>, skipping prefixRange: Range<Int>) -> [(token: Int, quality: Float)] {
        guard word.count <= 60 else { return [] }
        let maxEdits = word.count >= 8 ? 2 : 1
        var firsts = [word[0]]
        if word[1] != word[0] { firsts.append(word[1]) }
        var found: [(token: Int, distance: Int, frequency: Int)] = []
        for first in firsts {
            let low = [first].withUnsafeBufferPointer { lowerBound($0) }
            let high = first == 0xFF ? tokenCount : [first + 1].withUnsafeBufferPointer { lowerBound($0) }
            var token = low
            while token < high {
                if !prefixRange.contains(token) {
                    let length = tokenLength(token)
                    if length >= 3 && abs(length - word.count) <= maxEdits {
                        let distance = editDistance(token, word, limit: maxEdits)
                        if distance <= maxEdits {
                            found.append((token, distance, Int(postingOffsets[token + 1] - postingOffsets[token])))
                        }
                    }
                }
                token += 1
            }
        }
        found.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.frequency != b.frequency { return a.frequency > b.frequency }
            return a.token < b.token
        }
        return found.prefix(SearchEngine.maxFuzzyTokens).map { ($0.token, $0.distance == 1 ? 0.6 : 0.45) }
    }

    private func select(count: Int, words: Int, scope: TitleKind?, includeChannels: Bool, limit: Int) -> [SearchHit] {
        let required = UInt8(words)
        let wordCount = Float(words)
        func better(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.group != b.group { return a.group < b.group }
            if a.score != b.score { return a.score > b.score }
            if a.rank != b.rank { return a.rank > b.rank }
            return a.doc < b.doc
        }
        // Bounded heap: the root is the worst kept candidate.
        var heap: [Candidate] = []
        heap.reserveCapacity(min(limit, count))
        for slot in 0..<count {
            let doc = Int(queryTouched[slot])
            guard queryMatched[doc] == required else { continue }
            switch DocKind(rawValue: docKind[doc]) ?? .movie {
            case .movie: if let scope, scope != .movie { continue }
            case .series: if let scope, scope != .series { continue }
            case .channel, .program: if !includeChannels || scope != nil { continue }
            case .person: if scope != nil { continue }
            }
            var score = queryScore[doc] / wordCount
            if queryNameExact[doc] == required && docNameWords[doc] == required { score += 0.5 }
            if queryStarts[doc] != 0 { score += 0.15 }
            score += 0.1 * docRank[doc]
            let candidate = Candidate(doc: Int32(doc), score: score, group: docGroup[doc], rank: docRank[doc])
            if heap.count < limit {
                heap.append(candidate)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard better(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child)
                    child = parent
                }
            } else if better(candidate, heap[0]) {
                heap[0] = candidate
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var worst = parent
                    if left < heap.count && better(heap[worst], heap[left]) { worst = left }
                    if right < heap.count && better(heap[worst], heap[right]) { worst = right }
                    if worst == parent { break }
                    heap.swapAt(parent, worst)
                    parent = worst
                }
            }
        }
        heap.sort(by: better)
        return heap.map { candidate in
            let doc = docs[Int(candidate.doc)]
            let score = Double(candidate.score) + (candidate.group == 0 ? 2 : 0)
            return SearchHit(target: doc.target, score: score, primary: doc.primary, secondary: doc.secondary)
        }
    }

    // MARK: Token buffer helpers

    private func tokenLength(_ token: Int) -> Int { Int(tokenOffsets[token + 1] - tokenOffsets[token]) }

    /// First token >= `word` (byte order).
    private func lowerBound(_ word: UnsafeBufferPointer<UInt8>) -> Int {
        var low = 0, high = tokenCount
        while low < high {
            let mid = (low + high) >> 1
            if compare(mid, word) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func compare(_ token: Int, _ word: UnsafeBufferPointer<UInt8>) -> Int {
        let start = Int(tokenOffsets[token])
        let length = Int(tokenOffsets[token + 1]) - start
        let common = min(length, word.count)
        var index = 0
        while index < common {
            let x = tokenBytes[start + index], y = word[index]
            if x != y { return x < y ? -1 : 1 }
            index += 1
        }
        return length == word.count ? 0 : (length < word.count ? -1 : 1)
    }

    private func hasPrefix(_ token: Int, _ word: UnsafeBufferPointer<UInt8>) -> Bool {
        let start = Int(tokenOffsets[token])
        guard Int(tokenOffsets[token + 1]) - start >= word.count else { return false }
        var index = 0
        while index < word.count {
            if tokenBytes[start + index] != word[index] { return false }
            index += 1
        }
        return true
    }

    /// Optimal-string-alignment distance (adjacent transpositions cost 1), or `limit + 1` once it is exceeded.
    private func editDistance(_ token: Int, _ word: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
        let start = Int(tokenOffsets[token])
        let n = Int(tokenOffsets[token + 1]) - start
        let m = word.count
        guard n <= 62, m <= 62, let base = editRows.baseAddress else { return limit + 1 }
        var older = base, previous = base + 64, current = base + 128
        for j in 0...m { previous[j] = Int32(j) }
        let cap = Int32(limit)
        for i in 1...n {
            let a = tokenBytes[start + i - 1]
            current[0] = Int32(i)
            var rowMinimum = current[0]
            for j in 1...m {
                let b = word[j - 1]
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a == b ? 0 : 1))
                if i > 1 && j > 1 && a == word[j - 2] && tokenBytes[start + i - 2] == b {
                    value = min(value, older[j - 2] + 1)
                }
                current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            if rowMinimum > cap { return limit + 1 }
            let recycled = older
            older = previous
            previous = current
            current = recycled
        }
        return Int(previous[m])
    }
}
