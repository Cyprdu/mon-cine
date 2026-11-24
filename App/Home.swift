import SwiftUI

@main struct MonCineApp: App {
    @State private var store = Store.shared
    var body: some Scene {
        WindowGroup {
            Root().environment(store).environment(Position.shared).preferredColorScheme(.dark).tint(.or)
                .onOpenURL { if $0.isFileURL { store.pendingFile = $0 } }
                .task(priority: .background) { Disk.purge() }
        }
    }
}

enum Onglet: String { case home, cine, mine, tickets, search }
struct Root: View {
    @Environment(Store.self) private var store
    @State private var tab = Onglet(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .home
    @State private var paths: [Onglet: [Route]] = [:]
    private func path(_ t: Onglet) -> Binding<[Route]> { Binding { paths[t] ?? [] } set: { paths[t] = $0 } }
    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Accueil", systemImage: "play.tv.fill", value: Onglet.home) { Pile(path: path(.home)) { HomeView() } }
            Tab("Séances", systemImage: "popcorn.fill", value: Onglet.cine) { Pile(path: path(.cine)) { CineTab() } }
            Tab("Ma liste", systemImage: "heart.fill", value: Onglet.mine) { Pile(path: path(.mine)) { LibraryView() } }
            Tab("Billets", systemImage: "ticket.fill", value: Onglet.tickets) { Pile(path: path(.tickets)) { TicketsView() } }
            Tab("Recherche", systemImage: "magnifyingglass", value: Onglet.search, role: .search) { Pile(path: path(.search)) { SearchView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { Haptic.pick() }
        .onChange(of: store.pendingFile) { if store.pendingFile != nil { tab = .tickets } }
        .onAppear {
            if store.pendingFile != nil { tab = .tickets }
            if TMDB.demo, UserDefaults.standard.bool(forKey: "film"), let f = store.likes.first { paths[.home] = [.film(f, "x")] }
        }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t).font(.subheadline.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 13).glassEffect(.regular, in: .capsule).padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) { try? await Task.sleep(for: .seconds(2.4)); if !Task.isCancelled { store.toast = nil } }
            }
        }
        .animation(.bouncy, value: store.toast)
        .fullScreenCover(isPresented: Binding { !store.s.onboarded } set: { store.s.onboarded = !$0 }) { Welcome().environment(store).environment(Position.shared).preferredColorScheme(.dark).tint(.or) }
    }
}

