import SwiftUI

struct Offer: Hashable, Identifiable {
    var provider: Provider, kind: String, deep: URL?, web: URL
    var id: String { "\(provider.id)\(kind)" }
    var included: Bool { ["FLATRATE", "FREE", "ADS", "FLATRATE_AND_BUY"].contains(kind) }
    var label: String { switch kind { case "RENT": "Location"; case "BUY": "Achat"; case "FREE", "ADS": "Gratuit"; default: "Inclus dans l’abonnement" } }
}

/// Catalogue français, offres et adresses exactes des films (source non officielle, usage personnel modéré)
actor JustWatch {
    static let shared = JustWatch()
    private var last = Date.distantPast, pause = Date.distantPast
    private static let fields = "objectId objectType content(country:FR,language:\"fr\"){title originalReleaseYear originalReleaseDate shortDescription posterUrl backdrops{backdropUrl} scoring{tmdbScore} externalIds{tmdbId}}"

    private func ask(_ q: String, _ vars: J, ttl: Double) async throws -> J {
        let body = try JSONSerialization.data(withJSONObject: ["query": q, "variables": vars] as J, options: .sortedKeys)
        let key = "jw1:" + (String(data: body, encoding: .utf8) ?? "")
        func decode(_ d: Data) -> J? { ((try? JSONSerialization.jsonObject(with: d)) as? J)?["data"] as? J }
        let old = Disk.read(key)
        if let old, old.age < ttl, let j = decode(old.data) { return j }
        do {
            guard pause < .now else { throw Oops("Catalogue en pause, réessaie plus tard", quota: true) }
            let slot = max(Date.now, last.addingTimeInterval(0.25)); last = slot   // quatre demandes par seconde au plus
            if slot > .now { try await Task.sleep(for: .seconds(slot.timeIntervalSinceNow)) }
            var r = URLRequest(url: URL(string: "https://apis.justwatch.com/graphql")!, timeoutInterval: 12)
            r.httpMethod = "POST"; r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("mon-cine-perso/1.0", forHTTPHeaderField: "User-Agent")
            let (d, res) = try await URLSession.shared.data(for: r)
            let s = (res as? HTTPURLResponse)?.statusCode ?? 0
            if s == 403 || s == 429 { pause = .now.addingTimeInterval(900) }
            guard s == 200, let j = decode(d) else { throw Oops("Catalogue indisponible") }
            Disk.write(key, d)
            return j
        } catch { if Task.isCancelled { throw CancellationError() }; if let old, let j = decode(old.data) { return j }; throw error }
    }
    static func image(_ p: String?, _ profile: String) -> String? { p.map { "https://images.justwatch.com" + $0.replacingOccurrences(of: "{profile}", with: profile).replacingOccurrences(of: "{format}", with: "webp") } }
    static func film(_ n: J) -> Film? {
        guard let c = n["content"] as? J, let t = c["title"] as? String, let id = ((c["externalIds"] as? J)?["tmdbId"] as? String).flatMap({ Int($0) }), let p = c["posterUrl"] as? String else { return nil }
        return Film(id: n["objectType"] as? String == "SHOW" ? -id : id, title: t.replacingOccurrences(of: "\u{a0}", with: " "), release: c["originalReleaseDate"] as? String ?? (c["originalReleaseYear"] as? Int).map { "\($0)-01-01" } ?? "", poster: image(p, "s332"),
                    back: image(((c["backdrops"] as? [J])?.first)?["backdropUrl"] as? String, "s1440"), note: (c["scoring"] as? J)?["tmdbScore"] as? Double, overview: c["shortDescription"] as? String ?? "")
    }
    /// Filtres : genres, countries, packages (identifiants), cinema, min, max, runtime, sort
    func list(_ p: [String: String], page: Int = 1, size: Int = 24) async throws -> [Film] {
        if TMDB.demo { return page > 1 ? [] : p["type"] == "tv" ? Demo.series : Demo.films.compactMap(TMDB.film) }
        if p["mix"] != nil {   // un film français pour un film étranger populaire en France
            var q = p; q["mix"] = nil
            let all = try await list(q, page: page, size: size)
            q["countries"] = "FR"
            let fr = (try? await list(q, page: page, size: size)) ?? []
            var out: [Film] = [], seen = Set<Int>()
            for i in 0..<max(all.count, fr.count) { for l in [fr, all] where i < l.count && seen.insert(l[i].id).inserted { out.append(l[i]) } }
            return out
        }
        var f: J = ["objectTypes": p["type"] == "tv" ? ["SHOW"] : p["type"] == "all" ? ["MOVIE", "SHOW"] : ["MOVIE"]]
        if let g = p["genres"] { f["genres"] = g.components(separatedBy: ",") }
        if let c = p["countries"] { f["productionCountries"] = [c] }
        if let k = p["packages"] {
            let all = try await packages()
            let short = all.filter { k.components(separatedBy: ",").contains(String($0.id)) }.map(\.short)
            guard !short.isEmpty else { return [] }
            f["packages"] = short
            f["monetizationTypes"] = ["FLATRATE", "FREE", "ADS"]
        }
        if p["cinema"] != nil { f["monetizationTypes"] = ["CINEMA"] }
        var y: J = [:]; if let a = p["min"].flatMap({ Int($0) }) { y["min"] = a }; if let b = p["max"].flatMap({ Int($0) }) { y["max"] = b }
        if !y.isEmpty { f["releaseYear"] = y }
        if let r = p["runtime"].flatMap({ Int($0) }) { f["runtime"] = ["min": 60, "max": r] }
        var v: J = ["f": f, "s": p["sort"] ?? "POPULAR", "n": size]
        if page > 1 { v["a"] = Data(String((page - 1) * size).utf8).base64EncodedString() }
        let j = try await ask("query($f:TitleFilter!,$s:PopularTitlesSorting!,$n:Int!,$a:String){popularTitles(country:FR,filter:$f,first:$n,after:$a,sortBy:$s){edges{node{\(Self.fields)}}}}", v, ttl: 43200)
        var seen = Set<Int>()
        return (((j["popularTitles"] as? J)?["edges"] as? [J]) ?? []).compactMap { ($0["node"] as? J).flatMap(Self.film) }.filter { seen.insert($0.id).inserted }
    }
    func packages() async throws -> [(id: Int, short: String, provider: Provider)] {
        if TMDB.demo { return [(8, "nfx", Provider(id: 8, name: "Netflix")), (119, "prv", Provider(id: 119, name: "Amazon Prime Video")), (337, "dnp", Provider(id: 337, name: "Disney Plus")), (381, "cpd", Provider(id: 381, name: "Canal+"))] }
        let j = try await ask("{packages(country:FR,platform:WEB){packageId shortName clearName icon}}", [:], ttl: 7 * 86400)
        return ((j["packages"] as? [J]) ?? []).compactMap { x in
            guard let i = x["packageId"] as? Int, let s = x["shortName"] as? String, let n = x["clearName"] as? String else { return nil }
            return (i, s, Provider(id: i, name: n.trimmingCharacters(in: .whitespaces), logo: Self.image(x["icon"] as? String, "s100")))
        }
    }
    /// Services, les plus utilisés en France d’abord
    func services() async throws -> [Provider] {
        let top = [8, 119, 337, 381, 1899, 350, 531, 234, 1754, 147, 236, 283, 415, 11, 1967, 58, 2, 10, 35]
        let l = try await packages().map(\.provider).filter { !$0.name.localizedCaseInsensitiveContains("with ads") && !$0.name.localizedCaseInsensitiveContains("sport") }
        return l.enumerated().sorted { (top.firstIndex(of: $0.element.id) ?? 100 + $0.offset) < (top.firstIndex(of: $1.element.id) ?? 100 + $1.offset) }.map(\.element)
    }
    func offers(_ film: Film, original: String = "") async throws -> [Offer] {
        if TMDB.demo {
            let n = Offer(provider: Provider(id: 8, name: "Netflix"), kind: "FLATRATE", deep: URL(string: "https://www.netflix.com/watch/1"), web: URL(string: "https://www.netflix.com/title/1")!)
            return film.id.isMultiple(of: 2) ? [n] : [Offer(provider: Provider(id: 2140, name: "Cinémas Pathé"), kind: "CINEMA", deep: nil, web: URL(string: "https://www.pathe.fr")!)]
        }
        for t in [film.title, original] where !t.isEmpty {
            let j = try await ask("query($f:TitleFilter!){popularTitles(country:FR,filter:$f,first:8,sortBy:POPULAR){edges{node{content(country:FR,language:\"fr\"){externalIds{tmdbId}} offers(country:FR,platform:IOS){monetizationType package{clearName packageId icon} standardWebURL deeplinkURL(platform:IOS)}}}}}", ["f": ["objectTypes": [film.tv ? "SHOW" : "MOVIE"], "searchQuery": t] as J], ttl: 21600)
            let nodes = (((j["popularTitles"] as? J)?["edges"] as? [J]) ?? []).compactMap { $0["node"] as? J }
            guard let n = nodes.first(where: { ((($0["content"] as? J)?["externalIds"] as? J)?["tmdbId"] as? String) == String(abs(film.id)) }) else { continue }
            var seen = Set<String>()
            return ((n["offers"] as? [J]) ?? []).compactMap { o -> Offer? in
                guard let k = o["monetizationType"] as? String, let p = o["package"] as? J, let i = p["packageId"] as? Int, let w = (o["standardWebURL"] as? String).flatMap({ URL(string: $0) }), w.scheme == "https" else { return nil }
                let d = (o["deeplinkURL"] as? String).flatMap { URL(string: $0) }
                return Offer(provider: Provider(id: i, name: (p["clearName"] as? String ?? "").trimmingCharacters(in: .whitespaces), logo: Self.image(p["icon"] as? String, "s100")), kind: k, deep: d, web: w)
            }.filter { seen.insert($0.id).inserted }
        }
        return []
    }
}

