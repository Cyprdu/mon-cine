import SwiftUI
import UniformTypeIdentifiers

// MARK: Ma liste
struct LibraryView: View {
    enum Part: String, CaseIterable { case likes = "J’aime", later = "À voir", rated = "Notés", seen = "Vus", alertes = "Alertes", agenda = "Séances" }
    @Environment(Store.self) private var store
    @State private var part = Part.likes
    private var films: [Film] {
        switch part { case .likes: store.likes; case .later: store.s.later; case .rated: store.rated.map(\.film); case .seen: store.s.seen; case .alertes: store.s.alertes; case .agenda: [] }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    stat("\(store.s.seen.count)", "vus", "eye.fill"); stat("\(store.likes.count)", "coups de cœur", "heart.fill")
                    stat(store.rated.isEmpty ? "–" : (store.rated.reduce(0) { $0 + $1.stars } / Double(store.rated.count)).fr, "note moyenne", "star.fill")
                }.padding(.horizontal, 18)
                ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(Part.allCases, id: \.self) { p in Chip(text: p.rawValue, on: p == part) { part = p } } }.padding(.horizontal, 18) }.scrollIndicators(.hidden).scrollClipDisabled()
                if part == .agenda {
                    let l = store.s.agenda.sorted { $0.start > $1.start }
                    if l.isEmpty { empty("Aucune séance enregistrée") }
                    LazyVStack(spacing: 12) { ForEach(l) { AgendaCard(item: $0).opacity($0.past ? 0.6 : 1) } }.padding(.horizontal, 18)
                } else if part == .rated {
                    if films.isEmpty { empty("Note un film depuis sa fiche") }
                    LazyVStack(spacing: 12) {
                        ForEach(store.rated, id: \.film.id) { r in
                            NavigationLink(value: Route.film(r.film, "r-\(r.film.id)")) {
                                HStack(spacing: 14) {
                                    Poster(path: r.film.poster, title: r.film.title, width: 62, size: 185).modifier(ZoomSource(id: "r-\(r.film.id)"))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(r.film.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                        HStack(spacing: 2) { ForEach(1...5, id: \.self) { i in Image(systemName: r.stars >= Double(i) ? "star.fill" : r.stars >= Double(i) - 0.5 ? "star.leadinghalf.filled" : "star") } }.font(.caption).foregroundStyle(Color.or)
                                        if !r.comment.isEmpty { Text(r.comment).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                                    }
                                    Spacer(minLength: 0)
                                }.card()
                            }.buttonStyle(Press())
                        }
                    }.padding(.horizontal, 18)
                } else {
                    if films.isEmpty { empty(part == .likes ? "Touche le cœur d’un film pour le retrouver ici" : part == .later ? "Garde ici les films à voir" : part == .alertes ? "Touche la cloche d’un film ancien pour être prévenu de sa ressortie" : "Les films vus apparaîtront ici") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) { ForEach(films) { FilmTile(film: $0, source: "l-\(part.rawValue)-\($0.id)", width: nil).transition(.scale.combined(with: .opacity)) } }.padding(.horizontal, 18)
                }
            }.padding(.vertical, 12)
        }
        .background(Ambient(path: films.first?.back ?? films.first?.poster)).navigationTitle("Ma liste")
    }
    private func stat(_ v: String, _ t: String, _ i: String) -> some View {
        VStack(spacing: 4) { Image(systemName: i).foregroundStyle(Color.or); Text(v).font(.system(.title2, design: .rounded, weight: .heavy)).contentTransition(.numericText()); Text(t).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 14).glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
    private func empty(_ t: String) -> some View { ContentUnavailableView(t, systemImage: "film.stack").padding(.top, 40) }
}

