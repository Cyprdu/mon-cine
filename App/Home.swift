import SwiftUI

@main struct MonCineApp: App {
    @State private var store = Store.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Root().environment(store).environment(Position.shared).preferredColorScheme(.dark).tint(.or)
                .onOpenURL { if $0.isFileURL { store.pendingFile = $0 } }
                .task(priority: .background) { Disk.purge() }
                .task { try? await Task.sleep(for: .seconds(6)); await Veille.run(store) }
                .onChange(of: phase) { _, p in if p == .background { Veille.planifier() } }
        }
        .backgroundTask(.appRefresh(Veille.id)) { await Veille.planifier(); await Veille.run(Store.shared) }
    }
}

enum Onglet: String { case home, cine, mine, search }
struct Root: View {
    @Environment(Store.self) private var store
    @State private var tab = Onglet(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .home
    @State private var paths: [Onglet: [Route]] = [:]
    @State private var booted = false
    private func path(_ t: Onglet) -> Binding<[Route]> { Binding { paths[t] ?? [] } set: { paths[t] = $0 } }
    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Accueil", systemImage: "play.tv.fill", value: Onglet.home) { Pile(path: path(.home)) { HomeView() } }
            Tab("Cinéma", systemImage: "popcorn.fill", value: Onglet.cine) { Pile(path: path(.cine)) { CineTab() } }
            Tab("Ma liste", systemImage: "heart.fill", value: Onglet.mine) { Pile(path: path(.mine)) { LibraryView() } }
            Tab("Recherche", systemImage: "magnifyingglass", value: Onglet.search, role: .search) { Pile(path: path(.search)) { SearchView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { Haptic.pick() }
        .onChange(of: store.pendingFile) { if store.pendingFile != nil { tab = .cine } }
        .onAppear {
            if store.pendingFile != nil { tab = .cine }
            if UserDefaults.standard.string(forKey: "tab") == "tickets" { tab = .cine }
            if TMDB.demo, UserDefaults.standard.bool(forKey: "film"), let f = store.likes.first { paths[.home] = [.film(f, "x")] }
            if TMDB.demo, UserDefaults.standard.bool(forKey: "serie"), let f = Demo.series.first { paths[.home] = [.film(f, "x")] }
        }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t).font(.subheadline.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 13).glassEffect(.regular, in: .capsule).padding(.top, 6)
                    .onTapGesture { store.toast = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        .overlay { if !booted && store.s.onboarded && tab == .home { Splash().transition(.opacity) } }
        .task {
            let t = Task { await Accueil.shared.start(store) }
            for _ in 0..<35 where !Accueil.shared.ready { try? await Task.sleep(for: .milliseconds(100)) }
            withAnimation(.easeOut(duration: 0.4)) { booted = true }
            await t.value
        }
        .fullScreenCover(isPresented: Binding { !store.s.onboarded || !store.s.picked } set: { _ in }) { Welcome().environment(store).environment(Position.shared).preferredColorScheme(.dark).tint(.or) }
    }
}

// MARK: Catégories
struct RailDef: Identifiable, Hashable {
    enum Kind: Hashable { case seances, likes, later, rated, cinema, because, foryou, reissues, query(String, [String: String]) }
    var id: String, title: String, icon: String, kind: Kind, logo: String? = nil
    var serie: Bool { if case .query(let p, let q) = kind { q["type"] == "tv" || p.hasPrefix("/tv") || p.hasSuffix("/tv") } else { false } }
    static let vitrine: Set<String> = ["ttrend", "tfr", "tcrm", "tani"]
    @MainActor static func all(_ s: Store) -> [RailDef] {
        let y = Int(Jour.iso(.now).prefix(4)) ?? 2026
        func jw(_ id: String, _ t: String, _ i: String, _ p: [String: String]) -> RailDef { RailDef(id: id, title: t, icon: i, kind: .query("jw", p)) }
        var l = [
            RailDef(id: "seances", title: "Mes prochaines séances", icon: "calendar", kind: .seances),
            jw("now", "À l’affiche en France", "popcorn.fill", ["cinema": "1", "min": "\(y - 1)"]),
            RailDef(id: "reissue", title: "Ressorties au cinéma", icon: "sparkles", kind: .reissues),
            RailDef(id: "foryou", title: "Recommandé pour toi", icon: "wand.and.stars", kind: .foryou),
            RailDef(id: "cinema", title: "Dans mon cinéma", icon: "mappin.and.ellipse", kind: .cinema),
            RailDef(id: "later", title: "À voir", icon: "bookmark.fill", kind: .later),
            jw("trend", "Top 10 en France", "flame.fill", ["sort": "TRENDING", "type": "all"]),
            jw("ttrend", "Séries du moment", "tv.fill", ["type": "tv", "sort": "TRENDING"]),
        ]
        for p in s.s.services { var r = jw("p\(p.id)", "Sur " + p.name.replacingOccurrences(of: "Amazon ", with: ""), "play.rectangle.fill", ["packages": "\(p.id)", "type": "all"]); r.logo = p.logo; l.append(r); var t = jw("tp\(p.id)", "Séries " + p.name.replacingOccurrences(of: "Amazon ", with: ""), "tv.fill", ["packages": "\(p.id)", "type": "tv"]); t.logo = p.logo; l.append(t) }
        l += [
            RailDef(id: "likes", title: "Mes coups de cœur", icon: "heart.fill", kind: .likes),
            RailDef(id: "rated", title: "Mes mieux notés", icon: "star.fill", kind: .rated),
            RailDef(id: "because", title: "Parce que tu as aimé…", icon: "wand.and.stars", kind: .because),
            jw("fr", "Cinéma français du moment", "flag.fill", ["countries": "FR", "min": "\(y - 2)"]),
            jw("frcmy", "Comédies françaises", "theatermasks.fill", ["countries": "FR", "genres": "cmy"]),
            jw("cult", "Comédies cultes françaises", "quote.bubble.fill", ["countries": "FR", "genres": "cmy", "max": "2005"]),
            RailDef(id: "top", title: "Les mieux notés par le public", icon: "trophy.fill", kind: .query("/discover/movie", ["sort_by": "vote_average.desc", "vote_count.gte": "5000", "include_adult": "false"])),
            jw("frtop", "Grands films français", "rosette", ["countries": "FR", "min": "1930", "max": "\(y - 8)"]),
            jw("polar", "Polars et thrillers français", "magnifyingglass", ["countries": "FR", "genres": "crm,trl"]),
            jw("classic", "Classiques du cinéma français", "film.fill", ["countries": "FR", "max": "1979"]),
            jw("short", "Moins de 1 h 30", "timer", ["runtime": "90", "mix": "1"]),
        ]
        for (g, t, i) in [("cmy", "Comédies", "face.smiling"), ("act", "Action et aventure", "bolt.fill"), ("drm", "Drames", "drop.fill"), ("scf", "Science-fiction", "sparkle.magnifyingglass"), ("trl", "Thrillers", "eye.fill"), ("fml", "En famille", "figure.2.and.child.holdinghands"), ("ani", "Animation", "paintpalette.fill"), ("rma", "Comédies romantiques", "heart.circle.fill"), ("fnt", "Fantastique", "wand.and.stars"), ("hrr", "Horreur", "moon.fill"), ("doc", "Documentaires", "globe.europe.africa.fill"), ("war", "Films de guerre", "shield.fill"), ("msc", "Musique", "music.note")] {
            l.append(jw("g" + g, t, i, ["genres": g, "mix": "1"]))
        }
        l += [jw("2000", "Succès des années 2000", "opticaldisc.fill", ["min": "2000", "max": "2009", "mix": "1"]), jw("90", "Cultes des années 90", "opticaldisc.fill", ["min": "1990", "max": "1999", "mix": "1"]), jw("80", "Cultes des années 80", "recordingtape", ["min": "1980", "max": "1989", "mix": "1"])]
        func tv(_ id: String, _ t: String, _ i: String, _ p: [String: String]) -> RailDef { jw(id, t, i, p.merging(["type": "tv"]) { a, _ in a }) }
        l += [
            tv("tfr", "Séries françaises", "flag.fill", ["countries": "FR"]), tv("tcrm", "Séries policières", "magnifyingglass", ["genres": "crm,trl", "mix": "1"]), tv("tcmy", "Séries comiques", "face.smiling", ["genres": "cmy", "mix": "1"]),
            RailDef(id: "ttop", title: "Séries les mieux notées", icon: "trophy.fill", kind: .query("/discover/tv", ["sort_by": "vote_average.desc", "vote_count.gte": "2000"])),
            tv("tdrm", "Séries dramatiques", "drop.fill", ["genres": "drm"]), tv("tscf", "Science-fiction et fantastique", "sparkle.magnifyingglass", ["genres": "scf,fnt"]), tv("tact", "Action et aventure", "bolt.fill", ["genres": "act"]),
            tv("tani", "Animés japonais", "paintpalette.fill", ["genres": "ani", "countries": "JP"]), tv("tkr", "Séries coréennes", "globe.asia.australia.fill", ["countries": "KR"]), tv("tgb", "Séries britanniques", "globe.europe.africa.fill", ["countries": "GB"]),
            tv("tfml", "Séries en famille", "figure.2.and.child.holdinghands", ["genres": "fml"]), tv("tdoc", "Séries documentaires", "camera.fill", ["genres": "doc", "mix": "1"]), tv("told", "Séries cultes", "recordingtape", ["min": "1985", "max": "2009"]),
        ]
        let pos = Dictionary(s.s.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return l.enumerated().sorted { (pos[$0.element.id] ?? 1000 + $0.offset) < (pos[$1.element.id] ?? 1000 + $1.offset) }.map(\.element)
    }
}

/// Contenu de l’accueil, gardé hors des vues : rien ne se recharge ni ne change de hauteur en remontant.
@MainActor @Observable final class Accueil {
    static let shared = Accueil()
    var hero: [Film] = []
    var rails: [String: [Film]] = [:]
    var titles: [String: String] = [:]
    var details: [Int: FilmDetail] = [:]
    var failed = false
    var ready = false
    @ObservationIgnored private var running = false
    func start(_ store: Store) async {
        guard !running else { return }
        running = true; defer { running = false }
        async let a: Void = Affiche.shared.load()
        async let reg: Void = Registre.shared.load()
        let cine = (try? await Catalogue.list("jw", ["cinema": "1"])) ?? [], soft = (try? await Catalogue.list("jw", store.s.services.isEmpty ? ["sort": "TRENDING", "type": "all"] : ["packages": store.s.services.map { String($0.id) }.joined(separator: ","), "type": "all"])) ?? []
        var h: [Film] = []
        for f in cine.prefix(5) + soft.prefix(4) where !h.contains(where: { $0.id == f.id }) { h.append(f) }
        failed = h.isEmpty
        if !h.isEmpty {
            await withTaskGroup(of: (Int, FilmDetail?).self) { g in
                for f in h { g.addTask { (f.id, try? await TMDB.detail(f.id)) } }
                for await (i, x) in g { if let x { details[i] = x } }
            }
            await ImageBank.shared.prefetch(h.prefix(2).flatMap { [TMDB.img(Visuel($0, details[$0.id]).path, 780), TMDB.img(details[$0.id]?.logo, 500)] })
            hero = h
        }
        await a
        await reg
        // Ce que l’accueil montre d’abord, puis les rayons réservés aux onglets Films et Séries
        let tous = RailDef.all(store).filter { !store.s.hidden.contains($0.id) }
        let defs = tous.filter { !$0.serie || RailDef.vitrine.contains($0.id) } + tous.filter { $0.serie && !RailDef.vitrine.contains($0.id) }
        for (n, d) in defs.enumerated() {
            await load(d, store)
            if n >= 4 { ready = true }
        }
        ready = true
        await ImageBank.shared.prefetch(h.flatMap { [TMDB.img(Visuel($0, details[$0.id]).path, 780), TMDB.img(details[$0.id]?.logo, 500)] })
    }
    func load(_ d: RailDef, _ store: Store) async {
        var l: [Film] = []
        switch d.kind {
        case .query(let p, let q): l = (try? await Catalogue.list(p, q)) ?? rails[d.id] ?? []
        case .because:
            if let s = Self.seed(store) { l = (try? await Catalogue.list(s.chemin + "/recommendations", [:])) ?? rails[d.id] ?? []; titles[d.id] = "Parce que tu as aimé « \(s.title) »" }
        case .foryou: l = await Self.conseils(store)
        case .reissues: l = Registre.shared.ready ? Array(Registre.shared.proches(Position.shared.best).prefix(40).map(\.0)) : (try? await Catalogue.list("jw", ["cinema": "1", "max": "\((Int(Jour.iso(.now).prefix(4)) ?? 2026) - 2)"])) ?? rails[d.id] ?? []
        default: return
        }
        await ImageBank.shared.prefetch(l.prefix(5).map { TMDB.img($0.poster, 342) })
        rails[d.id] = l
        Task(priority: .utility) { await ImageBank.shared.prefetch(l.dropFirst(5).map { TMDB.img($0.poster, 342) }) }
    }
    /// Films et séries proches de ceux que l’utilisateur a le mieux notés ; ce qui revient le plus souvent passe devant
    static func conseils(_ s: Store) async -> [Film] {
        var bases: [(Film, Double)] = s.rated.filter { $0.stars >= 3.5 }.prefix(12).map { ($0.film, $0.stars - 2.5) }
        for f in s.likes.prefix(8) where !bases.contains(where: { $0.0.id == f.id }) && s.s.ratings[f.id] == nil { bases.append((f, 1)) }
        guard !bases.isEmpty else { return [] }
        let ecartes = Set(s.s.seen.map(\.id) + s.likes.map(\.id) + Array(s.s.ratings.keys))
        var score: [Int: Double] = [:], film: [Int: Film] = [:]
        for (b, poids) in bases {
            for p in [1, 2] {
                let l = (try? await TMDB.list(b.chemin + "/recommendations", [:], page: p, ttl: 3 * 86400)) ?? []
                for (i, f) in l.enumerated() where !ecartes.contains(f.id) && f.poster != nil && !f.overview.isEmpty {
                    score[f.id, default: 0] += poids * (1 - Double(i + (p - 1) * 20) / 60) * (0.5 + (f.note ?? 6) / 14)
                    film[f.id] = f
                }
            }
        }
        // Un film mal noté fait reculer ce qui lui ressemble
        for r in s.rated.suffix(4) where r.stars <= 2 {
            for f in (try? await TMDB.list(r.film.chemin + "/recommendations", [:], ttl: 3 * 86400)) ?? [] { score[f.id]? -= 1 }
        }
        return score.sorted { $0.value > $1.value }.prefix(40).compactMap { film[$0.key] }
    }
    static func seed(_ s: Store) -> Film? { s.rated.first { $0.stars >= 4 }?.film ?? s.likes.first }
}
struct Splash: View {
    var body: some View {
        ZStack {
            Color.fond.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "popcorn.fill").font(.system(size: 60)).foregroundStyle(Color.or).phaseAnimator([1.0, 1.12]) { v, p in v.scaleEffect(p) } animation: { _ in .easeInOut(duration: 0.7) }
                Text("Mon Ciné").font(.system(size: 34, weight: .heavy, design: .rounded))
            }
        }
    }
}

enum Genre: String, CaseIterable { case tout = "Tout", films = "Films", series = "Séries" }
struct HomeView: View {
    @State private var genre = Genre.tout
    @State private var remue = 0
    @Environment(Store.self) private var store
    private var acc = Accueil.shared
    @State private var current: Int?
    @State private var dice: Film?
    private func visible(_ r: RailDef) -> Bool {
        if store.s.hidden.contains(r.id) { return false }
        if genre == .tout && r.serie && !RailDef.vitrine.contains(r.id) { return false }
        if genre == .films && (r.serie || r.id == "ttrend") { return false }
        if genre == .series && !r.serie && r.id != "foryou" { return false }
        switch r.kind {
        case .seances: return !store.upcoming.isEmpty
        case .likes: return !store.likes.isEmpty
        case .later: return !store.s.later.isEmpty
        case .rated: return !store.s.ratings.isEmpty
        case .cinema: return !store.cinemas.isEmpty
        case .because: return Accueil.seed(store) != nil && acc.rails[r.id]?.isEmpty != true
        case .foryou: return acc.rails[r.id]?.isEmpty == false
        case .query, .reissues: return acc.rails[r.id]?.isEmpty != true
        }
    }
    private var une: [Film] {
        switch genre {
        case .tout: acc.hero
        case .films: acc.hero.filter { !$0.tv }
        case .series: acc.hero.filter(\.tv) + (acc.rails["ttrend"] ?? []).prefix(6).filter { f in !acc.hero.contains { $0.id == f.id } }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if acc.failed && acc.hero.isEmpty { Note(text: "Connexion impossible. Vérifie Internet puis réessaie.", icon: "wifi.exclamationmark") { Task { await acc.start(store) } }.padding(.horizontal, 18).padding(.top, 110) }
                else {
                    HeroCarousel(films: une, current: $current, remue: remue).id(genre)
                        .overlay(alignment: .top) {
                            GlassEffectContainer(spacing: 8) { HStack(spacing: 8) { ForEach(Genre.allCases, id: \.self) { g in Chip(text: g.rawValue, on: g == genre) { current = nil; genre = g } } } }.padding(.top, 108)
                        }
                }
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(RailDef.all(store).filter(visible)) { RailView(def: $0, genre: genre) }
                    Text("Ce produit utilise l’API TMDB mais n’est ni approuvé ni certifié par TMDB. Catalogue et streaming : JustWatch. Séances : AlloCiné.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.bottom, 30)
                }
            }
        }
        .onScrollPhaseChange { _, p in if p != .idle { remue += 1 } }
        .ignoresSafeArea(edges: .top).scrollEdgeEffectHidden(true, for: .top)
        .background { Ambient(path: (acc.hero.first { $0.id == current } ?? acc.hero.first).map { $0.back ?? $0.poster ?? "" }) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Text("Mon Ciné").font(.system(.title2, design: .rounded, weight: .heavy)).fixedSize() }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { Button("Surprends-moi", systemImage: "dice.fill") { roll() }.symbolEffect(.bounce, value: dice) }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: Route.settings) { Image(systemName: "gearshape.fill") }.accessibilityLabel("Réglages") }
        }
        .navigationDestination(item: $dice) { FilmView(film: $0) }
        .refreshable { Haptic.tap(); await acc.start(store) }
        .onChange(of: store.s.services.map(\.id)) { Task { for d in RailDef.all(store) where d.id.hasPrefix("p") && acc.rails[d.id] == nil { await acc.load(d, store) } } }
        .onChange(of: "\(store.s.ratings.count)|\(store.likes.count)|\(store.rated.first?.film.id ?? 0)") { Task { for d in RailDef.all(store) where d.id == "because" || d.id == "foryou" { await acc.load(d, store) } } }
    }
    private func roll() {
        let pool = (store.s.later.isEmpty ? acc.hero : store.s.later).filter { $0.id != dice?.id }
        guard let f = pool.randomElement() else { return store.say("Ajoute d’abord des films à voir") }
        Haptic.stars(); dice = f
    }
}

