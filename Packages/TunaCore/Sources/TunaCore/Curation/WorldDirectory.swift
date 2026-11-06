import Foundation

/// Static data behind `WorldDirectory`: countries and languages seen in IPTV catalogs, regions and featured worlds.
enum WorldData {
    /// "CODE|English name|Native name|languages" (ISO 3166-1 alpha-2, ISO 639-1).
    private static let countryRows = """
    AF|Afghanistan|افغانستان|fa,ps
    AL|Albania|Shqipëria|sq
    DZ|Algeria|الجزائر|ar,fr
    AO|Angola|Angola|pt
    AR|Argentina|Argentina|es
    AM|Armenia|Հայաստան|hy
    AU|Australia|Australia|en
    AT|Austria|Österreich|de
    AZ|Azerbaijan|Azərbaycan|az
    BH|Bahrain|البحرين|ar
    BD|Bangladesh|বাংলাদেশ|bn
    BY|Belarus|Беларусь|be,ru
    BE|Belgium|België|nl,fr,de
    BO|Bolivia|Bolivia|es
    BA|Bosnia and Herzegovina|Bosna i Hercegovina|bs,hr,sr
    BR|Brazil|Brasil|pt
    BG|Bulgaria|България|bg
    KH|Cambodia|កម្ពុជា|km
    CM|Cameroon|Cameroun|fr,en
    CA|Canada|Canada|en,fr
    CL|Chile|Chile|es
    CN|China|中国|zh
    CO|Colombia|Colombia|es
    CD|Congo (DRC)|RD Congo|fr
    CR|Costa Rica|Costa Rica|es
    CI|Côte d'Ivoire|Côte d'Ivoire|fr
    HR|Croatia|Hrvatska|hr
    CU|Cuba|Cuba|es
    CY|Cyprus|Κύπρος|el,tr
    CZ|Czechia|Česko|cs
    DK|Denmark|Danmark|da
    DO|Dominican Republic|República Dominicana|es
    EC|Ecuador|Ecuador|es
    EG|Egypt|مصر|ar
    SV|El Salvador|El Salvador|es
    EE|Estonia|Eesti|et
    ET|Ethiopia|ኢትዮጵያ|am
    FI|Finland|Suomi|fi,sv
    FR|France|France|fr
    GE|Georgia|საქართველო|ka
    DE|Germany|Deutschland|de
    GH|Ghana|Ghana|en
    GR|Greece|Ελλάδα|el
    GT|Guatemala|Guatemala|es
    HT|Haiti|Haïti|fr,ht
    HN|Honduras|Honduras|es
    HK|Hong Kong|香港|zh,en
    HU|Hungary|Magyarország|hu
    IS|Iceland|Ísland|is
    IN|India|भारत|hi,en
    ID|Indonesia|Indonesia|id
    IR|Iran|ایران|fa
    IQ|Iraq|العراق|ar,ku
    IE|Ireland|Éire|en,ga
    IL|Israel|ישראל|he
    IT|Italy|Italia|it
    JM|Jamaica|Jamaica|en
    JP|Japan|日本|ja
    JO|Jordan|الأردن|ar
    KZ|Kazakhstan|Қазақстан|kk,ru
    KE|Kenya|Kenya|sw,en
    XK|Kosovo|Kosova|sq,sr
    KW|Kuwait|الكويت|ar
    KG|Kyrgyzstan|Кыргызстан|ky,ru
    LV|Latvia|Latvija|lv
    LB|Lebanon|لبنان|ar
    LY|Libya|ليبيا|ar
    LT|Lithuania|Lietuva|lt
    LU|Luxembourg|Lëtzebuerg|lb,fr,de
    MY|Malaysia|Malaysia|ms
    MT|Malta|Malta|mt,en
    MX|Mexico|México|es
    MD|Moldova|Moldova|ro
    MN|Mongolia|Монгол Улс|mn
    ME|Montenegro|Crna Gora|sr
    MA|Morocco|المغرب|ar,fr
    MZ|Mozambique|Moçambique|pt
    MM|Myanmar|မြန်မာ|my
    NP|Nepal|नेपाल|ne
    NL|Netherlands|Nederland|nl
    NZ|New Zealand|New Zealand|en
    NI|Nicaragua|Nicaragua|es
    NG|Nigeria|Nigeria|en
    MK|North Macedonia|Северна Македонија|mk
    NO|Norway|Norge|no
    OM|Oman|عُمان|ar
    PK|Pakistan|پاکستان|ur,en
    PS|Palestine|فلسطين|ar
    PA|Panama|Panamá|es
    PY|Paraguay|Paraguay|es
    PE|Peru|Perú|es
    PH|Philippines|Pilipinas|tl,en
    PL|Poland|Polska|pl
    PT|Portugal|Portugal|pt
    PR|Puerto Rico|Puerto Rico|es,en
    QA|Qatar|قطر|ar
    RO|Romania|România|ro
    RU|Russia|Россия|ru
    SA|Saudi Arabia|السعودية|ar
    SN|Senegal|Sénégal|fr
    RS|Serbia|Србија|sr
    SG|Singapore|Singapore|en,zh,ms
    SK|Slovakia|Slovensko|sk
    SI|Slovenia|Slovenija|sl
    SO|Somalia|Soomaaliya|so,ar
    ZA|South Africa|South Africa|en,af,zu
    KR|South Korea|대한민국|ko
    ES|Spain|España|es
    LK|Sri Lanka|ශ්\u{200D}රී ලංකාව|si,ta
    SD|Sudan|السودان|ar,en
    SE|Sweden|Sverige|sv
    CH|Switzerland|Schweiz|de,fr,it
    SY|Syria|سوريا|ar
    TW|Taiwan|臺灣|zh
    TZ|Tanzania|Tanzania|sw,en
    TH|Thailand|ประเทศไทย|th
    TT|Trinidad and Tobago|Trinidad and Tobago|en
    TN|Tunisia|تونس|ar,fr
    TR|Turkey|Türkiye|tr
    UG|Uganda|Uganda|en,sw
    UA|Ukraine|Україна|uk
    AE|United Arab Emirates|الإمارات|ar
    GB|United Kingdom|United Kingdom|en
    US|United States|United States|en
    UY|Uruguay|Uruguay|es
    UZ|Uzbekistan|Oʻzbekiston|uz
    VE|Venezuela|Venezuela|es
    VN|Vietnam|Việt Nam|vi
    YE|Yemen|اليمن|ar
    """