/// Formules d’un même service (Netflix avec pub, Prime avec pub…) ; les « chaînes » restent à part
func famille(_ p: Provider) -> String {
    let n = p.name.lowercased()
    if n.contains("channel") { return n }
    if n.contains("netflix") { return "netflix" }
    if n.contains("prime video") { return "prime" }
    if n.contains("disney") { return "disney" }
    if n.contains("hbo") || n == "max" { return "hbo" }
    if n.contains("paramount") { return "paramount" }
    if n == "canal+" || n == "canal plus" { return "canal" }
    if n == "apple tv" || n == "apple tv+" || n == "apple tv plus" { return "appletv" }
    return n
}
extension Store {
    func owns(_ p: Provider) -> Bool { let f = famille(p); return s.services.contains { famille($0) == f } }
    /// Première offre incluse chez un service possédé
    func direct(_ l: [Offer]) -> Offer? { s.services.lazy.compactMap { p in l.first { $0.included && famille($0.provider) == famille(p) } }.first }
}

/// Lien universel vers la lecture, puis lien propre à l’app, puis fiche ; le navigateur seulement si l’app manque.
@MainActor enum Lecture {
    static func open(_ o: Offer) async {
        Haptic.ok()
        var l: [(URL, Bool)] = []
        if let d = o.deep { l.append((d, d.scheme == "https")) }
        for u in [o.deep, o.web].compactMap({ $0 }) {
            let h = u.host() ?? ""
            if h.hasSuffix("netflix.com"), let x = URL(string: u.absoluteString.replacingOccurrences(of: "https://", with: "nflx://")) { l.append((x, false)) }
            if h.hasSuffix("primevideo.com"), let x = URL(string: "aiv://aiv/detail?" + (u.query() ?? "")) { l.append((x, false)) }
            if h.hasSuffix("disneyplus.com"), let x = URL(string: u.absoluteString.replacingOccurrences(of: "https://", with: "disneyplus://")) { l.append((x, false)) }
        }
        l.append((o.web, true))
        for (u, universal) in l {
            let ok = await UIApplication.shared.open(u, options: universal ? [.universalLinksOnly: true] : [:])
            if ok { return }
        }
        await UIApplication.shared.open(o.web)
    }
}

