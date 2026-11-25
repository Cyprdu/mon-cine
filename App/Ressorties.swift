import SwiftUI
import UserNotifications
import BackgroundTasks
import CoreLocation
import MapKit

// MARK: Base des ressorties (serveur personnel)
struct Ville: Codable, Hashable, Identifiable {
    var loc: Int, nom: String, n: Int, dates: [String]
    var id: Int { loc }
    /// « Paris 5e arrondissement » → « Paris »
    var base: String { nom.replacing(/\s\d+(er|e|ème) arrondissement/, with: "") }
}
struct Reprise: Codable, Hashable {
    var tmdb: Int?, ac: Int?, titre: String?, sortie: String?, affiche: String?, chaines: [String]?, lu: Int?, villes: [Ville]?
    /// Arrondissements regroupés sous leur ville, sans les dates passées
    var lieux: [Ville] {
        let t = Jour.cine(.now)
        let l = (villes ?? []).map { v -> Ville in var v = v; v.dates = v.dates.filter { $0 >= t }; return v }
        let noms = Set(l.map(\.nom))
        var out: [Ville] = []
        for v in l.filter({ $0.base == $0.nom || !noms.contains($0.base) }).sorted(by: { $0.loc > $1.loc }) {   // numéro négatif : indépendants
            if v.loc < 0, let i = out.firstIndex(where: { Match.plat($0.base) == Match.plat(v.base) }) {
                if !out[i].dates.isEmpty { out[i].dates = Array(Set(out[i].dates + v.dates)).sorted() }
            } else { var w = v; w.dates.sort(); if v.loc < 0 { w.nom = v.nom.localizedCapitalized }; out.append(w) }
        }
        return out
    }
    var film: Film? { tmdb.map { Film(id: $0, title: titre ?? "", release: sortie ?? "", poster: affiche) } }
}
/// Horaires gardés par la base : salles AlloCiné lues hier ou aujourd’hui, indépendants sur plusieurs semaines
struct Horaires: Codable {
    struct S: Codable { var id: String, nom: String?, adr: String?, h: [String] }
    struct I: Codable { var id: String, cine: Int, nom: String?, ville: String?, adr: String?, lat: Double?, lon: Double?, d: String, v: String?, u: String? }
    var salles: [S], ind: [I]
    private static func fin(_ d: Date, _ r: Int?) -> Date? { r.map { d.addingTimeInterval(Double($0) * 60) } }
    /// Cinéma indépendant ramené à celui de la liste AlloCiné quand il est au même endroit
    private static func cinema(_ i: I) -> Cinema {
        let at = Salles.villes[Match.plat(i.ville ?? "")], p = CLLocationCoordinate2D(latitude: i.lat ?? at?.latitude ?? 46.6, longitude: i.lon ?? at?.longitude ?? 2.4)
        if i.lat != nil, let c = Salles.search("", near: p, max: 1).first, Salles.km(c, p) < 0.25 { return c }
        return Cinema(id: "ind-\(i.cine)", name: i.nom ?? "Cinéma", address: (i.adr ?? "").trimmingCharacters(in: .whitespaces) + " " + (i.ville ?? ""), lat: p.latitude, lon: p.longitude)
    }
    func rows(_ runtime: Int?) -> [Pres.Row] {
        var out: [Pres.Row] = []
        for s in salles {
            let l = s.h.compactMap { x -> Seance? in
                let p = x.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let d = Jour.local(p[0]) else { return nil }
                return Seance(id: "b-" + s.id + x, start: d, end: Self.fin(d, runtime), version: p.count > 1 && p[1] == "VO" ? "VOST" : "VF", formats: [], url: nil, label: "")
            }
            let c = Salles.parID[s.id] ?? Cinema(id: s.id, name: s.nom ?? "Cinéma", address: s.adr ?? "", lat: 46.6, lon: 2.4)
            if !l.isEmpty { out.append(.init(cinema: c, seances: l)) }
        }
        for (_, g) in Dictionary(grouping: ind, by: \.cine) {
            let c = Self.cinema(g[0])
            if out.contains(where: { $0.cinema.id == c.id }) { out.removeAll { $0.cinema.id == c.id } }   // la programmation du cinéma va plus loin
            let l = g.compactMap { x -> Seance? in
                guard let d = Jour.local(x.d) else { return nil }
                return Seance(id: "i-" + x.id, start: d, end: Self.fin(d, runtime), version: x.v == "VERSION_ORIGINAL" || x.v?.hasPrefix("VERSION_ORIGINAL_S") == true ? "VOST" : "VF", formats: [], url: x.u.flatMap { $0.hasPrefix("https://") ? $0 : nil }, label: "")
            }
            if !l.isEmpty { out.append(.init(cinema: c, seances: l.sorted { $0.start < $1.start })) }
        }
        return out
    }
}
@MainActor @Observable final class Registre {
    static let shared = Registre()
    private(set) var films: [Int: Reprise] = [:]
    private(set) var ready = false
    /// Ajoutée à l’app livrée ou saisie dans les réglages, jamais dans le dépôt public
    static var base: URL? {
        let saisie = UserDefaults.standard.string(forKey: "serveur")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pack = Bundle.main.url(forResource: "serveur", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let h = (saisie.isEmpty ? pack : saisie).replacingOccurrences(of: "https://", with: "")
        return h.isEmpty ? nil : URL(string: "https://" + h)
    }
    private func get<T: Decodable>(_ path: String, ttl: Double, as: T.Type) async -> T? {
        guard !TMDB.demo, let u = Self.base?.appending(path: path) else { return nil }
        let key = "srv:" + path, old = Disk.read(key)
        if let old, old.age < ttl, let v = try? JSONDecoder().decode(T.self, from: old.data) { return v }
        var r = URLRequest(url: u, timeoutInterval: 10)
        r.setValue("mon-cine-perso/1.0", forHTTPHeaderField: "User-Agent")
        if let (d, res) = try? await URLSession.shared.data(for: r), (res as? HTTPURLResponse)?.statusCode == 200, let v = try? JSONDecoder().decode(T.self, from: d) { Disk.write(key, d); return v }
        return old.flatMap { try? JSONDecoder().decode(T.self, from: $0.data) }
    }
    private struct Liste: Decodable { var films: [Reprise] }
    private struct Titre: Decodable { var ac: Int, titre: String }
    func load(fresh: Bool = false) async {
        guard let l = await get("ressorties", ttl: fresh ? 0 : 1800, as: Liste.self) else { return }
        var d: [Int: Reprise] = [:]
        for f in l.films { if let i = f.tmdb { d[i] = f } }
        films = d; ready = true
    }
    func reprise(_ f: Film) async -> Reprise? {
        guard !f.tv else { return nil }
        if let r = await get("film/\(f.id)", ttl: 600, as: Reprise.self), r.tmdb != nil { films[f.id] = r; return r }
        return films[f.id]
    }
    func horaires(_ f: Film, _ ac: Int?, _ runtime: Int?) async -> [Pres.Row] {
        guard !f.tv else { return [] }
        let h = await get("horaires/\(f.id)" + (ac.map { "/\($0)" } ?? ""), ttl: 900, as: Horaires.self)
        return h?.rows(runtime) ?? []
    }
    func vider() { films = [:]; ready = false }
    /// Numéro AlloCiné : base, films en salles, puis Wikidata
    func allocine(_ f: Film, _ original: String) async -> Int? {
        if let a = films[f.id]?.ac { return a }
        if !Affiche.old(f), let l = await get("affiche", ttl: 43200, as: [Titre].self), let t = l.first(where: { Match.same([f.title, original], [$0.titre]) }) { return t.ac }
        guard !TMDB.demo else { return nil }
        let key = "wd:\(f.id)"
        if let o = Disk.read(key), o.age < 7 * 86400 { return String(data: o.data, encoding: .utf8).flatMap { Int($0) } }
        var c = URLComponents(string: "https://query.wikidata.org/sparql")!
        c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "query", value: "SELECT ?a WHERE { ?f wdt:P4947 \"\(f.id)\"; wdt:P1265 ?a } LIMIT 1")]
        var r = URLRequest(url: c.url!, timeoutInterval: 8)
        r.setValue("mon-cine-perso/1.0", forHTTPHeaderField: "User-Agent")
        guard let (d, res) = try? await URLSession.shared.data(for: r), (res as? HTTPURLResponse)?.statusCode == 200, let j = (try? JSONSerialization.jsonObject(with: d)) as? J else { return nil }
        let b = (j["results"] as? J)?["bindings"] as? [J]
        let v = (b?.first?["a"] as? J)?["value"] as? String
        Disk.write(key, Data((v ?? "").utf8))
        return v.flatMap { Int($0) }
    }
    /// Seuls des numéros de films partent au serveur
    func suivre(_ ids: [Int]) async {
        guard !TMDB.demo, !ids.isEmpty, let u = Self.base?.appending(path: "suivre") else { return }
        var r = URLRequest(url: u, timeoutInterval: 10)
        r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": ids])
        _ = try? await URLSession.shared.data(for: r)
    }
    /// Ressorties en cours, la plus proche d’abord
    func proches(_ p: CLLocationCoordinate2D) -> [(Film, Ville, Double)] {
        var l: [(Film, Ville, Double)] = []
        for r in films.values {
            guard let f = r.film, !f.title.isEmpty, Affiche.old(f), let v = Salles.proche(r.lieux, p) else { continue }
            l.append((f, v.0, v.1))
        }
        return l.sorted { $0.2 < $1.2 }
    }
}
extension Salles {
    static let villes: [String: CLLocationCoordinate2D] = {
        var s: [String: (Double, Double, Double)] = [:]
        for c in all { let k = Match.plat(c.city); let o = s[k] ?? (0, 0, 0); s[k] = (o.0 + c.lat, o.1 + c.lon, o.2 + 1) }
        return s.mapValues { CLLocationCoordinate2D(latitude: $0.0 / $0.2, longitude: $0.1 / $0.2) }
    }()
    static let noms: [String] = Array(Set(all.map(\.city))).filter { !$0.isEmpty }.sorted()
    static let parID: [String: Cinema] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    static func km(_ nom: String, _ p: CLLocationCoordinate2D) -> Double {
        guard let c = villes[Match.plat(nom)] else { return 9999 }
        return km(Cinema(id: "", name: "", address: "", lat: c.latitude, lon: c.longitude), p)
    }
    static func proche(_ l: [Ville], _ p: CLLocationCoordinate2D) -> (Ville, Double)? { l.map { ($0, km($0.base, p)) }.min { $0.1 < $1.1 } }
    static func triees(_ l: [Ville], _ p: CLLocationCoordinate2D) -> [(Ville, Double)] { l.map { ($0, km($0.base, p)) }.sorted { $0.1 < $1.1 } }
}

