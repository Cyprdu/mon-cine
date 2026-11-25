import SwiftUI

// MARK: Films
struct Film: Codable, Hashable, Identifiable {
    var id: Int
    var title: String
    var release: String = ""
    var poster: String?
    var back: String?
    var note: Double?
    var overview: String = ""
    var year: String { String(release.prefix(4)) }
    var upcoming: Bool { release > Jour.iso(.now) }
}
struct Person: Codable, Hashable, Identifiable { var id: Int; var name: String; var role: String; var photo: String? }
struct Provider: Codable, Hashable, Identifiable { var id: Int; var name: String; var logo: String? }
struct FilmDetail {
    var film: Film
    var original = "", runtime: Int?, tagline = "", genres: [String] = [], directors: [Person] = [], cast: [Person] = []
    var trailer: String?, logo: String?, votes = 0
    var stream: [Provider] = [], free: [Provider] = [], rent: [Provider] = [], buy: [Provider] = [], watchLink: URL?
    var similar: [Film] = []
    var cleanPoster: String?, cleanBack: String?
}
/// Grande image sans texte ; à défaut l’affiche, qui porte déjà le titre
struct Visuel {
    var path: String?, titled = false
    init(_ f: Film, _ d: FilmDetail?) {
        path = d?.cleanPoster ?? d?.cleanBack ?? f.back
        if path == nil { path = f.poster; titled = path != nil }
    }
}
struct Rating: Codable, Hashable { var film: Film; var stars: Double; var comment: String; var date: Date }

// MARK: Cinémas et séances
struct Cinema: Codable, Hashable, Identifiable {
    var id: String, name: String, address: String, lat: Double, lon: Double
    var city: String { address.firstMatch(of: /\d{5} (.+)$/).map { String($0.1) } ?? "" }
    var isPathe: Bool { name.localizedStandardContains("pathe") || name.localizedStandardContains("pathé") }
}
struct Seance: Codable, Hashable, Identifiable {
    var id: String, start: Date, end: Date?, version: String, formats: [String], url: String?, label: String
    var day: String { Jour.cine(start) }
}
struct ACFilm: Codable, Hashable, Identifiable {
    var movie: Int, title: String, original: String, years: [Int], year: Int?, runtime: Int?, genres: [String], director: String
    var poster: String?, seances: [Seance]
    var id: Int { movie }
}
struct Programme: Codable { var at = Date.now, partial = false, next: String?, films: [ACFilm] = [], stale = false }
struct AgendaItem: Codable, Hashable, Identifiable {
    var id: String, filmID: Int?, title: String, poster: String?, cinema: Cinema, start: Date, end: Date
    var version: String, formats: [String], url: String?, tickets: [UUID] = []
    var past: Bool { end < .now }
}

