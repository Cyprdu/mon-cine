import SwiftUI
import UserNotifications

struct Saved: Codable {
    var likes: [Film] = [], later: [Film] = [], seen: [Film] = [], ratings: [Int: Rating] = [:]
    var cinemas: [Cinema] = [], agenda: [AgendaItem] = []
    var services: [Provider] = []
    var order: [String] = [], hidden: Set<String> = []
    var alertes: [Film] = [], prevenus: Set<String> = [], episodes: Set<String> = [], zone = Zone()
    var onboarded = false, lock = false, picked = false
    init() {}
    init(from d: Decoder) throws {   // un champ absent (ancienne sauvegarde) garde sa valeur par défaut
        let c = try d.container(keyedBy: CodingKeys.self), z = Saved()
        likes = try c.decodeIfPresent([Film].self, forKey: .likes) ?? []
        later = try c.decodeIfPresent([Film].self, forKey: .later) ?? []
        seen = try c.decodeIfPresent([Film].self, forKey: .seen) ?? []
        ratings = try c.decodeIfPresent([Int: Rating].self, forKey: .ratings) ?? [:]
        cinemas = try c.decodeIfPresent([Cinema].self, forKey: .cinemas) ?? []
        agenda = try c.decodeIfPresent([AgendaItem].self, forKey: .agenda) ?? []
        services = try c.decodeIfPresent([Provider].self, forKey: .services) ?? z.services
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        picked = try c.decodeIfPresent(Bool.self, forKey: .picked) ?? false
        alertes = try c.decodeIfPresent([Film].self, forKey: .alertes) ?? []
        prevenus = try c.decodeIfPresent(Set<String>.self, forKey: .prevenus) ?? []
        episodes = try c.decodeIfPresent(Set<String>.self, forKey: .episodes) ?? []
        zone = try c.decodeIfPresent(Zone.self, forKey: .zone) ?? Zone()
        lock = try c.decodeIfPresent(Bool.self, forKey: .lock) ?? false
    }
}
struct Backup: Codable { var saved: Saved, tickets: [Ticket] }