// MARK: Zone et alertes
struct Zone: Codable, Hashable {
    var favoris = true, nom = "", lat = 45.764, lon = 4.8357, km = 30.0
    var point: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
extension Store {
    func dansZone(_ v: Ville) -> Bool {
        if s.zone.favoris { return cinemas.contains { Match.plat($0.city) == Match.plat(v.base) || Salles.km(v.base, .init(latitude: $0.lat, longitude: $0.lon)) < 4 } }
        return Salles.km(v.base, s.zone.point) <= s.zone.km
    }
    func alerte(_ id: Int) -> Bool { s.alertes.contains { $0.id == id } }
    func alerter(_ f: Film) {
        if alerte(f.id) { withAnimation(.bouncy) { s.alertes.removeAll { $0.id == f.id } }; Haptic.tap(); return }
        withAnimation(.bouncy) { s.alertes.insert(f, at: 0) }
        Haptic.ok()
        say(s.zone.favoris && cinemas.isEmpty ? "Choisis ta zone dans les réglages" : "Tu seras prévenu de sa ressortie")
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await Registre.shared.suivre([f.id])
            await Veille.run(self)
        }
    }
}
@MainActor enum Veille {
    nonisolated static let id = "fr.cyprdu.moncine.veille"
    static func planifier() {
        guard !Store.shared.s.alertes.isEmpty else { return }
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = .now.addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }
    static func run(_ store: Store) async {
        guard !TMDB.demo, !store.s.alertes.isEmpty else { return }
        await Registre.shared.suivre(Array(store.s.alertes.map(\.id).prefix(60)))
        await Registre.shared.load(fresh: true)
        var actifs = Set<String>()
        for f in store.s.alertes {
            guard let r = Registre.shared.films[f.id] else { continue }
            for v in r.lieux where store.dansZone(v) {
                let k = "\(f.id)|\(v.loc)"
                actifs.insert(k)
                if store.s.prevenus.contains(k) { continue }
                var lieu = v.nom
                if store.s.zone.favoris, let ac = r.ac {   // l’un de ses cinémas, et pas seulement sa ville
                    lieu = await Registre.shared.horaires(f, ac, nil).first { store.isCinema($0.cinema.id) && Match.plat($0.cinema.city) == Match.plat(v.base) }?.cinema.name ?? ""
                    if lieu.isEmpty {
                        guard v.loc > 0, let n = try? await AlloCine.shared.pres(ac, v.loc, v.dates.first ?? Jour.cine(.now), runtime: nil), let c = n.rows.first(where: { store.isCinema($0.cinema.id) })?.cinema else { actifs.remove(k); continue }
                        lieu = c.name
                    }
                }
                let n = UNMutableNotificationContent()
                n.title = "\(f.title) ressort au cinéma"
                n.body = lieu + (v.dates.first.map { ", " + Jour.jolie($0, long: true).lowercased() } ?? "")
                n.sound = .default
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ressortie-" + k, content: n, trigger: nil))
                store.s.prevenus.insert(k)
            }
        }
        // Ville quittée : une prochaine ressortie préviendra de nouveau
        if Registre.shared.ready {
            let ids = Set(store.s.alertes.map(\.id))
            let garde = store.s.prevenus.filter { k in actifs.contains(k) || !(Int(k.split(separator: "|").first ?? "").map { ids.contains($0) && Registre.shared.films[$0]?.lu != nil } ?? false) }
            if garde != store.s.prevenus { store.s.prevenus = garde }
        }
    }
}
struct ZonePicker: View {
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @State private var pick = false
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Picker("Surveiller", selection: $store.s.zone.favoris.animation(.snappy)) { Text("Mes cinémas").tag(true); Text("Un périmètre").tag(false) }.pickerStyle(.segmented)
            if store.s.zone.favoris {
                Text(store.cinemas.isEmpty ? "Aucun cinéma choisi" : store.cinemas.map(\.name).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button { pick = true } label: { Label(store.s.zone.nom.isEmpty ? "Choisir une ville" : store.s.zone.nom, systemImage: "mappin.and.ellipse").lineLimit(1) }
                    Button("Ma position", systemImage: "location.fill") { pos.ask(); ici() }
                }.buttonStyle(.glass).font(.subheadline)
                Map(position: .constant(cadre), interactionModes: []) {
                    MapCircle(center: store.s.zone.point, radius: store.s.zone.km * 1000).foregroundStyle(Color.or.opacity(0.22)).stroke(Color.or, lineWidth: 2)
                }.frame(height: 190).clipShape(.rect(cornerRadius: 18)).allowsHitTesting(false)
                HStack { Slider(value: $store.s.zone.km, in: 5...150, step: 5); Text("\(Int(store.s.zone.km)) km").font(.headline).monospacedDigit().frame(width: 74, alignment: .trailing) }
            }
        }
        .onChange(of: pos.here?.latitude) { if !store.s.zone.favoris { ici() } }
        .sheet(isPresented: $pick) { CityPicker { n, c in store.s.zone.nom = n; store.s.zone.lat = c.latitude; store.s.zone.lon = c.longitude } }
    }
    private var cadre: MapCameraPosition { .region(MKCoordinateRegion(center: store.s.zone.point, latitudinalMeters: store.s.zone.km * 2500, longitudinalMeters: store.s.zone.km * 2500)) }
    private func ici() { if let h = pos.here { store.s.zone.nom = "Ma position"; store.s.zone.lat = h.latitude; store.s.zone.lon = h.longitude } }
}
struct ZoneView: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section { ZonePicker().padding(.vertical, 6) } footer: { Text("Tu es prévenu quand un film suivi ressort dans cette zone. L’iPhone vérifie de temps en temps en arrière-plan, et à chaque ouverture de l’app.") }
            Section("Films suivis (\(store.s.alertes.count))") {
                if store.s.alertes.isEmpty { Text("Touche la cloche sur la fiche d’un film ancien.").foregroundStyle(.secondary) }
                ForEach(store.s.alertes) { f in HStack(spacing: 12) { Poster(path: f.poster, title: f.title, width: 40, size: 185); VStack(alignment: .leading) { Text(f.title).font(.headline); Text(f.year).font(.caption).foregroundStyle(.secondary) } } }
                    .onDelete { store.s.alertes.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Alertes de ressortie").navigationBarTitleDisplayMode(.inline)
    }
}
struct CityPicker: View {
    let done: (String, CLLocationCoordinate2D) -> Void
    @State private var q = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let w = Match.plat(q), l = w.isEmpty ? ["Lyon", "Paris", "Marseille", "Toulouse", "Lille", "Bordeaux", "Nantes", "Nice", "Strasbourg", "Rennes", "Montpellier", "Grenoble"] : Array(Salles.noms.filter { Match.plat($0).hasPrefix(w) }.prefix(40))
            List(l, id: \.self) { n in Button(n) { if let c = Salles.villes[Match.plat(n)] { Haptic.pick(); done(n, c); dismiss() } } }
                .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ville")
                .navigationTitle("Ville").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer", systemImage: "xmark") { dismiss() } } }
        }
    }
}