// MARK: Billets
enum Brand: String, Codable, CaseIterable, Identifiable {
    case pathe, cinecheque, ugc, cgr, kinepolis, megarama, autre
    var id: String { rawValue }
    var label: String {
        switch self { case .pathe: "Pathé"; case .cinecheque: "e-CinéChèque"; case .ugc: "UGC"; case .cgr: "CGR"; case .kinepolis: "Kinepolis"; case .megarama: "Megarama"; case .autre: "Cinéma" }
    }
    var colors: [Color] {
        switch self {
        case .pathe: [Color(hex: 0xFFD34D), Color(hex: 0xF08A1D)]
        case .cinecheque: [Color(hex: 0xFF5F7E), Color(hex: 0xA3195B)]
        case .ugc: [Color(hex: 0x4DA3FF), Color(hex: 0x12348C)]
        case .cgr: [Color(hex: 0x7BE0C3), Color(hex: 0x0B6E66)]
        case .kinepolis: [Color(hex: 0x9AA7FF), Color(hex: 0x3A2E9E)]
        case .megarama: [Color(hex: 0xFF8A5C), Color(hex: 0xB0261E)]
        case .autre: [Color(hex: 0xC7CBD6), Color(hex: 0x5B6172)]
        }
    }
    static func guess(_ text: String) -> Brand {
        let t = Match.plat(text)
        for (b, words) in [(Brand.cinecheque, ["cinecheque", "cine cheque"]), (.pathe, ["pathe", "cinecarte"]), (.ugc, ["ugc"]), (.cgr, ["cgr"]), (.kinepolis, ["kinepolis"]), (.megarama, ["megarama"])]
            where words.contains(where: { (" " + t + " ").contains(" " + $0) }) { return b }
        return .autre
    }
}
struct Ticket: Codable, Hashable, Identifiable {
    var id = UUID()
    var brand: Brand = .autre
    var prepaid = true            // carte ou chèque prépayé ; sinon billet d’une séance réservée
    var name = ""
    var payload: String?          // contenu exact du code scanné
    var symbology = "QR"
    var image: Data?              // découpe d’origine si le code ne peut pas être redessiné à l’identique
    var number = "", pin = ""
    var until: Date?
    var total = 1, left = 1
    var usedAt: Date?
    var added = Date.now
    var film = "", place = "", seat = ""
    var seance: Date?
    var used: Bool { usedAt != nil || left <= 0 }
    func expired(at d: Date = .now) -> Bool { until.map { Jour.iso($0) < Jour.iso(d) } ?? false }
    func usable(at d: Date) -> Bool { prepaid && !used && !expired(at: d) }
    var title: String { name.isEmpty ? (prepaid ? brand.label : (film.isEmpty ? "Billet" : film)) : name }
}

// MARK: Dates (heure de Paris, journée de cinéma jusqu’à 3 h)
enum Jour {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = paris; c.locale = Locale(identifier: "fr_FR"); return c }()
    private static func make(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: f.contains("EEE") || f.contains("MMM") ? "fr_FR" : "en_US_POSIX"); d.timeZone = paris; d.calendar = cal; d.dateFormat = f; return d
    }
    private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()
    static func fmt(_ d: Date, _ f: String) -> String { lock.withLock { let x = cache[f] ?? make(f); cache[f] = x; return x.string(from: d) } }
    static func parse(_ s: String, _ f: String) -> Date? { lock.withLock { let x = cache[f] ?? make(f); cache[f] = x; return x.date(from: s) } }
    static func iso(_ d: Date) -> String { fmt(d, "yyyy-MM-dd") }
    static func local(_ s: String) -> Date? { parse(String(s.prefix(16)), "yyyy-MM-dd'T'HH:mm") }
    static func heure(_ d: Date) -> String { fmt(d, "HH:mm") }
    static func cine(_ d: Date) -> String {
        cal.component(.hour, from: d) < 3 ? shift(iso(d), -1) : iso(d)
    }
    static func shift(_ day: String, _ n: Int) -> String {
        guard let d = parse(day, "yyyy-MM-dd"), let r = cal.date(byAdding: .day, value: n, to: d) else { return day }
        return iso(r)
    }
    static func jolie(_ day: String, long: Bool = false) -> String {
        let t = cine(.now)
        if day == t { return "Aujourd’hui" }
        if day == shift(t, 1) { return "Demain" }
        guard let d = parse(day, "yyyy-MM-dd") else { return day }
        let s = fmt(d, day.prefix(4) == t.prefix(4) ? (long ? "EEEE d MMMM" : "d MMM") : "d MMM yyyy")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    static func duree(_ m: Int) -> String { m < 60 ? "\(m) min" : "\(m / 60) h " + String(format: "%02d", m % 60) }
}

extension Color {
    init(hex: UInt) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
    static let fond = Color(hex: 0x08080D)
    static let or = Color(hex: 0xFFB52E)
    static let rose = Color(hex: 0xFF3B5C)
}
extension Double { var fr: String { String(format: "%.1f", self).replacingOccurrences(of: ".", with: ",") } }
struct Oops: LocalizedError { var errorDescription: String?; var quota = false; init(_ m: String, quota: Bool = false) { errorDescription = m; self.quota = quota } }