// MARK: Recherche
struct SearchView: View {
    enum Scope: String, CaseIterable { case all = "Tout", films = "Films", series = "Séries", people = "Personnes", cinemas = "Cinémas" }
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @AppStorage("recherches") private var saved = ""
    @State private var q = ""
    @State private var scope = Scope.all
    @State private var films: [Film] = []
    @State private var people: [Person] = []
    @State private var salles: [Cinema] = []
    @State private var done = ""
    @State private var err: String?
    private let genres: [(String, String)] = [("cmy", "Comédie"), ("act", "Action"), ("drm", "Drame"), ("trl", "Thriller"), ("scf", "Science-fiction"), ("fml", "Famille"), ("ani", "Animation"), ("rma", "Romance"), ("fnt", "Fantastique"), ("hrr", "Horreur"), ("doc", "Documentaire"), ("war", "Guerre")]
    private var text: String { q.trimmingCharacters(in: .whitespaces) }
    private var recents: [String] { saved.components(separatedBy: "\n").filter { !$0.isEmpty } }
    private func keep() { guard text.count >= 2 else { return }; saved = ([text] + recents.filter { $0.lowercased() != text.lowercased() }).prefix(8).joined(separator: "\n") }
    var body: some View {
        ScrollView { if text.count < 2 { browse } else { results } }
            .background(Color.fond.ignoresSafeArea()).navigationTitle("Recherche").scrollEdgeEffectStyle(.hard, for: .top)
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $q, prompt: "Films, séries, acteurs, cinémas").autocorrectionDisabled()
            .onSubmit(of: .search) { keep() }
            .task(id: q) { await search() }
    }
    // Avant de taper : recherches récentes, tendances, catégories
    private var browse: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Récentes").font(.title3.bold()); Spacer(); Button("Effacer") { withAnimation { saved = "" } }.font(.subheadline) }.padding(.horizontal, 18)
                    ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(recents, id: \.self) { r in Chip(text: r, icon: "clock") { q = r } } }.padding(.horizontal, 18) }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            }
            if let t = Accueil.shared.rails["trend"], !t.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tendances en France").font(.title3.bold()).padding(.horizontal, 18)
                    ForEach(Array(t.prefix(5).enumerated()), id: \.element.id) { i, f in
                        NavigationLink(value: Route.film(f, "st-\(f.id)")) { FilmRow(film: f, rank: i + 1, source: "st-\(f.id)") }.buttonStyle(Press())
                        if i < 4 { Divider().padding(.leading, 112) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Parcourir").font(.title3.bold()).padding(.horizontal, 18)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(genres, id: \.0) { g in
                        NavigationLink(value: Route.grid(GridQuery(title: g.1, path: "jw", params: ["genres": g.0, "mix": "1", "type": "all"]))) {
                            Color.white.opacity(0.07).frame(height: 96)
                                .overlay { if let b = art[g.0] { Pic(url: TMDB.img(b, 300)) { Color.clear } } }
                                .overlay { LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom) }
                                .overlay(alignment: .bottomLeading) { Text(g.1).font(.headline).lineLimit(1).minimumScaleFactor(0.7).padding(12) }
                                .clipShape(.rect(cornerRadius: 18, style: .continuous)).contentShape(.rect)
                        }.buttonStyle(Press())
                    }
                }.padding(.horizontal, 18)
            }
        }.padding(.vertical, 12)
    }
    /// Un visuel différent par catégorie
    private var art: [String: String] {
        var used = Set<Int>(), out: [String: String] = [:]
        for g in genres { if let f = Accueil.shared.rails["g" + g.0]?.first(where: { $0.back != nil && !used.contains($0.id) }) { used.insert(f.id); out[g.0] = f.back } }
        return out
    }
    private var results: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(Scope.allCases, id: \.self) { s in Chip(text: s.rawValue, on: s == scope) { scope = s } } }.padding(.horizontal, 18) }.scrollIndicators(.hidden).scrollClipDisabled().padding(.bottom, 14)
            if let err { Note(text: err, icon: "wifi.exclamationmark") { Task { await search() } }.padding(.horizontal, 18) }
            else if done.isEmpty { ForEach(0..<6, id: \.self) { _ in HStack(spacing: 14) { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).frame(width: 56, height: 84); VStack(alignment: .leading, spacing: 8) { Capsule().fill(.white.opacity(0.1)).frame(width: 170, height: 13); Capsule().fill(.white.opacity(0.07)).frame(width: 90, height: 11) }; Spacer() }.padding(.horizontal, 18).padding(.vertical, 8) }.modifier(Shimmer()) }
            else if films.isEmpty && people.isEmpty && salles.isEmpty { ContentUnavailableView.search(text: text).padding(.top, 40) }
            if !done.isEmpty {
                if scope == .all || scope == .cinemas { section("Cinémas", salles.count); ForEach(scope == .all ? Array(salles.prefix(2)) : salles) { c in link(.cinema(c)) { CinemaLine(cinema: c).padding(.horizontal, 18).padding(.vertical, 6) } } }
                if (scope == .all || scope == .people) && !people.isEmpty {
                    section("Personnes", people.count)
                    if scope == .all { RailScroll(spacing: 14) { ForEach(people.prefix(8)) { p in link(.person(p)) { VStack(spacing: 6) { face(p, 72); Text(p.name).font(.caption).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center) }.frame(width: 84) } } }.padding(.bottom, 8) }
                    else { ForEach(people) { p in link(.person(p)) { HStack(spacing: 14) { face(p, 56); Text(p.name).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }.padding(.horizontal, 18).padding(.vertical, 6).contentShape(.rect) } } }
                }
                if scope == .all || scope == .films || scope == .series { let l = scope == .all ? films : films.filter { $0.tv == (scope == .series) }; section("Films et séries", l.count); ForEach(l) { f in link(.film(f, "s-\(f.id)")) { FilmRow(film: f, source: "s-\(f.id)") }; Divider().padding(.leading, 88) } }
            }
        }.padding(.vertical, 12)
    }
    @ViewBuilder private func section(_ t: String, _ n: Int) -> some View { if scope == .all && n > 0 { Text(t).font(.title3.bold()).padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8) } }
    private func link<L: View>(_ r: Route, @ViewBuilder _ l: () -> L) -> some View { NavigationLink(value: r) { l() }.buttonStyle(Press()).simultaneousGesture(TapGesture().onEnded { keep() }) }
    private func face(_ p: Person, _ s: CGFloat) -> some View { Pic(url: TMDB.img(p.photo, 185), loading: .white.opacity(0.07)) { Color.white.opacity(0.07) }.frame(width: s, height: s).clipShape(.circle) }
    private func search() async {
        let s = text
        guard s.count >= 2 else { films = []; people = []; salles = []; done = ""; err = nil; scope = .all; return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let near = pos.best
        async let c = Task.detached { Salles.search(s, near: near, max: 15) }.value
        async let p = TMDB.people(s)
        do {
            let r = try await TMDB.search(s), pp = (try? await p) ?? [], cc = await c
            await ImageBank.shared.prefetch(r.prefix(5).map { TMDB.img($0.poster, 185) })
            if Task.isCancelled { return }
            films = r; people = pp; salles = cc; done = s; err = nil
        } catch is CancellationError { return } catch { if !Task.isCancelled { err = error.localizedDescription } }
    }
}
struct FilmRow: View {
    let film: Film
    var rank: Int? = nil
    let source: String
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 14) {
            if let rank { Text("\(rank)").font(.system(.title2, design: .rounded, weight: .heavy)).foregroundStyle(.secondary).frame(width: 24) }
            Poster(path: film.poster, title: film.title, width: 56, size: 185).modifier(ZoomSource(id: source))
            VStack(alignment: .leading, spacing: 4) {
                Text(film.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Text([film.tv ? "Série" : nil, film.year, film.sur5.map { "★ " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                if Affiche.shared.reissue(film) { Ressortie() } else if Affiche.shared.has(film) { Label("Au cinéma", systemImage: "popcorn.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.or) }
            }
            Spacer(minLength: 0)
            if store.liked(film.id) { Image(systemName: "heart.fill").foregroundStyle(Color.rose) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 18).padding(.vertical, 8).contentShape(.rect)
    }
}

// MARK: Réglages
struct KeyField: View {
    @Environment(Store.self) private var store
    @State private var key = ""
    @State private var busy = false
    @State private var msg: String?
    var body: some View {
        SecureField("Clé d’API ou jeton TMDB", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button { Task { await check() } } label: { HStack { Text("Vérifier et enregistrer"); if busy { Spacer(); ProgressView() } } }.disabled(key.count < 20 || busy)
        if let msg { Text(msg).font(.footnote).foregroundStyle(Color.rose) }
        Link("Obtenir une clé gratuite sur TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
    }
    private func check() async {
        busy = true; msg = nil; defer { busy = false }
        do {
            _ = try await TMDB.get("/configuration", ttl: 0, key: key)
            Trousseau.write(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; store.hasKey = true; Haptic.ok(); store.say("Clé enregistrée")
        } catch { Haptic.warn(); msg = error.localizedDescription }
    }
}
struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var cinemas = false
    @State private var importing = false
    @State private var exportFile: BackupFile?
    @State private var exporting = false
    @State private var restore: Backup?
    @AppStorage("serveur") private var serveur = ""
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Films (TMDB)") {
                if store.hasKey { LabeledContent("Clé", value: "Enregistrée"); Button("Retirer la clé", role: .destructive) { Trousseau.write(nil); store.hasKey = false } } else { KeyField() }
            }
            Section("Cinémas") {
                Button("Gérer mes cinémas (\(store.cinemas.count))") { cinemas = true }
                NavigationLink("Alertes de ressortie") { ZoneView() }
            }
            Section { TextField("Adresse du serveur", text: $serveur).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).onSubmit { Task { await Registre.shared.load(fresh: true) } } } header: { Text("Base des ressorties") } footer: { Text(Registre.shared.ready ? "Connectée : \(Registre.shared.films.count) films suivis." : Registre.base == nil ? "Aucun serveur : les ressorties sont lues film par film." : "Base injoignable pour l’instant.") }
            Section { Toggle("Protéger les billets par Face ID", isOn: $store.s.lock) } header: { Text("Billets") } footer: { Text("Les billets restent uniquement sur cet iPhone, dans le dossier protégé de l’app.") }
            Section("Mes plateformes") { ServicePicker().padding(.vertical, 8) }
            Section { NavigationLink("Ordre et affichage des catégories") { RailOrder() } } header: { Text("Accueil") }
            Section {
                Button("Exporter une sauvegarde") { if let d = try? JSONEncoder().encode(Backup(saved: store.s, tickets: store.tickets)) { exportFile = BackupFile(data: d); exporting = true } }
                Button("Restaurer une sauvegarde") { importing = true }
            } header: { Text("Sauvegarde") } footer: { Text("Le fichier contient tes billets en clair : garde-le en lieu sûr.") }
            Section { Text("Ce produit utilise l’API TMDB mais n’est ni approuvé ni certifié par TMDB. Catalogue et streaming : JustWatch. Séances : AlloCiné. Ces deux sources sont non officielles, pour un usage personnel.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Réglages").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $cinemas) { CinemaPicker() }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: "MonCine") { _ in exportFile = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            guard let u = try? r.get() else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u), let b = try? JSONDecoder().decode(Backup.self, from: d) { restore = b } else { Haptic.warn(); store.say("Sauvegarde illisible") }
        }
        .confirmationDialog("Remplacer tes données par cette sauvegarde ?", isPresented: Binding { restore != nil } set: { if !$0 { restore = nil } }, titleVisibility: .visible, presenting: restore) { b in
            Button("Remplacer", role: .destructive) { store.s = b.saved; store.tickets = b.tickets; store.upcoming.forEach(Rappel.set); Haptic.ok() }
        }
    }
}
struct BackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration c: ReadConfiguration) throws { data = c.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct RailOrder: View {
    @Environment(Store.self) private var store
    var body: some View {
        let l = RailDef.all(store)
        List {
            ForEach(l) { r in
                Toggle(isOn: Binding { !store.s.hidden.contains(r.id) } set: { if $0 { store.s.hidden.remove(r.id) } else { store.s.hidden.insert(r.id) } }) { Label(r.title, systemImage: r.icon) }
            }.onMove { a, b in var ids = l.map(\.id); ids.move(fromOffsets: a, toOffset: b); store.s.order = ids; Haptic.tap() }
        }
        .environment(\.editMode, .constant(.active)).navigationTitle("Catégories")
        .toolbar { Button("Réinitialiser") { withAnimation { store.s.order = []; store.s.hidden = [] } } }
    }
}

// MARK: Premier lancement
struct Welcome: View {
    @Environment(Store.self) private var store
    @State private var step = 0
    @State private var cinemas = false
    @State private var pulse = false
    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [pulse ? 0.7 : 0.3, pulse ? 0.4 : 0.6], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                         colors: [Color(hex: 0x2A0B3A), Color(hex: 0x5C1138), Color(hex: 0x12082B), Color(hex: 0x8A2A1B), Color(hex: 0xD9781E), Color(hex: 0x3A0F45), .fond, Color(hex: 0x1B0A2B), .fond]).ignoresSafeArea()
                .onAppear { withAnimation(.easeInOut(duration: 5).repeatForever()) { pulse = true } }
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: ["popcorn.fill", "key.fill", "play.tv.fill", "mappin.and.ellipse"][step]).font(.system(size: 50)).contentTransition(.symbolEffect(.replace)).frame(width: 112, height: 112).glassEffect(.regular, in: .circle)
                    Text(["Mon Ciné", "Ta clé TMDB", "Tes plateformes", "Tes cinémas"][step]).font(.system(size: 38, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(["Tes films, tes séances, tes billets.", "Elle sert aux fiches des films et reste dans le trousseau de ton iPhone.", "Touche celles que tu as : « Regarder » ouvrira directement le film dans leur app.", "Pour voir directement les horaires près de chez toi."][step]).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 30)
                    if step == 1 { if store.hasKey { Label("Clé enregistrée", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } else { VStack(alignment: .leading, spacing: 16) { KeyField() }.card().padding(.horizontal, 24) } }
                    if step == 2 { ServicePicker().card().padding(.horizontal, 18) }
                    if step == 3 { Button("Choisir mes cinémas (\(store.cinemas.count))", systemImage: "plus") { cinemas = true }.buttonStyle(.glass).controlSize(.large) }
                }.padding(.top, 70).padding(.bottom, 30).frame(maxWidth: .infinity)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            Button { Haptic.ok(); withAnimation(.bouncy) { next() } } label: { Text(step == 3 || (store.s.onboarded && step == 2) ? "Commencer" : step == 1 && !store.hasKey ? "Plus tard" : "Continuer").font(.headline).frame(maxWidth: .infinity).frame(height: 38).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.white).padding(.horizontal, 24).padding(.bottom, 12)
        }
        .onAppear { if store.s.onboarded { step = 2 } }
        .sheet(isPresented: $cinemas) { CinemaPicker() }
    }
    private func next() {
        if step == 2 { store.s.picked = true; if store.s.onboarded { return } }
        if step < 3 { step += 1 } else { store.s.onboarded = true }
    }
}
