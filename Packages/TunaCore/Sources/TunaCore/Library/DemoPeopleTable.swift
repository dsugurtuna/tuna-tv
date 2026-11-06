// Name pools for the invented demo people. Combinations are generated deterministically; none is meant to
// refer to a real person. "_" inside a surname stands for a space. Birthplaces are "City, Country#Demonym".

struct DemoCulture: Sendable {
    let code: String
    let female: [String]
    let male: [String]
    let surnames: [String]
    let birthplaces: [String]
    /// Family name first in credits (Korean, Chinese).
    let familyFirst: Bool
    /// How many people of this culture the demo invents.
    let population: Int

    init(_ code: String, female: String, male: String, surnames: String, birthplaces: [String],
         familyFirst: Bool = false, population: Int) {
        self.code = code
        self.female = female.split(separator: " ").map(String.init)
        self.male = male.split(separator: " ").map(String.init)
        self.surnames = surnames.split(separator: " ").map { $0.replacingOccurrences(of: "_", with: " ") }
        self.birthplaces = birthplaces
        self.familyFirst = familyFirst
        self.population = population
    }
}

enum DemoTables {
    static let cultures: [DemoCulture] = [
        DemoCulture("anglo",
                    female: "Abigail Beatrix Clara Delia Eleanor Fiona Georgia Harriet Imogen Jessa Kathleen Lorna Maeve Nell Orla Philippa Rosalind Sadie Tamsin Willa Wren Hazel Iris Margot",
                    male: "Alistair Barnaby Callum Declan Ewan Felix Gideon Hugo Iain Jasper Kit Lachlan Malcolm Niall Oscar Percy Quentin Rory Silas Theo Wyatt Elliot Rufus Desmond",
                    surnames: "Ashdown Blackwood Calloway Darrow Ellery Fenwick Garrick Hallam Ingleby Kensley Lockhart Merriweather Northcott Oakes Pemberton Quayle Rookwood Sallow Thornbury Underhill Whitlock Yardley Ashcombe Brierley Carrow Dunmore Fairlie Gadsby Hartigan Marchbank",
                    birthplaces: ["London, England, UK#British", "Manchester, England, UK#British", "Leeds, England, UK#British",
                                  "Bristol, England, UK#British", "Glasgow, Scotland, UK#Scottish", "Edinburgh, Scotland, UK#Scottish",
                                  "Cardiff, Wales, UK#Welsh", "Belfast, Northern Ireland, UK#Northern Irish", "Dublin, Ireland#Irish",
                                  "Galway, Ireland#Irish", "Brooklyn, New York, USA#American", "Chicago, Illinois, USA#American",
                                  "Austin, Texas, USA#American", "Portland, Oregon, USA#American", "Atlanta, Georgia, USA#American",
                                  "Oakland, California, USA#American", "Toronto, Ontario, Canada#Canadian", "Halifax, Nova Scotia, Canada#Canadian",
                                  "Melbourne, Victoria, Australia#Australian", "Perth, Western Australia, Australia#Australian",
                                  "Wellington, New Zealand#New Zealand"],
                    population: 150),
        DemoCulture("tr",
                    female: "Elif Zeynep Defne Ece Selin Nehir Aslı Melis Damla Yasemin Gül Pelin Nur Derya Ayşe Hande Feride Leyla Nesrin Su",
                    male: "Kerem Emir Barış Mert Deniz Ozan Tolga Serkan Umut Cem Kaan Murat Burak Efe Alper Onur Tarık Rüzgar Selim Levent",
                    surnames: "Karaca Aydın Yıldırım Demirtaş Kurtuluş Şahin Ateş Bozkurt Erdem Aksoy Tunç Güler Özkan Kılıç Duman Sezer Akın Toprak Uçar Yalçın Ekinci Karadağ Soylu Çakır Altun Ercan",
                    birthplaces: ["İstanbul, Türkiye#Turkish", "İzmir, Türkiye#Turkish", "Ankara, Türkiye#Turkish", "Bursa, Türkiye#Turkish",
                                  "Trabzon, Türkiye#Turkish", "Eskişehir, Türkiye#Turkish", "Antalya, Türkiye#Turkish",
                                  "Mardin, Türkiye#Turkish", "Adana, Türkiye#Turkish"],
                    population: 80),
        DemoCulture("es",
                    female: "Lucía Valentina Inés Paloma Ximena Carmen Alba Renata Maite Pilar Soledad Ainhoa Camila Julieta",
                    male: "Mateo Joaquín Rodrigo Íñigo Santiago Tomás Emilio Andrés Gael Bruno Martín Álvaro Rafael Ignacio",
                    surnames: "Quintero Echeverría Valdés Montoya Arrieta Ibarra Salcedo Cifuentes Lozano Peralta Ugarte Robledo Castañeda Villalba Mendívil Zubiri",
                    birthplaces: ["Madrid, Spain#Spanish", "Seville, Spain#Spanish", "Bilbao, Spain#Spanish", "Valencia, Spain#Spanish",
                                  "Mexico City, Mexico#Mexican", "Guadalajara, Mexico#Mexican", "Buenos Aires, Argentina#Argentine",
                                  "Santiago, Chile#Chilean", "Valparaíso, Chile#Chilean", "Bogotá, Colombia#Colombian"],
                    population: 34),
        DemoCulture("fr",
                    female: "Camille Margaux Élodie Solène Apolline Clémence Maëlle Léonie Anouk Céleste Odile Romane",
                    male: "Bastien Aurélien Matthias Gaspard Florian Lucien Rémi Étienne Maxence Jules Benoît Thibault",
                    surnames: "Lacombe Fontaine Verdier Rouvière Garnier Chevalier Morel Duval Bertin Faure Leclerc Marchand Perrin Vasseur Aubert Delorme",
                    birthplaces: ["Paris, France#French", "Lyon, France#French", "Marseille, France#French", "Nantes, France#French",
                                  "Rennes, France#French", "Brussels, Belgium#Belgian", "Montréal, Québec, Canada#Canadian"],
                    population: 30),
        DemoCulture("de",
                    female: "Lena Johanna Greta Mila Frieda Annika Ilse Katrin Svenja Marlene Theresa Wiebke",
                    male: "Lukas Jonas Anton Henrik Konstantin Moritz Tobias Johannes Benedikt Friedrich Niklas Volker",
                    surnames: "Brenner Kessler Hartmann Vogel Engel Winkler Lorenz Seidel Brandt Kühn Albrecht Ostermann Roth Falk Reimann Thalberg",
                    birthplaces: ["Berlin, Germany#German", "Hamburg, Germany#German", "Munich, Germany#German", "Cologne, Germany#German",
                                  "Leipzig, Germany#German", "Vienna, Austria#Austrian", "Zürich, Switzerland#Swiss"],
                    population: 30),
        DemoCulture("nordic",
                    female: "Sigrid Astrid Liv Ingrid Freja Saga Maja Hedda Tove Silje",
                    male: "Anders Magnus Erik Sindre Mads Oskar Leif Joakim Torvald Rasmus",
                    surnames: "Halvorsen Lindqvist Berglund Strand Dahl Eriksen Nyberg Holm Sandvik Aasen Lund Sørby",
                    birthplaces: ["Oslo, Norway#Norwegian", "Bergen, Norway#Norwegian", "Tromsø, Norway#Norwegian",
                                  "Copenhagen, Denmark#Danish", "Aarhus, Denmark#Danish", "Stockholm, Sweden#Swedish",
                                  "Gothenburg, Sweden#Swedish", "Reykjavík, Iceland#Icelandic", "Helsinki, Finland#Finnish"],
                    population: 30),
        DemoCulture("wafrica",
                    female: "Adaeze Chiamaka Ama Efua Folake Ifeoma Nneka Yetunde Abena Zainab Amara Kemi",
                    male: "Kwame Chidi Obinna Kofi Tunde Emeka Babatunde Ifeanyi Kwabena Seun Femi Kelechi",
                    surnames: "Okafor Adeyemi Mensah Okonkwo Boateng Eze Nwosu Asante Adebayo Owusu Nnamdi Oduya Balogun Ofori",
                    birthplaces: ["Lagos, Nigeria#Nigerian", "Enugu, Nigeria#Nigerian", "Ibadan, Nigeria#Nigerian", "Accra, Ghana#Ghanaian",
                                  "Kumasi, Ghana#Ghanaian", "London, England, UK#British", "Houston, Texas, USA#American"],
                    population: 34),
        DemoCulture("ja",
                    female: "Haruka Aoi Yui Mei Rin Sakura Natsuki Emi",
                    male: "Haruto Sota Ren Kaito Daichi Yuto Kenji Takumi",
                    surnames: "Morikawa Hoshino Ishida Fujimori Kuroda Saeki Hayashi Mizuno Tachibana Ueda",
                    birthplaces: ["Tokyo, Japan#Japanese", "Osaka, Japan#Japanese", "Sapporo, Japan#Japanese", "Fukuoka, Japan#Japanese",
                                  "Kyoto, Japan#Japanese"],
                    population: 20),
        DemoCulture("ko",
                    female: "Seo-yeon Ji-woo Ha-eun Min-ji Soo-ah Yu-na Da-eun Hye-jin",
                    male: "Min-jun Seo-jun Do-hyun Ji-ho Hyun-woo Tae-yang Joon-ho Sung-min",
                    surnames: "Baek Yoon Seo Kang Moon Han Shin Jang Ahn Hwang",
                    birthplaces: ["Seoul, South Korea#South Korean", "Busan, South Korea#South Korean",
                                  "Incheon, South Korea#South Korean", "Daegu, South Korea#South Korean"],
                    familyFirst: true, population: 22),
        DemoCulture("zh",
                    female: "Xiaowen Meiling Ruoxi Yuting Jiayi Lanfen Shuang Qiaolian",
                    male: "Haoran Zhiwei Junjie Wenbo Tianyu Mingxuan Zihao Yichen",
                    surnames: "Lin Zhou Qiao Shen Tang Wei Gu Luo Fang Song",
                    birthplaces: ["Shanghai, China#Chinese", "Chengdu, China#Chinese", "Hangzhou, China#Chinese",
                                  "Taipei, Taiwan#Taiwanese", "Hong Kong#Hong Kong"],
                    familyFirst: true, population: 20),
        DemoCulture("sasia",
                    female: "Ananya Priya Kavya Meera Riya Ishani Nandini Tara Aditi Sanjana",
                    male: "Arjun Rohan Vikram Kabir Aarav Nikhil Dev Ishaan Rahul Siddharth",
                    surnames: "Iyer Banerjee Desai Malhotra Nair Chatterjee Rao Saxena Bhatt Kulkarni Menon Joshi",
                    birthplaces: ["Mumbai, Maharashtra, India#Indian", "Kolkata, West Bengal, India#Indian",
                                  "Chennai, Tamil Nadu, India#Indian", "Pune, Maharashtra, India#Indian", "Kochi, Kerala, India#Indian",
                                  "Leicester, England, UK#British", "Toronto, Ontario, Canada#Canadian"],
                    population: 30),
        DemoCulture("ar",
                    female: "Layla Yasmin Nour Salma Rania Dalia Mariam Huda Farida Amira",
                    male: "Omar Karim Tariq Youssef Hassan Samir Nabil Ziad Rami Faris",
                    surnames: "Haddad Mansour Khalil Nasser Saleh Farouk Aziz Hamdan Khoury Sabbagh Najjar Qasim",
                    birthplaces: ["Cairo, Egypt#Egyptian", "Alexandria, Egypt#Egyptian", "Beirut, Lebanon#Lebanese",
                                  "Amman, Jordan#Jordanian", "Dubai, United Arab Emirates#Emirati", "Casablanca, Morocco#Moroccan",
                                  "Tunis, Tunisia#Tunisian"],
                    population: 32),
        DemoCulture("slavic",
                    female: "Katarzyna Zofia Anya Milena Darya Vesna Irena Oksana Magda Jana",
                    male: "Tomasz Mikhail Pavel Andrej Bogdan Lukasz Dmitri Marek Stanislav Viktor",
                    surnames: "Kowalczyk Novak Horvat Marić Lisowski Zelenko Kral Varga Ilić Petrović Sobczak Hájek",
                    birthplaces: ["Kraków, Poland#Polish", "Gdańsk, Poland#Polish", "Prague, Czech Republic#Czech",
                                  "Zagreb, Croatia#Croatian", "Belgrade, Serbia#Serbian", "Ljubljana, Slovenia#Slovenian",
                                  "Budapest, Hungary#Hungarian"],
                    population: 26),
        DemoCulture("it",
                    female: "Giulia Chiara Francesca Alessia Martina Ludovica Serena Bianca Arianna Ottavia",
                    male: "Lorenzo Matteo Tommaso Riccardo Leonardo Giacomo Edoardo Fabrizio Massimo Pietro",
                    surnames: "Bellandi Lombardi Ricci Galli Marchesi Conti Barbieri Fontana Moretti Ferraro Santoro Vitale",
                    birthplaces: ["Rome, Italy#Italian", "Naples, Italy#Italian", "Turin, Italy#Italian", "Bologna, Italy#Italian",
                                  "Palermo, Sicily, Italy#Italian", "Venice, Italy#Italian"],
                    population: 24),
        DemoCulture("pt",
                    female: "Beatriz Mariana Larissa Fernanda Joana Raquel Letícia Teresa",
                    male: "Thiago Rafael Gustavo Leandro Caio Vinícius Duarte Rui",
                    surnames: "Albuquerque Teixeira Monteiro Cavalcanti Pacheco Azevedo Moura Siqueira Barros Nogueira",
                    birthplaces: ["São Paulo, Brazil#Brazilian", "Rio de Janeiro, Brazil#Brazilian", "Salvador, Bahia, Brazil#Brazilian",
                                  "Lisbon, Portugal#Portuguese", "Porto, Portugal#Portuguese"],
                    population: 20),
    ]