/// Films à l’affiche en France, ressorties comprises
@MainActor @Observable final class Affiche {
    static let shared = Affiche()
    private(set) var ids = Set<Int>()
    func load() async {
        if let l = try? await JustWatch.shared.list(["cinema": "1"], size: 100) { ids = Set(l.map(\.id)) }
        else if let l = try? await TMDB.list("/movie/now_playing") { ids = Set(l.map(\.id)) }
        if TMDB.demo { ids = ids.filter { !$0.isMultiple(of: 2) } }
    }
    /// Film ancien déjà relu par la base et sans aucune ville : il n’est plus en salles
    func has(_ f: Film) -> Bool {
        if f.tv { return false }
        if Self.old(f), let r = Registre.shared.films[f.id], r.lu != nil { return !r.lieux.isEmpty }
        return ids.contains(f.id)
    }
    static func old(_ f: Film) -> Bool { Jour.parse(f.release, "yyyy-MM-dd").map { $0 < .now.addingTimeInterval(-540 * 86400) } ?? false }
    func reissue(_ f: Film) -> Bool { has(f) && Self.old(f) }
}
extension ACFilm { var reissue: Bool { year.map { $0 <= (Int(Jour.iso(.now).prefix(4)) ?? 0) - 3 } ?? false } }
struct Ressortie: View {
    var long = true
    var body: some View {
        Label(long ? "Ressortie exceptionnelle" : "Ressortie", systemImage: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 4).background(Color.or, in: .capsule)
    }
}

