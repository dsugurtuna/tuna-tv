import Foundation

/// Live channel categories from provider category hints, group names and channel-name keywords
/// ("beIN Sports 1" -> sports, "Cartoon Network" -> kids, "CNN Türk" -> news), plus genre words for categories.
enum ChannelClassifier {
    /// Folded single words -> category.
    private static let words: [String: ChannelCategory] = {
        let table: [(ChannelCategory, String)] = [
            (.news, "news haber haberler nachrichten noticias noticia notizie nieuws wiadomosci novosti info infos akhbar "
                + "اخبار cnn euronews aljazeera skynews foxnews msnbc france24 dw bfmtv lci i24news newsmax haberturk tgrt"),
            (.sports, "sport sports spor deportes deporte esporte esportes sportif calcio football soccer futbol tennis golf "
                + "nba nfl nhl mlb ufc wwe boxing f1 motogp racing cricket rugby espn dazn eurosport bein ssc arena "
                + "sportklub sporttv tivibu nbatv laliga premier bundesliga"),
            (.kids, "kids kid children cocuk kinder enfants infantil bambini junior jr cartoon cartoons toons nick "
                + "nickelodeon boomerang cbeebies cbbc babytv minika cartoonito gulli kika tiji jimjam duck yumurcak"),
            (.movies, "movie movies film films filme filmes cinema cine kino sinema filmbox cinemax tcm mgm peliculas cinemas film4 "
                + "action thriller"),
            (.series, "series dizi diziler serien serie"),
            (.music, "music muzik musik musique musica mtv vh1 kral trace clubland 4music nrj hits"),
            (.documentary, "documentary documentaries docu doku belgesel documentaire documental discovery natgeo history "
                + "explore nature wild"),
            (.entertainment, "entertainment eglence tlc bravo lifetime tv8"),
            (.religious, "religious religion dini islam islamic quran coran ewtn daystar diyanet semerkand makkah gospel "
                + "christian church catholic"),
            (.business, "business finance ekonomi bloomberg cnbc"),
            (.education, "education egitim edu learning okul"),
            (.cooking, "cooking food yemek cuisine kitchen 24kitchen tastemade"),
            (.travel, "travel seyahat voyage travelxp"),
            (.comedy, "comedy komedi"),
            (.animation, "animation anime animasyon animax"),
            (.weather, "weather meteo"),
            (.shop, "shop shopping qvc hsn teleshopping alisveris"),
            (.legislative, "parliament parlament tbmm senate congress cspan bundestag"),
            (.outdoor, "outdoor hunting fishing"),
            (.science, "science bilim"),
            (.culture, "culture kultur arte"),
            (.family, "family aile"),
            (.auto, "auto motor cars motorvision"),
            (.classic, "classic classics klasik retro nostalgia yesilcam"),
            (.relax, "relax ambient fireplace aquarium"),
            (.events, "ppv event events"),
            (.xxx, "xxx adult adults porn"),
            (.lifestyle, "lifestyle fashion moda hgtv ftv yasam"),
            (.general, "general ulusal genel national"),
        ]
        var map: [String: ChannelCategory] = [:]
        for (category, list) in table {
            for word in list.split(separator: " ") where map[String(word)] == nil { map[String(word)] = category }
        }
        return map
    }()

    /// Folded two-word phrases -> category (checked before single words).
    private static let phrases: [String: ChannelCategory] = [
        "nat geo": .documentary, "national geographic": .documentary, "animal planet": .documentary,
        "love nature": .documentary, "bbc earth": .documentary, "da vinci": .kids, "food network": .cooking,
        "comedy central": .comedy, "cartoon network": .kids, "sky sports": .sports, "sky news": .news,
        "sky cinema": .movies, "bt sport": .sports, "fox sports": .sports, "fox news": .news, "al jazeera": .news,
        "trt cocuk": .kids, "trt haber": .news, "a haber": .news, "cnn turk": .news, "baby tv": .kids,
        "disney junior": .kids, "disney channel": .kids, "disney jr": .kids, "nick jr": .kids, "travel channel": .travel,
        "weather channel": .weather, "god tv": .religious, "c span": .legislative, "s sport": .sports,
        "tivibu spor": .sports, "show tv": .entertainment, "star tv": .entertainment, "fox life": .lifestyle,
        "investigation discovery": .documentary, "science channel": .science, "discovery science": .science,
        "true movies": .movies, "movie channel": .movies,
    ]