    /// Invented production companies: "name#country#culture".
    static let studios: [String] = [
        "Saltglass Pictures#US#anglo", "Ember & Oak Films#GB#anglo", "Kestrel Lane Films#GB#anglo", "Tidemark Studios#US#anglo",
        "Paper Lantern Animation#US#anglo", "Ironwood Features#US#anglo", "Velvet Compass#GB#anglo", "Driftwood Media#CA#anglo",
        "Stonefruit Pictures#US#anglo", "Brightwater Collective#AU#anglo", "Okapi Nine#US#anglo", "Larkspur Entertainment#US#anglo",
        "Cinder Lake Films#CA#anglo", "Moonmoth Studios#GB#anglo", "Northbridge Film Collective#GB#anglo",
        "Marrowstone Entertainment#IE#anglo", "Halcyon Reel Company#US#anglo", "Blue Heron Works#NZ#anglo",
        "Quarry Light Pictures#US#anglo", "Gilded Kite Media#GB#anglo",
        "Mavi Bulut Yapım#TR#tr", "Çınaraltı Film#TR#tr", "Lodos Yapım#TR#tr", "Poyraz Film#TR#tr",
        "Lindenhaus Film#DE#de", "Nordwind Pictures#DE#de", "Les Films du Héron Gris#FR#fr", "Atelier Minuit#FR#fr",
        "Faro Norte Producciones#ES#es", "Cometa Azul Films#MX#es", "Nakheel Media#AE#ar", "Wahat Studios#EG#ar",
        "Studio Kumoji#JP#ja", "Ondal Pictures#KR#ko", "Jade River Films#CN#zh", "Saffron Lane Films#IN#sasia",
        "Laguna Film#IT#it", "Ipê Filmes#BR#pt", "Fjellstue Film#NO#nordic", "Nordlys Studio#DK#nordic",
    ]