enum Catalogue {
    static func list(_ path: String, _ p: [String: String], page: Int = 1) async throws -> [Film] {
        guard path == "jw" else { return try await TMDB.list(path, p, page: page).filter { TMDB.demo || ($0.poster != nil && !$0.overview.isEmpty) } }
        do { return try await JustWatch.shared.list(p, page: page) } catch is CancellationError { throw CancellationError() } catch {
            if p["cinema"] != nil, p["max"] == nil { return try await TMDB.list("/movie/now_playing", page: page) }
            throw error
        }
    }
}

// MARK: Lecture ou séances
struct PlayButton: View {
    let film: Film
    var offers: [Offer]? = nil
    var known = false
    @Environment(Store.self) private var store
    @State private var busy = false
    @State private var sheet: Offres?
    struct Offres: Identifiable { let id = UUID(); let list: [Offer] }
    var body: some View {
        Button {
            Task {
                busy = true; defer { busy = false }
                let l: [Offer]
                if let offers { l = offers } else { l = (try? await JustWatch.shared.offers(film)) ?? [] }
                if let o = store.direct(l) { await Lecture.open(o) } else { Haptic.tap(); sheet = Offres(list: l.filter { $0.kind != "CINEMA" }) }
            }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.black) } else { Image(systemName: "play.fill") }
                Text("Regarder").lineLimit(1)
            }.font(.headline).frame(maxWidth: known ? .infinity : nil).frame(height: 34).padding(.horizontal, known ? 0 : 12).foregroundStyle(.black)
        }
        .buttonStyle(.glassProminent).tint(.white).disabled(busy)
        .sheet(item: $sheet) { PlatformSheet(film: film, offers: $0.list) }
    }
}
struct PlatformSheet: View {
    let film: Film, offers: [Offer]
    @State private var d: FilmDetail?
    @State private var loaded = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Poster(path: film.poster, title: film.title, width: 70)
                        VStack(alignment: .leading, spacing: 4) { Text(film.title).font(.title2.bold()); Text(offers.isEmpty ? "" : "Où le regarder en France").foregroundStyle(.secondary) }
                    }
                    if !offers.isEmpty { OfferList(offers: offers) }
                    else if let d, !(d.stream + d.free + d.rent + d.buy).isEmpty { ProviderList(film: film, d: d) }
                    else if loaded { Note(text: "Pas disponible en streaming, en location ou à l’achat en France pour l’instant.", icon: "play.slash") }
                    else { ProgressView().frame(maxWidth: .infinity) }
                    Text("Disponibilités : JustWatch.").font(.caption2).foregroundStyle(.tertiary)
                }.padding(18)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { if offers.isEmpty { d = try? await TMDB.detail(film.id) }; loaded = true }
    }
}
struct OfferList: View {
    let offers: [Offer]
    @Environment(Store.self) private var store
    var body: some View {
        let groups = ["Inclus dans l’abonnement", "Gratuit", "Location", "Achat"].map { t in (t, offers.filter { $0.kind != "CINEMA" && $0.label == t }.sorted { store.owns($0.provider) && !store.owns($1.provider) }) }.filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.0) { t, l in
                VStack(alignment: .leading, spacing: 8) {
                    Text(t).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(l) { o in
                        Button { Task { await Lecture.open(o) } } label: {
                            HStack(spacing: 12) {
                                Pic(url: TMDB.img(o.provider.logo, 92)) { Color.white.opacity(0.12) }.frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 1) { Text(o.provider.name).font(.headline); if store.owns(o.provider) && o.included { Text("Mon abonnement").font(.caption2).foregroundStyle(Color.or) } }
                                Spacer()
                                Image(systemName: o.included ? "play.fill" : "arrow.up.right").foregroundStyle(.secondary)
                            }.padding(.horizontal, 14).frame(height: 62).contentShape(.rect)
                        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                    }
                }
            }
        }
    }
}
/// Secours sans adresse exacte : recherche du titre chez le service
struct ProviderList: View {
    let film: Film, d: FilmDetail
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(Set(d.stream + d.free + d.rent + d.buy)).sorted { $0.name < $1.name }) { p in
                Button { if let u = Stream.url(p, film.title) ?? d.watchLink { openURL(u) } } label: {
                    HStack { Pic(url: TMDB.img(p.logo, 92)) { Color.white.opacity(0.12) }.frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 10)); Text(p.name).font(.headline); Spacer(); Image(systemName: "magnifyingglass") }.padding(.horizontal, 14).frame(height: 62).contentShape(.rect)
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            }
        }
    }
}
struct ServicePicker: View {
    @Environment(Store.self) private var store
    @State private var all: [Provider] = []
    @State private var more = false
    @State private var failed = false
    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                ForEach(more ? all : Array(all.prefix(15))) { p in
                    let on = store.owns(p)
                    Button {
                        Haptic.pick()
                        withAnimation(.bouncy) { if on { store.s.services.removeAll { famille($0) == famille(p) } } else { store.s.services.append(p) } }
                    } label: {
                        VStack(spacing: 6) {
                            Pic(url: TMDB.img(p.logo, 92)) { Blank(title: p.name) }.frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 16))
                                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Color.or : .clear, lineWidth: 3) }
                                .overlay(alignment: .topTrailing) { if on { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.black, Color.or).font(.title3).offset(x: 7, y: -7).transition(.scale) } }
                                .opacity(on ? 1 : 0.7)
                            Text(p.name.replacingOccurrences(of: "Amazon ", with: "")).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if all.isEmpty { if failed { Note(text: "Liste indisponible, tu pourras choisir plus tard dans les réglages.") } else { ProgressView().padding() } }
            else if all.count > 15 { Button(more ? "Voir moins" : "Voir toutes les plateformes") { withAnimation { more.toggle() } }.font(.subheadline.weight(.semibold)) }
        }
        .task {
            guard let l = try? await JustWatch.shared.services() else { failed = true; return }
            all = l
            for i in store.s.services.indices { if let p = l.first(where: { famille($0) == famille(store.s.services[i]) }), store.s.services[i] != p { store.s.services[i] = p } }
        }
    }
}