    /// "code|English name|Native name|flag country".
    private static let languageRows = """
    af|Afrikaans|Afrikaans|ZA
    sq|Albanian|Shqip|AL
    am|Amharic|አማርኛ|ET
    ar|Arabic|العربية|SA
    hy|Armenian|Հայերեն|AM
    az|Azerbaijani|Azərbaycan dili|AZ
    be|Belarusian|Беларуская|BY
    bn|Bengali|বাংলা|BD
    bs|Bosnian|Bosanski|BA
    bg|Bulgarian|Български|BG
    my|Burmese|မြန်မာ|MM
    ca|Catalan|Català|ES
    zh|Chinese|中文|CN
    hr|Croatian|Hrvatski|HR
    cs|Czech|Čeština|CZ
    da|Danish|Dansk|DK
    nl|Dutch|Nederlands|NL
    en|English|English|GB
    et|Estonian|Eesti|EE
    tl|Filipino|Filipino|PH
    fi|Finnish|Suomi|FI
    fr|French|Français|FR
    ka|Georgian|ქართული|GE
    de|German|Deutsch|DE
    el|Greek|Ελληνικά|GR
    gu|Gujarati|ગુજરાતી|IN
    ht|Haitian Creole|Kreyòl ayisyen|HT
    he|Hebrew|עברית|IL
    hi|Hindi|हिन्दी|IN
    hu|Hungarian|Magyar|HU
    is|Icelandic|Íslenska|IS
    id|Indonesian|Bahasa Indonesia|ID
    ga|Irish|Gaeilge|IE
    it|Italian|Italiano|IT
    ja|Japanese|日本語|JP
    kn|Kannada|ಕನ್ನಡ|IN
    kk|Kazakh|Қазақ тілі|KZ
    km|Khmer|ខ្មែរ|KH
    ko|Korean|한국어|KR
    ku|Kurdish|Kurdî|IQ
    ky|Kyrgyz|Кыргызча|KG
    lv|Latvian|Latviešu|LV
    lt|Lithuanian|Lietuvių|LT
    lb|Luxembourgish|Lëtzebuergesch|LU
    mk|Macedonian|Македонски|MK
    ms|Malay|Bahasa Melayu|MY
    ml|Malayalam|മലയാളം|IN
    mt|Maltese|Malti|MT
    mr|Marathi|मराठी|IN
    mn|Mongolian|Монгол|MN
    ne|Nepali|नेपाली|NP
    no|Norwegian|Norsk|NO
    ps|Pashto|پښتو|AF
    fa|Persian|فارسی|IR
    pl|Polish|Polski|PL
    pt|Portuguese|Português|PT
    pa|Punjabi|ਪੰਜਾਬੀ|IN
    ro|Romanian|Română|RO
    ru|Russian|Русский|RU
    sr|Serbian|Српски|RS
    si|Sinhala|සිංහල|LK
    sk|Slovak|Slovenčina|SK
    sl|Slovenian|Slovenščina|SI
    so|Somali|Soomaali|SO
    es|Spanish|Español|ES
    sw|Swahili|Kiswahili|KE
    sv|Swedish|Svenska|SE
    ta|Tamil|தமிழ்|IN
    te|Telugu|తెలుగు|IN
    th|Thai|ไทย|TH
    tr|Turkish|Türkçe|TR
    uk|Ukrainian|Українська|UA
    ur|Urdu|اردو|PK
    uz|Uzbek|Oʻzbekcha|UZ
    vi|Vietnamese|Tiếng Việt|VN
    cy|Welsh|Cymraeg|GB
    zu|Zulu|isiZulu|ZA
    """