    /// Folded word -> genre label (movie/series categories).
    private static let genreWords: [String: String] = {
        let table: [(String, String)] = [
            ("Action", "action aksiyon aktion accion azione acao"),
            ("Adventure", "adventure macera abenteuer aventure aventura avventura"),
            ("Animation", "animation animated animasyon animacion animazione cartoon cartoons anime"),
            ("Comedy", "comedy comedies komedi komodie comedie comedia commedia"),
            ("Crime", "crime suc krimi crimen polar"),
            ("Documentary", "documentary documentaries docu docs belgesel doku dokumentation documentaire documental "
                + "documentario"),
            ("Drama", "drama dramas dram drame dramma"),
            ("Family", "family aile familie famille familia"),
            ("Fantasy", "fantasy fantastik fantastique fantasia"),
            ("History", "history historical tarih tarihi histoire historia storia"),
            ("Horror", "horror korku terror horreur terrore"),
            ("Kids", "kids children cocuk kinder enfants infantil bambini"),
            ("Music", "music musical muzik musik musique musica"),
            ("Mystery", "mystery gizem"),
            ("Romance", "romance romantic romantik romantique romantica"),
            ("Science Fiction", "scifi sci-fi bilimkurgu"),
            ("Thriller", "thriller gerilim suspense"),
            ("War", "war savas krieg guerre guerra"),
            ("Western", "western westerns"),
            ("Biography", "biography biyografi"),
            ("Sport", "sport sports spor"),
            ("Reality", "reality"),
            ("Stand-up", "standup stand-up"),
        ]
        var map: [String: String] = [:]
        for (genre, list) in table {
            for word in list.split(separator: " ") { map[String(word)] = genre }
        }
        return map
    }()

    private static let genrePhrases: [String: String] = ["science fiction": "Science Fiction", "bilim kurgu": "Science Fiction",
                                                         "sci fi": "Science Fiction", "stand up": "Stand-up"]

    /// Lowercase folded words of a name (punctuation split, diacritics removed, Turkish-safe).
    static func foldedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in TextFold.upperKey(text).unicodeScalars {
            let cp = scalar.value
            if cp < 0x80 {
                if cp >= 65 && cp <= 90, let lower = Unicode.Scalar(cp + 32) {
                    current.append(lower)
                } else if (cp >= 48 && cp <= 57) || cp == 43 || cp == 45 {
                    current.append(scalar)
                } else if !current.isEmpty {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if scalar.properties.changesWhenLowercased {
                    current.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
                } else {
                    current.append(scalar)
                }
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words.map { word in
            var w = word
            while w.hasSuffix("-") || w.hasSuffix("+") { w.removeLast() }
            while w.hasPrefix("-") { w.removeFirst() }
            return w
        }.filter { !$0.isEmpty }
    }

    /// Categories implied by words, in order of appearance (phrases first at each position).
    static func categories(inWords words: [String]) -> [ChannelCategory] {
        var found: [ChannelCategory] = []
        func add(_ c: ChannelCategory) { if !found.contains(c) { found.append(c) } }
        var i = 0
        while i < words.count {
            if i + 1 < words.count, let c = phrases[words[i] + " " + words[i + 1]] {
                add(c)
                i += 2
                continue
            }
            let word = words[i]
            if let c = ChannelClassifier.words[word] {
                add(c)
            } else if word.hasPrefix("sport") || (word.hasPrefix("spor") && word.count <= 8) {
                add(.sports)
            } else if word.hasSuffix("news") || word.hasPrefix("haber") {
                add(.news)
            } else if word.contains("kids") || word.contains("toons") || word.hasPrefix("cocuk") {
                add(.kids)
            } else if word.hasPrefix("cinema") || word.hasPrefix("movie") || word.hasPrefix("filmbox") {
                add(.movies)
            } else if word.hasPrefix("music") || word.hasPrefix("muzik") {
                add(.music)
            }
            i += 1
        }
        return found
    }

    /// First channel category implied by a category / group name.
    static func category(forName name: String) -> ChannelCategory? {
        categories(inWords: foldedWords(name)).first
    }

    /// First genre implied by a category name.
    static func genre(forName name: String) -> String? {
        let words = foldedWords(name)
        var i = 0
        while i < words.count {
            if i + 1 < words.count, let g = genrePhrases[words[i] + " " + words[i + 1]] { return g }
            if let g = genreWords[words[i]] { return g }
            i += 1
        }
        return nil
    }

    /// Channel categories: adult -> [xxx]; else hint categories, then name keywords; events first; [general] fallback.
    static func categories(channelName: String, hints: [CategoryHints], groupNames: [String], isAdult: Bool,
                           isEvent: Bool) -> [ChannelCategory] {
        if isAdult { return [.xxx] }
        var found: [ChannelCategory] = []
        func add(_ c: ChannelCategory) { if !found.contains(c) { found.append(c) } }
        if isEvent { add(.events) }
        for hint in hints {
            if let raw = hint.channelCategory, let c = ChannelCategory(rawValue: raw) { add(c) }
        }
        for group in groupNames {
            if let c = category(forName: group) { add(c) }
        }
        for c in categories(inWords: foldedWords(channelName)) where c != .xxx { add(c) }
        if found.isEmpty { found.append(.general) }
        return found
    }
}