// MARK: Catégories
struct RailDef: Identifiable, Hashable {
    enum Kind: Hashable { case seances, likes, later, rated, cinema, because, query(String, [String: String]) }
    var id: String, title: String, icon: String, kind: Kind, logo: String? = nil
    @MainActor static func all(_ s: Store) -> [RailDef] {
        let today = Jour.iso(.now)
        func disc(_ id: String, _ t: String, _ i: String, _ p: [String: String]) -> RailDef { RailDef(id: id, title: t, icon: i, kind: .query("/discover/movie", ["include_adult": "false", "sort_by": "popularity.desc"].merging(p) { $1 })) }
        var l = [
            RailDef(id: "seances", title: "Mes prochaines séances", icon: "calendar", kind: .seances),
            RailDef(id: "now", title: "À l’affiche", icon: "popcorn.fill", kind: .query("/movie/now_playing", [:])),
            RailDef(id: "cinema", title: "Dans mon cinéma", icon: "mappin.and.ellipse", kind: .cinema),
            RailDef(id: "later", title: "À voir", icon: "bookmark.fill", kind: .later),
            RailDef(id: "likes", title: "Mes coups de cœur", icon: "heart.fill", kind: .likes),
            RailDef(id: "rated", title: "Mes mieux notés", icon: "star.fill", kind: .rated),
            RailDef(id: "because", title: "Parce que tu as aimé…", icon: "sparkles", kind: .because),
            RailDef(id: "trend", title: "Tendances de la semaine", icon: "flame.fill", kind: .query("/trending/movie/week", [:])),
            disc("soon", "Prochainement au cinéma", "calendar.badge.clock", ["primary_release_date.gte": Jour.shift(today, 1), "primary_release_date.lte": Jour.shift(today, 120), "with_release_type": "3"]),
            disc("top", "Les mieux notés par le public", "trophy.fill", ["sort_by": "vote_average.desc", "vote_count.gte": "3000"]),
            disc("topyear", "Les mieux notés de l’année", "rosette", ["sort_by": "vote_average.desc", "vote_count.gte": "150", "primary_release_year": String(today.prefix(4))]),
        ]
        for p in s.s.services {
            var r = disc("p\(p.id)", "Sur " + p.name, "play.rectangle.fill", ["with_watch_providers": "\(p.id)", "watch_region": "FR", "with_watch_monetization_types": "flatrate|free|ads"])
            r.logo = p.logo; l.append(r)
        }
        l += [
            disc("gems", "Pépites méconnues", "diamond.fill", ["sort_by": "vote_average.desc", "vote_count.gte": "200", "vote_count.lte": "1500", "vote_average.gte": "7.4"]),
            disc("fr", "Cinéma français", "flag.fill", ["with_original_language": "fr", "vote_count.gte": "80"]),
            disc("short", "Moins de 1 h 30", "timer", ["with_runtime.lte": "90", "with_runtime.gte": "60", "vote_count.gte": "500"]),
        ]
        for (g, t, i) in [(28, "Action", "bolt.fill"), (35, "Comédie", "theatermasks.fill"), (878, "Science-fiction", "sparkle.magnifyingglass"), (27, "Horreur", "moon.fill"), (16, "Animation", "paintpalette.fill"), (10749, "Romance", "heart.circle.fill"), (53, "Thriller", "eye.fill"), (18, "Drame", "drop.fill"), (12, "Aventure", "map.fill"), (99, "Documentaires", "globe.europe.africa.fill")] {
            l.append(disc("g\(g)", t, i, ["with_genres": "\(g)", "vote_count.gte": "200"]))
        }
        l += [disc("90", "Cultes des années 90", "opticaldisc.fill", ["primary_release_date.gte": "1990-01-01", "primary_release_date.lte": "1999-12-31", "vote_count.gte": "2000", "sort_by": "vote_average.desc"]),
              disc("80", "Cultes des années 80", "recordingtape", ["primary_release_date.gte": "1980-01-01", "primary_release_date.lte": "1989-12-31", "vote_count.gte": "1500", "sort_by": "vote_average.desc"])]
        let pos = Dictionary(s.s.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return l.enumerated().sorted { (pos[$0.element.id] ?? 1000 + $0.offset) < (pos[$1.element.id] ?? 1000 + $1.offset) }.map(\.element)
    }
}

struct HomeView: View {
    @Environment(Store.self) private var store
    @State private var hero: [Film] = []
    @State private var current: Int?
    @State private var err: String?
    @State private var reload = 0
    @State private var dice: Film?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !store.hasKey {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "key.fill").font(.largeTitle).foregroundStyle(Color.or)
                        Text("Il manque ta clé TMDB").font(.title2.bold())
                        Text("Elle donne accès aux films, affiches et bandes-annonces. Elle est gratuite et reste dans le trousseau de ton iPhone.").foregroundStyle(.secondary)
                        NavigationLink(value: Route.settings) { Text("Ajouter la clé").frame(maxWidth: .infinity) }.buttonStyle(.glassProminent).controlSize(.large)
                    }.card().padding(.horizontal, 18).padding(.top, 110)
                } else if let err, hero.isEmpty { Note(text: err, icon: "wifi.exclamationmark") { reload += 1 }.padding(.horizontal, 18).padding(.top, 110) } else { HeroCarousel(films: hero, current: $current) }
                ForEach(RailDef.all(store).filter { !store.s.hidden.contains($0.id) }) { r in RailView(def: r, reload: reload) }
                Text("Ce produit utilise l’API TMDB mais n’est ni approuvé ni certifié par TMDB. Disponibilité en streaming : JustWatch. Séances : AlloCiné.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.bottom, 30)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background { Ambient(path: (hero.first { $0.id == current } ?? hero.first).map { $0.back ?? $0.poster ?? "" }) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Text("Mon Ciné").font(.system(.title2, design: .rounded, weight: .heavy)).fixedSize() }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { Button("Surprends-moi", systemImage: "dice.fill") { roll() }.symbolEffect(.bounce, value: dice) }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: Route.settings) { Image(systemName: "gearshape.fill") }.accessibilityLabel("Réglages") }
        }
        .navigationDestination(item: $dice) { FilmView(film: $0) }
        .refreshable { Haptic.tap(); Disk.clear(); reload += 1; await load() }
        .task(id: "\(reload)\(store.hasKey)") { await load() }
    }
    private func load() async {
        guard store.hasKey else { return }
        do {
            let l = try await TMDB.list("/movie/now_playing")
            err = nil
            withAnimation { hero = Array(l.filter { TMDB.demo || $0.back != nil }.prefix(7)) }
            if current == nil { current = hero.first?.id }
        } catch is CancellationError {} catch { err = error.localizedDescription }
    }
    private func roll() {
        let pool = (store.s.later.isEmpty ? hero : store.s.later).filter { $0.id != dice?.id }
        guard let f = pool.randomElement() else { return store.say("Ajoute d’abord des films à voir") }
        Haptic.stars(); dice = f
    }
}