struct HeroCarousel: View {
    let films: [Film]
    @Binding var current: Int?
    var remue = 0
    @State private var bande: Int?
    @State private var tick = 0
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var touched = Date.distantPast
    var body: some View {
        VStack(spacing: 12) {
            if films.isEmpty { Rectangle().fill(.white.opacity(0.06)).frame(height: 590).modifier(Shimmer()) } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(films) { f in
                            HeroCard(film: f, bande: bande == f.id).containerRelativeFrame(.horizontal)
                                .scrollTransition(.interactive, axis: .horizontal) { v, p in v.opacity(1 - abs(p.value) * 0.6).scaleEffect(1 - abs(p.value) * 0.06) }
                        }
                    }.scrollTargetLayout()
                }
                .frame(height: 590).scrollTargetBehavior(.paging).scrollIndicators(.hidden).scrollPosition(id: $current)
                .onScrollPhaseChange { _, p in if p == .interacting { touched = .now; bande = nil; tick += 1; Haptic.soft() } }
                HStack(spacing: 6) {
                    ForEach(films) { f in Capsule().fill(.white.opacity(f.id == current ? 1 : 0.3)).frame(width: f.id == current ? 22 : 7, height: 7) }
                }.animation(.bouncy, value: current).accessibilityHidden(true)
            }
        }
        .onChange(of: films.map(\.id), initial: true) { if !films.contains(where: { $0.id == current }) { current = films.first?.id } }
        .onChange(of: remue) { bande = nil; tick += 1 }
        .onDisappear { bande = nil }
        .task(id: "\(current ?? 0)|\(tick)") {
            bande = nil
            guard !calm, let f = films.first(where: { $0.id == current }) else { return }
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            // Cinq secondes sans geste : la bande-annonce muette remplace l’image
            if Accueil.shared.details[f.id]?.trailer != nil, !ProcessInfo.processInfo.isLowPowerModeEnabled { bande = f.id; try? await Task.sleep(for: .seconds(32)) } else { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled, films.count > 1, let i = films.firstIndex(where: { $0.id == current }) else { return }
            bande = nil
            withAnimation(.smooth(duration: 0.9)) { current = films[(i + 1) % films.count].id }
        }
    }
}
struct HeroCard: View {
    let film: Film
    var bande = false
    @Environment(Store.self) private var store
    @State private var tried = false
    private var d: FilmDetail? { Accueil.shared.details[film.id] }
    private var ready: Bool { d != nil || tried }
    var body: some View {
        let art = Visuel(film, d)
        ZStack(alignment: .bottom) {
            Color.clear.overlay { if ready { Pic(url: TMDB.img(art.path, 780)) { Blank(title: "") }.phaseAnimator([1.0, 1.07]) { v, p in v.scaleEffect(p) } animation: { _ in .easeInOut(duration: 9) } } }
                .overlay { if bande, let k = d?.trailer { Bande(key: k) } }.clipped()
                .mask { LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }
            VStack(spacing: 14) {
                if Affiche.shared.reissue(film) { Ressortie() }
                if let l = d?.logo { Pic(url: TMDB.img(l, 500), mode: .fit) { Color.clear }.frame(maxWidth: 280, maxHeight: 100) }
                else if ready && !art.titled { Text(film.title).font(.system(size: 34, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6).shadow(radius: 12) }
                Text([d?.genres.prefix(2).joined(separator: ", "), d?.runtime.map(Jour.duree), d.flatMap { $0.saisons.isEmpty ? nil : "\($0.saisons.count) saison\($0.saisons.count > 1 ? "s" : "")" }, film.sur5.map { "★ " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if Affiche.shared.has(film) {
                            NavigationLink(value: Route.film(film, "hero-\(film.id)")) { Label("Séances", systemImage: "ticket.fill").font(.headline).frame(height: 34).padding(.horizontal, 12).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.or)
                        } else { PlayButton(film: film) }
                        HeartButton(film: film, big: true)
                        Button { store.later(film) } label: { Image(systemName: store.isLater(film.id) ? "bookmark.fill" : "bookmark").font(.title3).contentTransition(.symbolEffect(.replace)).frame(width: 48, height: 48) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("À voir")
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 8)
        }
        .contentShape(.rect)
        .background { NavigationLink(value: Route.film(film, "hero-\(film.id)")) { Color.clear } }
        .modifier(ZoomSource(id: "hero-\(film.id)"))
        .task { if d == nil, let x = try? await TMDB.detail(film.id) { Accueil.shared.details[film.id] = x }; tried = true }
    }
}

struct RailView: View {
    let def: RailDef, genre: Genre
    @Environment(Store.self) private var store
    private var acc = Accueil.shared
    init(def: RailDef, genre: Genre = .tout) { self.def = def; self.genre = genre }
    private var shown: [Film]? { genre == .tout ? brut : brut?.filter { $0.tv == (genre == .series) } }
    private var brut: [Film]? {
        switch def.kind {
        case .likes: store.likes
        case .later: store.s.later
        case .rated: store.rated.map(\.film)
        default: acc.rails[def.id]
        }
    }
    private var title: String { acc.titles[def.id] ?? def.title }
    private var more: Route? {
        switch def.kind {
        case .query(let p, let q): .grid(GridQuery(title: def.title, path: p, params: q))
        case .likes, .later, .rated: .grid(GridQuery(title: def.title, path: "", films: shown))
        case .because: Accueil.seed(store).map { .grid(GridQuery(title: title, path: $0.chemin + "/recommendations")) }
        case .foryou, .reissues: .grid(GridQuery(title: def.title, path: "", films: shown))
        default: nil
        }
    }
    private var incine: Bool { if case .query(_, let q) = def.kind { q["cinema"] != nil } else { false } }
    var body: some View {
        switch def.kind {
        case .seances: VStack(alignment: .leading, spacing: 12) { RailHead(title: def.title, icon: def.icon); RailScroll { ForEach(store.upcoming) { AgendaCard(item: $0).frame(width: 320) } } }
        case .cinema: if let c = store.cinemas.first { CinemaRail(cinema: c) }
        default:
            VStack(alignment: .leading, spacing: 12) {
                RailHead(title: title, icon: def.icon, more: more, logo: def.logo)
                Group {
                    if let shown { if def.id == "trend" { top10(shown) } else { RailScroll { ForEach(shown) { FilmTile(film: $0, source: "\(def.id)-\($0.id)", caption: lieu($0), incine: incine).railFade() } } } }
                    else { GhostRail() }
                }.frame(height: 250, alignment: .top)
            }
            // Tout le rayon est prêt en mémoire avant d’être parcouru
            .task(id: shown?.count) { await ImageBank.shared.prefetch((shown ?? []).map { TMDB.img($0.poster, 342) }) }
        }
    }
    /// Ressorties : la ville la plus proche et sa prochaine date
    private func lieu(_ f: Film) -> String? {
        guard def.kind == .reissues, let r = Registre.shared.films[f.id], let v = Salles.proche(r.lieux, Position.shared.best) else { return nil }
        return [v.0.base, v.0.dates.first.map { Jour.jolie($0) }].compactMap { $0 }.joined(separator: " · ")
    }
    /// Classement façon télévision : grand chiffre derrière l’affiche
    private func top10(_ l: [Film]) -> some View {
        RailScroll(spacing: 4) {
            ForEach(Array(l.prefix(10).enumerated()), id: \.element.id) { i, f in
                HStack(alignment: .bottom, spacing: -16) {
                    Text("\(i + 1)").font(.system(size: 110, weight: .black, design: .rounded)).tracking(-12).foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)).offset(y: -22).accessibilityHidden(true)
                    FilmTile(film: f, source: "\(def.id)-\(f.id)")
                }.fixedSize().railFade()
            }
        }
    }
}

/// Ce qui passe encore aujourd’hui (ou demain) dans le premier cinéma favori
struct CinemaRail: View {
    let cinema: Cinema
    @State private var day = Jour.cine(.now)
    @State private var films: [ACFilm] = []
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RailHead(title: cinema.name, icon: "mappin.and.ellipse", more: .cinema(cinema))
            Group { if loading { GhostRail() } else if films.isEmpty { Text("Aucune séance à venir aujourd’hui ni demain.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18) } else { VStack(alignment: .leading, spacing: 12) {
                Text(Jour.jolie(day)).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, -8)
                RailScroll { ForEach(films) { f in
                    let h = f.seances.filter { $0.start > .now }.map { Jour.heure($0.start) }
                    ACTile(film: f, caption: h.prefix(2).joined(separator: " · ") + (h.count > 2 ? " · +\(h.count - 2)" : ""), width: 132).railFade()
                } }
            } } }.frame(height: 270, alignment: .top)
        }
        .task(id: cinema.id) {
            guard loading || films.isEmpty else { return }
            for d in [Jour.cine(.now), Jour.shift(Jour.cine(.now), 1)] {
                let l = ((try? await AlloCine.shared.programme(cinema.id, d))?.films ?? []).filter { $0.seances.contains { $0.start > .now } }
                if !l.isEmpty { day = d; films = l; break }
            }
            withAnimation { loading = false }
        }
    }
}
/// Film AlloCiné : la fiche TMDB n’est cherchée qu’au toucher
struct ACTile: View {
    let film: ACFilm, caption: String
    var width: CGFloat? = nil
    var body: some View {
        ACOpen(film: film) {
            VStack(alignment: .leading, spacing: 7) {
                Poster(path: film.poster, title: film.title, width: width).overlay(alignment: .topLeading) { if film.reissue { Ressortie(long: false).padding(5) } }
                Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: width)
        }
    }
}
struct ACOpen<L: View>: View {
    let film: ACFilm
    @ViewBuilder var label: L
    @State private var open: Film?
    @State private var busy = false
    @Environment(Store.self) private var store
    var body: some View {
        Button {
            guard !busy else { return }
            Haptic.tap(); busy = true
            Task { do { if let f = try await TMDB.resolve(film) { open = f } else { Haptic.warn(); store.say("Fiche introuvable pour ce film") } } catch { store.say(error.localizedDescription) }; busy = false }
        } label: { label.overlay { if busy { ProgressView().padding(14).glassEffect(.regular, in: .circle) } } }
        .buttonStyle(Press()).accessibilityLabel(film.title)
        .sheet(item: $open) { f in FilmSheet(film: f) }
    }
}
struct FilmSheet: View {
    let film: Film
    @State private var path: [Route] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View { Pile(path: $path) { FilmView(film: film).toolbar { ToolbarItem(placement: .topBarLeading) { Button("Fermer", systemImage: "xmark") { dismiss() } } } } }
}