    static let countries: [CountryInfo] = {
        var list: [CountryInfo] = []
        for line in countryRows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).tunaTrimmed }
            guard parts.count == 4 else { continue }
            list.append(CountryInfo(code: parts[0], name: parts[1], nativeName: parts[2],
                                    languages: parts[3].split(separator: ",").map(String.init)))
        }
        return list.sorted { $0.name.tunaFolded < $1.name.tunaFolded }
    }()

    static let languages: [LanguageInfo] = {
        var list: [LanguageInfo] = []
        for line in languageRows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).tunaTrimmed }
            guard parts.count == 4 else { continue }
            list.append(LanguageInfo(code: parts[0], name: parts[1], nativeName: parts[2], flagCountry: parts[3]))
        }
        return list.sorted { $0.name.tunaFolded < $1.name.tunaFolded }
    }()

    static let countryByCode: [String: CountryInfo] = {
        var map: [String: CountryInfo] = [:]
        for country in countries { map[country.code] = country }
        return map
    }()

    static let languageByCode: [String: LanguageInfo] = {
        var map: [String: LanguageInfo] = [:]
        for language in languages { map[language.code] = language }
        return map
    }()

    static let regionNames: [String: String] = [
        "LATAM": "Latin America", "EXYU": "Ex-Yugoslavia", "ARAB": "Arab World", "AFRICA": "Africa",
        "CARIB": "Caribbean", "NORDIC": "Nordic", "BALTIC": "Baltic",
    ]

    /// Countries of each region (world matching of region-only tags such as "NORDIC | ...").
    static let regionCountries: [String: Set<String>] = [
        "NORDIC": ["SE", "NO", "DK", "FI", "IS"],
        "BALTIC": ["EE", "LV", "LT"],
        "EXYU": ["RS", "HR", "BA", "SI", "MK", "ME", "XK"],
        "LATAM": ["MX", "AR", "CO", "CL", "PE", "VE", "EC", "UY", "PY", "BO", "CR", "PA", "PR", "CU", "DO", "GT", "HN",
                  "SV", "NI", "BR"],
        "ARAB": ["SA", "AE", "EG", "MA", "DZ", "TN", "LB", "IQ", "SY", "JO", "KW", "QA", "OM", "BH", "YE", "PS", "LY", "SD"],
        "AFRICA": ["NG", "GH", "KE", "ZA", "SN", "CM", "CI", "SO", "ET", "MA", "DZ", "TN", "EG", "LY", "SD", "UG", "TZ",
                   "AO", "MZ", "CD"],
        "CARIB": ["JM", "TT", "PR", "CU", "DO", "HT"],
    ]

    /// Onboarding's first row: each entry is a "world" (its native name is the label shown).
    static let featured: [CountryInfo] = [
        CountryInfo(code: "GB", name: "English", nativeName: "English", languages: ["en"]),
        CountryInfo(code: "TR", name: "Turkey", nativeName: "Türkiye", languages: ["tr"]),
        CountryInfo(code: "DE", name: "Germany", nativeName: "Deutschland", languages: ["de"]),
        CountryInfo(code: "FR", name: "France", nativeName: "France", languages: ["fr"]),
        CountryInfo(code: "ES", name: "Spain", nativeName: "España", languages: ["es"]),
        CountryInfo(code: "IT", name: "Italy", nativeName: "Italia", languages: ["it"]),
        CountryInfo(code: "BR", name: "Portuguese (Brazil)", nativeName: "Português (Brasil)", languages: ["pt"]),
        CountryInfo(code: "SA", name: "Arabic", nativeName: "العربية", languages: ["ar"]),
        CountryInfo(code: "NL", name: "Dutch", nativeName: "Nederlands", languages: ["nl"]),
        CountryInfo(code: "PL", name: "Polish", nativeName: "Polski", languages: ["pl"]),
        CountryInfo(code: "IN", name: "Hindi", nativeName: "हिन्दी", languages: ["hi"]),
    ]

    static func country(_ code: String) -> CountryInfo? {
        let upper = code.tunaTrimmed.uppercased()
        if let found = countryByCode[upper] { return found }
        if upper == "UK" { return countryByCode["GB"] }
        return nil
    }

    static func language(_ code: String) -> LanguageInfo? {
        languageByCode[code.tunaTrimmed.lowercased()]
    }

    static func regionName(_ code: String) -> String {
        let upper = code.tunaTrimmed.uppercased()
        if let name = regionNames[upper] { return name }
        if let country = country(upper) { return country.name }
        return code
    }
}
