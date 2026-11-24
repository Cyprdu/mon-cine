import SwiftUI
import UniformTypeIdentifiers

// MARK: Ma liste
struct LibraryView: View {
    enum Part: String, CaseIterable { case likes = "J’aime", later = "À voir", rated = "Notés", seen = "Vus", agenda = "Séances" }
    @Environment(Store.self) private var store
    @State private var part = Part.likes
    private var films: [Film] {
        switch part { case .likes: store.likes; case .later: store.s.later; case .rated: store.rated.map(\.film); case .seen: store.s.seen; case .agenda: [] }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    stat("\(store.s.seen.count)", "films vus", "eye.fill"); stat("\(store.likes.count)", "coups de cœur", "heart.fill")
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
                    if films.isEmpty { empty(part == .likes ? "Touche le cœur d’un film pour le retrouver ici" : part == .later ? "Garde ici les films à voir" : "Les films vus apparaîtront ici") }
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
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @State private var q = ""
    @State private var films: [Film] = []
    @State private var err: String?
    @State private var busy = false
    private let genres: [(Int, String, String)] = [(28, "Action", "bolt.fill"), (12, "Aventure", "map.fill"), (16, "Animation", "paintpalette.fill"), (35, "Comédie", "theatermasks.fill"), (80, "Crime", "magnifyingglass"), (99, "Documentaire", "globe.europe.africa.fill"), (18, "Drame", "drop.fill"), (10751, "Famille", "figure.2.and.child.holdinghands"), (14, "Fantastique", "wand.and.stars"), (36, "Histoire", "building.columns.fill"), (27, "Horreur", "moon.fill"), (10402, "Musique", "music.note"), (9648, "Mystère", "questionmark.circle.fill"), (10749, "Romance", "heart.fill"), (878, "Science-fiction", "sparkles"), (53, "Thriller", "eye.fill"), (10752, "Guerre", "shield.fill"), (37, "Western", "sun.dust.fill")]
    var body: some View {
        ScrollView {
            if q.trimmingCharacters(in: .whitespaces).count < 2 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(genres, id: \.0) { g in
                        NavigationLink(value: Route.grid(GridQuery(title: g.1, path: "/discover/movie", params: ["with_genres": "\(g.0)", "sort_by": "popularity.desc", "include_adult": "false"]))) {
                            HStack { Text(g.1).font(.headline); Spacer(); Image(systemName: g.2).font(.title2).foregroundStyle(.white.opacity(0.8)) }.padding(16).frame(height: 84)
                                .background(LinearGradient(colors: [Color(hue: Double(g.0 % 37) / 37, saturation: 0.6, brightness: 0.6).opacity(0.55), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 24))
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                        }.buttonStyle(Press())
                    }
                }.padding(18)
            } else {
                let c = Salles.search(q, near: pos.best, max: 4)
                VStack(alignment: .leading, spacing: 16) {
                    if !c.isEmpty { RailHead(title: "Cinémas", icon: "popcorn.fill"); VStack(spacing: 6) { ForEach(c) { x in NavigationLink(value: Route.cinema(x)) { CinemaLine(cinema: x) }.buttonStyle(.plain) } }.card().padding(.horizontal, 18) }
                    RailHead(title: "Films", icon: "film.fill")
                    if let err { Note(text: err).padding(.horizontal, 18) } else if busy && films.isEmpty { GhostRail() } else if films.isEmpty { Text("Aucun film trouvé.").foregroundStyle(.secondary).padding(.horizontal, 18) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) { ForEach(films) { FilmTile(film: $0, source: "s-\($0.id)", width: nil) } }.padding(.horizontal, 18)
                }.padding(.vertical, 12)
            }
        }
        .background(Ambient(path: nil)).navigationTitle("Recherche")
        .searchable(text: $q, prompt: "Film, cinéma, ville").autocorrectionDisabled()
        .task(id: q) {
            let s = q.trimmingCharacters(in: .whitespaces)
            guard s.count >= 2 else { films = []; err = nil; return }
            busy = true
            try? await Task.sleep(for: .milliseconds(450))
            if Task.isCancelled { return }
            do { let r = try await TMDB.search(s); withAnimation { films = r; err = nil } } catch is CancellationError { return } catch { if Task.isCancelled { return }; err = error.localizedDescription }
            busy = false
        }
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
    @State private var providers: [Provider] = []
    @State private var cinemas = false
    @State private var importing = false
    @State private var exportFile: BackupFile?
    @State private var exporting = false
    @State private var restore: Backup?
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Films (TMDB)") {
                if store.hasKey { LabeledContent("Clé", value: "Enregistrée"); Button("Retirer la clé", role: .destructive) { Trousseau.write(nil); store.hasKey = false } } else { KeyField() }
            }
            Section("Cinémas") { Button("Gérer mes cinémas (\(store.cinemas.count))") { cinemas = true } }
            Section { Toggle("Protéger les billets par Face ID", isOn: $store.s.lock) } header: { Text("Billets") } footer: { Text("Les billets restent uniquement sur cet iPhone, dans le dossier protégé de l’app.") }
            Section("Mes abonnements") {
                ForEach(providers) { p in
                    let on = store.s.services.contains { $0.id == p.id }
                    Button { Haptic.pick(); if on { store.s.services.removeAll { $0.id == p.id } } else { store.s.services.append(p) } } label: {
                        HStack { Pic(url: TMDB.img(p.logo, 92)) { Color.white.opacity(0.1) }.frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 8)); Text(p.name).foregroundStyle(.white); Spacer(); Image(systemName: on ? "checkmark.circle.fill" : "circle").contentTransition(.symbolEffect(.replace)) }
                    }
                }
                if providers.isEmpty { Text("Disponible une fois la clé TMDB ajoutée.").foregroundStyle(.secondary) }
            }
            Section { NavigationLink("Ordre et affichage des catégories") { RailOrder() } } header: { Text("Accueil") }
            Section {
                Button("Exporter une sauvegarde") { if let d = try? JSONEncoder().encode(Backup(saved: store.s, tickets: store.tickets)) { exportFile = BackupFile(data: d); exporting = true } }
                Button("Restaurer une sauvegarde") { importing = true }
            } header: { Text("Sauvegarde") } footer: { Text("Le fichier contient tes billets en clair : garde-le en lieu sûr.") }
            Section { Text("Ce produit utilise l’API TMDB mais n’est ni approuvé ni certifié par TMDB. Streaming : JustWatch. Séances : AlloCiné (source non officielle, usage personnel).").font(.footnote).foregroundStyle(.secondary) }
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
        .task(id: store.hasKey) { guard store.hasKey, let l = try? await TMDB.providers() else { return }; providers = l; for i in store.s.services.indices { if let p = l.first(where: { $0.id == store.s.services[i].id }), store.s.services[i] != p { store.s.services[i] = p } } }
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
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: ["popcorn.fill", "key.fill", "mappin.and.ellipse"][step]).font(.system(size: 64)).contentTransition(.symbolEffect(.replace)).frame(width: 140, height: 140).glassEffect(.regular, in: .circle)
                Text(["Mon Ciné", "Ta clé TMDB", "Tes cinémas"][step]).font(.system(size: 40, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                Text(["Tes films, tes séances, tes billets.", "Elle donne accès aux films et reste dans le trousseau de ton iPhone.", "Pour voir directement les horaires près de chez toi."][step]).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 30)
                if step == 1 { if store.hasKey { Label("Clé enregistrée", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } else { VStack(alignment: .leading, spacing: 16) { KeyField() }.card().padding(.horizontal, 24) } }
                if step == 2 { Button("Choisir mes cinémas (\(store.cinemas.count))", systemImage: "plus") { cinemas = true }.buttonStyle(.glass).controlSize(.large) }
                Spacer()
                Button { Haptic.ok(); withAnimation(.bouncy) { if step < 2 { step += 1 } else { store.s.onboarded = true } } } label: { Text(step < 2 ? (step == 1 && !store.hasKey ? "Plus tard" : "Continuer") : "Commencer").font(.headline).frame(maxWidth: .infinity).frame(height: 38).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.white).padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $cinemas) { CinemaPicker() }
    }
}