@MainActor @Observable final class Store {
    static let shared = Store()
    var s = Saved() { didSet { save(s, "etat.json") } }
    var tickets: [Ticket] = [] { didSet { save(tickets, "billets.json") } }
    /// Le message s’efface seul : le minuteur vit ici, pas dans la vue, dont la tâche pouvait être annulée avant la fin
    var toast: String? { didSet { if toast != nil { effacer() } } }
    @ObservationIgnored private var minuteur: Task<Void, Never>?
    private func effacer() {
        minuteur?.cancel()
        minuteur = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .seconds(2.4))) != nil else { return }
            self?.toast = nil
        }
    }
    var pendingFile: URL?
    var hasKey = Trousseau.read()?.isEmpty == false || TMDB.demo

    var likes: [Film] { s.likes }
    var cinemas: [Cinema] { s.cinemas }
    var rated: [Rating] { s.ratings.values.sorted { ($0.stars, $0.date) > ($1.stars, $1.date) } }
    var upcoming: [AgendaItem] { s.agenda.filter { !$0.past }.sorted { $0.start < $1.start } }

    @ObservationIgnored private let dir = URL.applicationSupportDirectory.appending(path: "MonCine")
    @ObservationIgnored private var ready = false
    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if TMDB.demo { demo() } else {
            s = load("etat.json") ?? Saved()
            tickets = load("billets.json") ?? []
        }
        ready = true
    }
    private func load<T: Decodable>(_ n: String) -> T? {
        let u = dir.appending(path: n)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        if let d = try? Data(contentsOf: u), let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        try? FileManager.default.copyItem(at: u, to: dir.appending(path: n + ".\(Int(Date.now.timeIntervalSince1970)).bak"))   // jamais écrasé sans copie
        return nil
    }
    private func save<T: Encodable>(_ v: T, _ n: String) {
        guard ready, !TMDB.demo else { return }
        do { try JSONEncoder().encode(v).write(to: dir.appending(path: n), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch { toast = "Enregistrement impossible" }
    }
    private func demo() {
        let f = Demo.films.compactMap(TMDB.film)
        s.onboarded = true; s.picked = true; s.services = [Provider(id: 8, name: "Netflix")]; s.likes = Array(f.prefix(5)); s.later = Array(f[5...8])
        for (i, x) in f.prefix(4).enumerated() { s.ratings[x.id] = Rating(film: x, stars: 5 - Double(i) * 0.5, comment: "", date: .now) }
        s.cinemas = Salles.all.filter { ["P0012", "P3757"].contains($0.id) }
        if let c = s.cinemas.first { s.agenda = [AgendaItem(id: "d", filmID: 1, title: f[0].title, poster: nil, cinema: c, start: .now.addingTimeInterval(9000), end: .now.addingTimeInterval(16000), version: "VOST", formats: ["IMAX"], url: "https://example.com/")] }
        tickets = [Ticket(brand: .pathe, name: "CinéCarte", payload: "DEMO12345", number: "DEMO12345", pin: "0000", until: .now.addingTimeInterval(9e6)), Ticket(brand: .cinecheque, payload: "CHEQUE-0001", number: "CHEQUE-0001", until: .now.addingTimeInterval(4e6), total: 5, left: 3)]
    }

    // Films
    func liked(_ id: Int) -> Bool { s.likes.contains { $0.id == id } }
    func isLater(_ id: Int) -> Bool { s.later.contains { $0.id == id } }
    func isSeen(_ id: Int) -> Bool { s.seen.contains { $0.id == id } }
    private func flip(_ k: WritableKeyPath<Saved, [Film]>, _ f: Film) -> Bool {
        if s[keyPath: k].contains(where: { $0.id == f.id }) { s[keyPath: k].removeAll { $0.id == f.id }; return false }
        s[keyPath: k].insert(f, at: 0); return true
    }
    func like(_ f: Film) { withAnimation(.bouncy) { flip(\.likes, f) ? Haptic.heart() : Haptic.tap() } }
    func later(_ f: Film) { withAnimation(.bouncy) { flip(\.later, f) ? Haptic.ok() : Haptic.tap() } }
    func seen(_ f: Film) { withAnimation(.bouncy) { flip(\.seen, f) ? Haptic.ok() : Haptic.tap() } }
    func rate(_ f: Film, _ stars: Double, _ comment: String = "") {
        withAnimation(.bouncy) {
            if stars <= 0 { s.ratings[f.id] = nil } else {
                var n = s
                n.ratings[f.id] = Rating(film: f, stars: stars, comment: comment, date: .now)
                if !n.seen.contains(where: { $0.id == f.id }) { n.seen.insert(f, at: 0) }
                n.later.removeAll { $0.id == f.id }
                s = n
            }
        }
    }
    // Cinémas
    func isCinema(_ id: String) -> Bool { s.cinemas.contains { $0.id == id } }
    func toggle(_ c: Cinema) { withAnimation(.bouncy) { if isCinema(c.id) { s.cinemas.removeAll { $0.id == c.id }; Haptic.tap() } else { s.cinemas.append(c); Haptic.ok() } } }
    // Agenda
    func inAgenda(_ id: String) -> AgendaItem? { s.agenda.first { $0.id == id } }
    func put(_ a: AgendaItem) {
        if let i = s.agenda.firstIndex(where: { $0.id == a.id }) { s.agenda[i] = a } else { s.agenda.append(a) }
        Rappel.set(a)
    }
    func drop(_ a: AgendaItem) { withAnimation { s.agenda.removeAll { $0.id == a.id } }; Rappel.cancel(a) }
    /// Places encore libres d’une carte : restantes moins celles promises à d’autres séances à venir
    func freePlaces(_ t: Ticket, except id: String) -> Int { t.left - s.agenda.filter { $0.id != id && !$0.past }.reduce(0) { $0 + $1.tickets.filter { $0 == t.id }.count } }
    func usable(for a: AgendaItem) -> [Ticket] {
        tickets.filter { $0.usable(at: a.start) && freePlaces($0, except: a.id) > 0 }.sorted { ($0.until ?? .distantFuture) < ($1.until ?? .distantFuture) }
    }
    func useOne(_ t: Ticket) {
        guard let i = tickets.firstIndex(where: { $0.id == t.id }), tickets[i].left > 0 else { return }
        var x = tickets[i]; x.left -= 1; if x.left == 0 { x.usedAt = .now }
        withAnimation(.bouncy) { tickets[i] = x }; Haptic.ok()
    }
    func restore(_ t: Ticket) {
        guard let i = tickets.firstIndex(where: { $0.id == t.id }) else { return }
        var x = tickets[i]; x.left = min(x.total, x.left + 1); x.usedAt = nil
        withAnimation(.bouncy) { tickets[i] = x }; Haptic.tap()
    }
    func upsert(_ t: Ticket) { withAnimation(.bouncy) { if let i = tickets.firstIndex(where: { $0.id == t.id }) { tickets[i] = t } else { tickets.append(t) } } }
    func delete(_ t: Ticket) {
        withAnimation { tickets.removeAll { $0.id == t.id } }
        for i in s.agenda.indices where s.agenda[i].tickets.contains(t.id) { s.agenda[i].tickets.removeAll { $0 == t.id } }
    }
    /// Comme une première installation : clé, données, billets, caches, rappels
    func reset() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if !TMDB.demo {
            Trousseau.write(nil)
            if let b = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: b) }
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
        }
        Disk.clear(); URLCache.shared.removeAllCachedResponses(); ImageBank.shared.vider()
        Registre.shared.vider(); Accueil.shared.vider()
        pendingFile = nil; hasKey = false; tickets = []; s = Saved()
    }
    func say(_ m: String) { toast = m }
}

enum Rappel {
    static func set(_ a: AgendaItem) {
        let when = a.start.addingTimeInterval(-5400)
        cancel(a)
        guard when > .now, !TMDB.demo else { return }
        Task {
            let c = UNUserNotificationCenter.current()
            guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let n = UNMutableNotificationContent()
            n.title = a.title; n.body = "Séance à \(Jour.heure(a.start)) · \(a.cinema.name)"; n.sound = .default
            let d = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            try? await c.add(UNNotificationRequest(identifier: a.id, content: n, trigger: UNCalendarNotificationTrigger(dateMatching: d, repeats: false)))
        }
    }
    static func cancel(_ a: AgendaItem) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [a.id]) }
}