struct HeroCarousel: View {
    let films: [Film]
    @Binding var current: Int?
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var touched = Date.distantPast
    var body: some View {
        VStack(spacing: 12) {
            if films.isEmpty { Rectangle().fill(.white.opacity(0.06)).frame(height: 590).modifier(Shimmer()) } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(films) { f in
                            HeroCard(film: f).containerRelativeFrame(.horizontal)
                                .scrollTransition(.interactive, axis: .horizontal) { v, p in v.opacity(1 - abs(p.value) * 0.6).scaleEffect(1 - abs(p.value) * 0.06) }
                        }
                    }.scrollTargetLayout()
                }
                .frame(height: 590).scrollTargetBehavior(.paging).scrollIndicators(.hidden).scrollPosition(id: $current)
                .onScrollPhaseChange { _, p in if p == .interacting { touched = .now; Haptic.soft() } }
                HStack(spacing: 6) {
                    ForEach(films) { f in Capsule().fill(.white.opacity(f.id == current ? 1 : 0.3)).frame(width: f.id == current ? 22 : 7, height: 7) }
                }.animation(.bouncy, value: current).accessibilityHidden(true)
            }
        }
        .task(id: current) {
            guard !calm, films.count > 1 else { return }
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, Date.now.timeIntervalSince(touched) > 6, let i = films.firstIndex(where: { $0.id == current }) else { return }
            withAnimation(.smooth(duration: 0.9)) { current = films[(i + 1) % films.count].id }
        }
    }
}
struct HeroCard: View {
    let film: Film
    @Environment(Store.self) private var store
    @State private var d: FilmDetail?
    @State private var zoom = false
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.overlay { Pic(url: TMDB.img(film.poster ?? film.back, 780)) { Blank(title: "") }.scaleEffect(zoom ? 1.08 : 1) }.clipped()
                .mask { LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }
            VStack(spacing: 14) {
                if let l = d?.logo { Pic(url: TMDB.img(l, 500), mode: .fit) { Color.clear }.frame(maxWidth: 280, maxHeight: 100) }
                else { Text(film.title).font(.system(size: 34, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6).shadow(radius: 12) }
                Text([d?.genres.prefix(2).joined(separator: ", "), d?.runtime.map(Jour.duree), film.note.map { "★ " + $0.fr }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        NavigationLink(value: Route.film(film, "hero-\(film.id)")) { Label("Voir le film", systemImage: "play.fill").font(.headline).frame(height: 34).padding(.horizontal, 10) }.buttonStyle(.glassProminent).tint(.white).foregroundStyle(.black)
                        HeartButton(film: film, big: true)
                        Button { store.later(film) } label: { Image(systemName: store.isLater(film.id) ? "bookmark.fill" : "bookmark").font(.title3).contentTransition(.symbolEffect(.replace)).frame(width: 48, height: 48) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("À voir")
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 8)
        }
        .modifier(ZoomSource(id: "hero-\(film.id)"))
        .task { d = try? await TMDB.detail(film.id) }
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { zoom = true } }
    }
}

struct RailView: View {
    let def: RailDef, reload: Int
    @Environment(Store.self) private var store
    @State private var films: [Film] = []
    @State private var loaded = false
    @State private var title: String?
    private var seed: Film? { store.rated.first { $0.stars >= 4 }?.film ?? store.likes.first }
    private var shown: [Film] {
        switch def.kind {
        case .likes: store.likes
        case .later: store.s.later
        case .rated: store.rated.map(\.film)
        default: films
        }
    }
    private var remote: Bool { switch def.kind { case .query: true; case .because: seed != nil; default: false } }
    private var more: Route? {
        switch def.kind {
        case .query(let p, let q): .grid(GridQuery(title: def.title, path: p, params: q))
        case .likes, .later, .rated: .grid(GridQuery(title: def.title, path: "", films: shown))
        case .because: seed.map { .grid(GridQuery(title: title ?? def.title, path: "/movie/\($0.id)/recommendations")) }
        default: nil
        }
    }
    var body: some View {
        Group {
            switch def.kind {
            case .seances: if !store.upcoming.isEmpty { VStack(alignment: .leading, spacing: 12) { RailHead(title: def.title, icon: def.icon); RailScroll { ForEach(store.upcoming) { AgendaCard(item: $0).frame(width: 320) } } } }
            case .cinema: if let c = store.cinemas.first { CinemaRail(cinema: c) }
            default:
                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RailHead(title: title ?? def.title, icon: def.icon, more: more, logo: def.logo)
                        if def.id == "trend" { top10 } else { RailScroll { ForEach(shown) { FilmTile(film: $0, source: "\(def.id)-\($0.id)").railFade() } } }
                    }
                } else if remote && !loaded && store.hasKey { VStack(alignment: .leading, spacing: 12) { RailHead(title: def.title, icon: def.icon, logo: def.logo); GhostRail() } }
                else { Color.clear.frame(height: 0.1) }
            }
        }
        .task(id: "\(reload)\(store.hasKey)\(seed?.id ?? 0)") { await load() }
    }
    /// Classement façon télévision : grand chiffre derrière l’affiche
    private var top10: some View {
        RailScroll(spacing: 4) {
            ForEach(Array(shown.prefix(10).enumerated()), id: \.element.id) { i, f in
                HStack(alignment: .bottom, spacing: -16) {
                    Text("\(i + 1)").font(.system(size: 110, weight: .black, design: .rounded)).tracking(-12).foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)).offset(y: -22).accessibilityHidden(true)
                    FilmTile(film: f, source: "\(def.id)-\(f.id)")
                }.fixedSize().railFade()
            }
        }
    }
    private func load() async {
        guard store.hasKey else { return }
        defer { loaded = true }
        do {
            switch def.kind {
            case .query(let p, let q): films = try await TMDB.list(p, q).filter { TMDB.demo || $0.poster != nil }
            case .because:
                guard let seed else { films = []; return }
                films = try await TMDB.list("/movie/\(seed.id)/recommendations").filter { TMDB.demo || $0.poster != nil }
                title = "Parce que tu as aimé « \(seed.title) »"
            default: break
            }
        } catch {}
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
            if loading { GhostRail() } else if films.isEmpty { Text("Aucune séance à venir aujourd’hui ni demain.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18) } else {
                Text(Jour.jolie(day)).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, -8)
                RailScroll { ForEach(films) { f in
                    let h = f.seances.filter { $0.start > .now }.map { Jour.heure($0.start) }
                    ACTile(film: f, caption: h.prefix(2).joined(separator: " · ") + (h.count > 2 ? " · +\(h.count - 2)" : ""), width: 132).railFade()
                } }
            }
        }
        .task(id: cinema.id) {
            loading = true
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
    @State private var open: Film?
    @State private var busy = false
    @Environment(Store.self) private var store
    var body: some View {
        Button {
            busy = true
            Task { do { if let f = try await TMDB.resolve(film) { open = f } else { Haptic.warn(); store.say("Fiche introuvable pour ce film") } } catch { store.say(error.localizedDescription) }; busy = false }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Poster(path: film.poster, title: film.title, width: width).overlay { if busy { ProgressView().padding(16).glassEffect(.regular, in: .circle) } }
                if !caption.isEmpty {
                    Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(width: width)
        }
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