// MARK: Séances d’un film autour d’une ville, en une seule demande
struct Pres: Codable {
    struct Row: Codable, Hashable { var cinema: Cinema, seances: [Seance] }
    var rows: [Row] = [], next: String?, pages = 1, at = Date.now
}
extension AlloCine {
    func pres(_ movie: Int, _ loc: Int, _ day: String, page n: Int = 1, runtime: Int?) async throws -> Pres {
        let key = "ac3:\(movie):\(loc):\(day):\(n)"
        if let o = Disk.read(key), o.age < 3 * 3600, let p = try? JSONDecoder().decode(Pres.self, from: o.data) { return p }
        let j = try await fetch("showtimes/movie-\(movie)/near-\(loc)/d-\(day)/p-\(n)/")
        guard let l = j["results"] as? [J] else { throw Oops("Le format d’AlloCiné a changé") }
        var out = Pres()
        out.next = (j["nextDate"] as? String).map { String($0.prefix(10)) }
        out.pages = (j["pagination"] as? J)?["totalPages"] as? Int ?? 1
        for x in l {
            guard let t = x["theater"] as? J, let id = t["internalId"] as? String else { continue }
            var seen = Set<String>(), s: [Seance] = []
            for (g, a) in ((x["showtimes"] as? J) ?? [:]).sorted(by: { ($0.key.contains("_") ? 0 : 1, $0.key) < ($1.key.contains("_") ? 0 : 1, $1.key) }) {
                for e in a as? [J] ?? [] { if let z = Self.seance(e, g, runtime), seen.insert(z.id).inserted { s.append(z) } }
            }
            let lo = t["location"] as? J, city = lo?["city"] as? String ?? "", at = Salles.villes[Match.plat(city)]
            let c = Salles.parID[id] ?? Cinema(id: id, name: t["name"] as? String ?? "Cinéma", address: [lo?["address"] as? String, [lo?["zip"] as? String, city].compactMap { $0 }.joined(separator: " ")].compactMap { $0 }.joined(separator: " "), lat: at?.latitude ?? 46.6, lon: at?.longitude ?? 2.4)
            if !s.isEmpty { out.rows.append(.init(cinema: c, seances: s.sorted { $0.start < $1.start })) }
        }
        if let d = try? JSONEncoder().encode(out) { Disk.write(key, d) }
        return out
    }
    func lieu(_ nom: String) async throws -> Int? {
        let key = "acl:" + nom
        if let o = Disk.read(key) { return String(data: o.data, encoding: .utf8).flatMap { Int($0) } }
        guard let q = nom.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let j = try await fetch("localization_city/\(q)")
        let l = (((j["values"] as? J)?["cities"] as? [J]) ?? []).compactMap { $0["node"] as? J }
        let i = (l.first { Match.plat($0["name"] as? String ?? "") == Match.plat(nom) } ?? l.first)?["id"] as? Int
        if let i { Disk.write(key, Data(String(i).utf8)) }
        return i
    }
}
struct FilmSeances: View {
    let film: Film, original: String, runtime: Int?
    var reprise: Reprise? = nil
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @State private var ac: Int?
    @State private var looked = false
    @State private var lieu: Ville?
    @State private var day = Jour.cine(.now)
    @State private var ver = ""
    @State private var rows: [Pres.Row] = []
    @State private var next: String?
    @State private var err: String?
    @State private var busy = true
    @State private var retry = 0
    @State private var auto = true
    @State private var pick = false
    @State private var tout = false
    @State private var base: [Pres.Row] = []
    /// Ce que la base connaît ce jour-là autour de la ville choisie
    private var gardees: [Pres.Row] {
        let nom = lieu?.base ?? "", p = Salles.villes[Match.plat(nom)] ?? pos.best
        return base.compactMap { r in
            let s = r.seances.filter { $0.day == day }
            guard !s.isEmpty, Match.plat(r.cinema.city) == Match.plat(nom) || Salles.km(r.cinema, p) < 25 else { return nil }
            return .init(cinema: r.cinema, seances: s)
        }
    }
    private var toutes: [Pres.Row] {
        rows + gardees.filter { g in !rows.contains { r in
            if r.cinema.id == g.cinema.id { return true }
            let a = Match.plat(r.cinema.name), b = Match.plat(g.cinema.name)
            return Salles.km(r.cinema, .init(latitude: g.cinema.lat, longitude: g.cinema.lon)) < 6 && (a.contains(b) || b.contains(a))
        } }
    }
    private var villes: [(Ville, Double)] { Salles.triees(reprise?.lieux ?? [], pos.best) }
    var body: some View {
        let shown = toutes.map { ($0.cinema, garde($0.seances, ver)) }.filter { !$0.1.isEmpty }.sorted { (store.isCinema($0.0.id) ? 0 : 1, Salles.km($0.0, pos.best)) < (store.isCinema($1.0.id) ? 0 : 1, Salles.km($1.0, pos.best)) }
        let known = lieu?.dates ?? []
        VStack(alignment: .leading, spacing: 14) {
            if looked && ac == nil && base.isEmpty && villes.isEmpty { CinemasSeances(film: film, original: original) } else {
                if !villes.isEmpty { carte }
                DayStrip(day: Binding { day } set: { auto = false; day = $0 }, only: known.isEmpty ? nil : known)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if villes.isEmpty { Chip(text: lieu?.nom ?? "Autour de moi", icon: "location.fill") { pick = true } }
                        ForEach(villes.prefix(12), id: \.0.loc) { v, k in Chip(text: v.nom + (k < 900 ? " · \(Int(k.rounded())) km" : ""), on: lieu?.loc == v.loc) { choisir(v) } }
                        if villes.count > 12 { Chip(text: "Toutes", icon: "list.bullet") { tout = true } }
                    }.padding(.horizontal, 18)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                HStack(spacing: 8) { Chip(text: "Tout", on: ver.isEmpty) { ver = "" }; Chip(text: "VF", on: ver == "VF") { ver = "VF" }; Chip(text: "VO", on: ver == "VO") { ver = "VO" } }.padding(.horizontal, 18)
                ForEach(shown, id: \.0.id) { c, s in
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink(value: Route.cinema(c)) { CinemaLine(cinema: c) }.buttonStyle(.plain).disabled(c.id.hasPrefix("ind-")).padding(.horizontal, 14)
                        Slots(seances: s, cinema: c, title: film.title, poster: film.poster, filmID: film.id, acID: ac ?? 0)
                    }.padding(.vertical, 14).surface().padding(.horizontal, 18)
                }
                if busy { ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.07)).frame(height: 140).modifier(Shimmer()) }.padding(.horizontal, 18) }
                if let err, shown.isEmpty { Note(text: err, icon: "exclamationmark.triangle") { retry += 1 }.padding(.horizontal, 18) }
                else if !busy && shown.isEmpty {
                    VStack(spacing: 12) {
                        Text(toutes.isEmpty ? "Aucune séance \(Jour.jolie(day).lowercased()) autour de \(lieu?.nom ?? "toi")" : "Plus de séance dans cette version").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        if let n = next, n > day { Button("Voir \(Jour.jolie(n, long: true).lowercased())") { day = n }.buttonStyle(.glass) }
                    }.frame(maxWidth: .infinity).card().padding(.horizontal, 18)
                }
            }
        }
        .task(id: reprise) {
            ac = await Registre.shared.allocine(film, original)
            base = await Registre.shared.horaires(film, ac, runtime)
            if lieu == nil { if let v = villes.first?.0 { choisir(v) } else { await ici() } }
            looked = true
        }
        .task(id: "\(ac ?? 0)|\(lieu?.loc ?? 0)|\(day)|\(retry)|\(looked)") { await load() }
        .sheet(isPresented: $pick) { CityPicker { n, _ in Task { if let i = try? await AlloCine.shared.lieu(n) { auto = true; lieu = Ville(loc: i, nom: n, n: 0, dates: []) } } } }
        .sheet(isPresented: $tout) {
            NavigationStack {
                List(villes, id: \.0.loc) { v, k in Button { choisir(v); tout = false } label: { LabeledContent(v.nom + (k < 900 ? " · \(Int(k.rounded())) km" : ""), value: v.dates.first.map { Jour.jolie($0) } ?? "") } }
                    .navigationTitle("Où il ressort").navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large])
        }
    }
    /// Résumé : villes concernées, la plus proche et la prochaine date
    private var carte: some View {
        let v = villes[0], near = store.dansZone(v.0) || v.1 < 30
        return HStack(spacing: 14) {
            Image(systemName: near ? "mappin.circle.fill" : "map.fill").font(.title).foregroundStyle(near ? .green : Color.or)
            VStack(alignment: .leading, spacing: 3) {
                Text(near ? "Près de toi : \(v.0.nom)" : "Au plus près : \(v.0.nom)" + (v.1 < 900 ? ", à \(Int(v.1.rounded())) km" : "")).font(.headline)
                Text(["\(villes.count) ville\(villes.count > 1 ? "s" : "")", v.0.dates.first.map { "dès " + Jour.jolie($0, long: true).lowercased() }, reprise?.chaines.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.card().padding(.horizontal, 18)
    }
    private func choisir(_ v: Ville) { auto = true; rows = []; next = nil; lieu = v; if let d = v.dates.first { day = d } else { day = Jour.cine(.now) } }
    private func ici() async {
        guard let n = Salles.search("", near: pos.best, max: 1).first?.city else { return }
        do { if let i = try await AlloCine.shared.lieu(n) { lieu = Ville(loc: i, nom: n, n: 0, dates: []) } else { err = "Ville introuvable" } } catch { err = error.localizedDescription; busy = false }
    }
    private func load() async {
        guard let ac, var v = lieu else { if looked && err == nil && ac != nil { await ici() } else if looked { busy = false }; return }
        busy = true; err = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            if v.loc < 0 { guard let i = try await AlloCine.shared.lieu(v.base) else { return }; v.loc = i }
            var p = try await AlloCine.shared.pres(ac, v.loc, day, runtime: runtime)
            if Task.isCancelled { return }
            // Rien ce jour-là : on saute seul à la prochaine date annoncée
            if auto, gardees.allSatisfy({ garde($0.seances, "").isEmpty }), p.rows.allSatisfy({ garde($0.seances, "").isEmpty }), let n = p.next, n > day { auto = false; day = n; return }
            auto = false
            withAnimation(.snappy) { rows = p.rows; next = p.next }
            var n = 2
            while n <= min(p.pages, 4) {
                let total = p.pages
                p = try await AlloCine.shared.pres(ac, v.loc, day, page: n, runtime: runtime)
                if Task.isCancelled { return }
                rows += p.rows.filter { r in !rows.contains { $0.cinema.id == r.cinema.id } }
                p.pages = total; n += 1
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { err = error.localizedDescription } }
    }
}