    /// Invented broadcasters and streaming services for series: "name#country#culture".
    static let networks: [String] = [
        "Harborline#US#anglo", "Albion One#GB#anglo", "Streamwell#US#anglo", "Aurora+#US#anglo", "Northlight Drama#GB#anglo",
        "Kanal Mavi#TR#tr", "Boğaz TV#TR#tr", "Rheinwelle#DE#de", "Canal Brume#FR#fr", "Onda Sur#ES#es",
        "Nakheel TV#AE#ar", "Dalbit TV#KR#ko", "Fjordkanalen#NO#nordic",
    ]

    /// Character names (F:/M:/X: marks the gender of the role) for specific titles (cast billing order), keyed by seed.
    static let featuredCharacters: [String: [String]] = [
        "neon-harbor": ["F:Ines Calloway", "M:Teodor Vasko", "F:Marguerite Hale"],
        "neon-harbor-undertow": ["F:Ines Calloway", "M:Teodor Vasko", "F:Priya Lindqvist"],
        "glasswing": ["F:Nadia Oduya", "M:Commander Elias Brandt", "F:Juno Abernathy"],
        "glasswing-ascendant": ["F:Nadia Oduya", "M:Commander Elias Brandt", "X:The Sleeper"],
        "glasswing-requiem": ["F:Captain Nadia Oduya", "M:Admiral Elias Brandt", "F:Juno Abernathy"],
        "the-ninth-precinct": ["F:Rosa Quintero", "M:Frank Dellacorte", "M:Captain Hal Brenner"],
        "the-ninth-precinct-ii": ["F:Det. Rosa Quintero", "M:Frank Dellacorte", "F:Mayor Ruth Kessling"],
        "pip-and-the-paper-moon": ["X:Pip (voice)", "X:Crane (voice)", "X:The Ink King (voice)"],
        "pip-and-the-paper-moon-2": ["X:Pip (voice)", "X:Crane (voice)", "X:The Ink King (voice)"],
        "midnight-at-the-marlowe": ["F:Jenny Albright", "M:Duke Harlan", "M:The Bellhop"],
        "return-to-the-marlowe": ["F:Jenny Albright", "M:Dr. Simon Pryce", "M:The Bellhop"],
        "saltwater-saints": ["F:Delphine Archambault", "M:Luc Archambault", "F:Agent Carla Ruiz"],
        "northbridge-general": ["F:Dr. Amara Okafor", "M:Dr. Ben Hollis", "F:Sister Maureen Doyle"],
        "karanfil-sokagi": ["F:Hayriye Teyze", "M:Bekir Usta", "F:Nazlı"],
        "moss-and-marigold": ["X:Moss (voice)", "X:Marigold (voice)", "X:Old Gnome (voice)"],
        "kite-and-comet": ["X:Kite (voice)", "X:Comet (voice)", "X:Captain Puffin (voice)"],
    ]
}
