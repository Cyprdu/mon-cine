import SwiftUI

struct Playlist: Codable, Hashable, Identifiable { var id = UUID().uuidString; var nom: String; var films: [Film] = [] }
struct Tier: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var nom: String
    var rangs: [[Film]] = [[], [], [], [], [], []]
    var reste: [Film] = []
    static let lettres = ["S", "A", "B", "C", "D", "F"]
    static let teintes: [Color] = [.red, .orange, .yellow, .green, .cyan, .purple]
    var tous: [Film] { rangs.flatMap { $0 } + reste }
    mutating func place(_ f: Film, _ r: Int?) {
        for i in rangs.indices { rangs[i].removeAll { $0.id == f.id } }
        reste.removeAll { $0.id == f.id }
        if let r { rangs[r].append(f) } else { reste.append(f) }
    }
}
/// Ce qu’il faut pour regrouper et filtrer, lu une fois par film puis gardé
struct Meta: Codable, Hashable { var saga = "", sagaID = 0, genres: [String] = [], min = 0 }

@MainActor enum Metas {
    private static var actif = false
    /// Une fiche après l’autre, seulement pour les films encore inconnus
    static func lire(_ films: [Film], _ store: Store) async {
        guard !actif else { return }
        actif = true; defer { actif = false }
        var lot: [Int: Meta] = [:]
        for f in films where store.s.meta[f.id] == nil {
            if Task.isCancelled { break }
            guard let d = try? await TMDB.detail(f.id) else { continue }
            lot[f.id] = Meta(saga: d.saga?.nom ?? "", sagaID: d.saga?.id ?? 0, genres: d.genres, min: d.runtime ?? 0)
            if lot.count >= 12 { store.s.meta.merge(lot) { $1 }; lot = [:] }
        }
        if !lot.isEmpty { store.s.meta.merge(lot) { $1 } }
    }
}

// MARK: Filtres
struct Filtre: Equatable {
    enum Tri: String, CaseIterable { case ajout = "Ajout récent", titre = "Titre", sortie = "Date de sortie", note = "Note du public", mienne = "Ma note", duree = "Durée" }
    enum Groupe: String, CaseIterable { case aucun = "Sans regroupement", saga = "Par saga", genre = "Par genre", decennie = "Par décennie", type = "Films et séries" }
    var tri = Tri.ajout, groupe = Groupe.aucun, inverse = false
    var genre = "", decennie = 0, type = 0, vu = 0, note = 0.0, dispo = false
    var actif: Bool { !genre.isEmpty || decennie > 0 || type > 0 || vu > 0 || note > 0 }
    static func decade(_ f: Film) -> Int { (Int(f.year) ?? 0) / 10 * 10 }

    @MainActor func liste(_ films: [Film], _ s: Store) -> [Film] {
        var l = films.filter { f in
            (genre.isEmpty || s.s.meta[f.id]?.genres.contains(genre) == true) && (decennie == 0 || Self.decade(f) == decennie)
                && (type == 0 || f.tv == (type == 2)) && (vu == 0 || s.isSeen(f.id) == (vu == 1)) && (note == 0 || (f.note ?? 0) / 2 >= note)
        }
        switch tri {
        case .ajout: break
        case .titre: l.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .sortie: l.sort { $0.release > $1.release }
        case .note: l.sort { ($0.note ?? 0) > ($1.note ?? 0) }
        case .mienne: l.sort { (s.s.ratings[$0.id]?.stars ?? 0) > (s.s.ratings[$1.id]?.stars ?? 0) }
        case .duree: l.sort { (s.s.meta[$0.id]?.min ?? 0) < (s.s.meta[$1.id]?.min ?? 0) }
        }
        return inverse ? l.reversed() : l
    }
    @MainActor func groupes(_ films: [Film], _ s: Store) -> [(String, [Film])] {
        let l = liste(films, s)
        func par(_ k: (Film) -> [String], _ ordre: (String, String) -> Bool) -> [(String, [Film])] {
            var d: [String: [Film]] = [:]
            for f in l { for c in k(f) { d[c, default: []].append(f) } }
            return d.keys.sorted(by: ordre).map { ($0, d[$0]!) }
        }
        switch groupe {
        case .aucun: return l.isEmpty ? [] : [("", l)]
        case .saga:
            let g = par({ f in [s.s.meta[f.id]?.saga ?? ""] }, { $0.localizedStandardCompare($1) == .orderedAscending })
            let sagas = g.filter { !$0.0.isEmpty }.map { n, l in (n, tri == .ajout ? l.sorted { $0.release < $1.release } : l) }
            return sagas + g.filter { $0.0.isEmpty }.map { ("Hors saga", $0.1) }
        case .genre: return par({ f in s.s.meta[f.id].map { $0.genres.isEmpty ? ["Autre"] : $0.genres } ?? ["Autre"] }, { $0 < $1 })
        case .decennie: return par({ f in [Self.decade(f) > 0 ? "Années \(Self.decade(f))" : "Date inconnue"] }, { $0 > $1 })
        case .type: return par({ f in [f.tv ? "Séries" : "Films"] }, { $0 < $1 })
        }
    }
}
struct FiltreMenu: View {
    @Binding var f: Filtre
    let films: [Film]
    @Environment(Store.self) private var store
    var body: some View {
        let genres = Set(films.flatMap { store.s.meta[$0.id]?.genres ?? [] }).sorted(), dec = Set(films.map(Filtre.decade)).filter { $0 > 0 }.sorted(by: >)
        Menu {
            Picker("Trier", selection: $f.tri) { ForEach(Filtre.Tri.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Toggle("Inverser l’ordre", isOn: $f.inverse)
            Picker("Regrouper", selection: $f.groupe) { ForEach(Filtre.Groupe.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Divider()
            Picker("Type", selection: $f.type) { Text("Films et séries").tag(0); Text("Films").tag(1); Text("Séries").tag(2) }.pickerStyle(.menu)
            Picker("Genre", selection: $f.genre) { Text("Tous les genres").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
            Picker("Décennie", selection: $f.decennie) { Text("Toutes").tag(0); ForEach(dec, id: \.self) { Text("Années \(String($0))").tag($0) } }.pickerStyle(.menu)
            Picker("Déjà vu", selection: $f.vu) { Text("Peu importe").tag(0); Text("Vus").tag(1); Text("Pas encore vus").tag(2) }.pickerStyle(.menu)
            Picker("Note du public", selection: $f.note) { Text("Toutes").tag(0.0); ForEach([3.0, 3.5, 4.0], id: \.self) { Text("\($0.fr) et plus").tag($0) } }.pickerStyle(.menu)
            if f != Filtre() { Button("Tout remettre à zéro", systemImage: "arrow.counterclockwise", role: .destructive) { f = Filtre() } }
        } label: { Label("Trier et filtrer", systemImage: f.actif ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") }
    }
}
/// Affiches filtrées, regroupées au besoin
struct GrilleFilms: View {
    let films: [Film], source: String, filtre: Filtre
    @Environment(Store.self) private var store
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(filtre.groupes(films, store), id: \.0) { nom, l in
                VStack(alignment: .leading, spacing: 12) {
                    if !nom.isEmpty { HStack { Text(nom).font(.title3.bold()); Spacer(); Text("\(l.count)").foregroundStyle(.secondary).monospacedDigit() } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) { ForEach(l) { FilmTile(film: $0, source: "\(source)-\(nom)-\($0.id)", width: nil) } }
                }
            }
        }.padding(.horizontal, 18)
        .task(id: films.count) { await Metas.lire(films, store) }
        if !films.isEmpty && filtre.liste(films, store).isEmpty { ContentUnavailableView("Aucun film avec ces filtres", systemImage: "line.3.horizontal.decrease").padding(.top, 30) }
    }
}

// MARK: Ajout rapide
extension Store {
    func basculer(_ f: Film, playlist id: String) {
        guard let i = s.playlists.firstIndex(where: { $0.id == id }) else { return }
        if s.playlists[i].films.contains(where: { $0.id == f.id }) { s.playlists[i].films.removeAll { $0.id == f.id }; Haptic.tap() } else { s.playlists[i].films.append(f); Haptic.ok() }
    }
    func nouvelle(_ nom: String, _ films: [Film] = []) { s.playlists.insert(Playlist(nom: nom.isEmpty ? "Playlist \(s.playlists.count + 1)" : nom, films: films), at: 0); Haptic.ok() }
}
struct MenuPlaylists: View {
    let film: Film
    @Environment(Store.self) private var store
    var body: some View {
        Menu {
            ForEach(store.s.playlists) { p in
                let dedans = p.films.contains { $0.id == film.id }
                Button(p.nom, systemImage: dedans ? "checkmark" : "music.note.list") { store.basculer(film, playlist: p.id) }
            }
            if !store.s.tiers.isEmpty {
                Menu { ForEach(store.s.tiers) { t in Button(t.nom) { if let i = store.s.tiers.firstIndex(where: { $0.id == t.id }), !store.s.tiers[i].tous.contains(where: { $0.id == film.id }) { store.s.tiers[i].reste.append(film) }; Haptic.ok(); store.say("Ajouté à « \(t.nom) »") } } } label: { Label("Tier lists", systemImage: "square.stack.3d.up") }
            }
            Button("Nouvelle playlist", systemImage: "plus") { store.nouvelle("", [film]); store.say("Playlist créée dans Ma liste") }
        } label: { Label("Ajouter à une playlist", systemImage: "text.badge.plus") }
    }
}

// MARK: Playlists
struct PlaylistsView: View {
    @Environment(Store.self) private var store
    @State private var creer = false
    @State private var nom = ""
    var body: some View {
        VStack(spacing: 12) {
            Button { nom = ""; creer = true } label: { Label("Nouvelle playlist", systemImage: "plus").frame(maxWidth: .infinity).frame(height: 34) }.buttonStyle(.glass)
            ForEach(store.s.playlists) { p in
                NavigationLink(value: Route.playlist(p.id)) {
                    HStack(spacing: 14) {
                        Mosaique(films: p.films)
                        VStack(alignment: .leading, spacing: 4) { Text(p.nom).font(.headline).lineLimit(2).multilineTextAlignment(.leading); Text("\(p.films.count) titre\(p.films.count > 1 ? "s" : "")").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
                    }.card()
                }.buttonStyle(Press())
                .contextMenu { Button("Supprimer", systemImage: "trash", role: .destructive) { withAnimation { store.s.playlists.removeAll { $0.id == p.id } } } }
            }
            if store.s.playlists.isEmpty { ContentUnavailableView("Aucune playlist", systemImage: "music.note.list", description: Text("Crée-en une, puis garde le doigt sur une affiche pour l’y ajouter.")).padding(.top, 20) }
        }.padding(.horizontal, 18)
        .alert("Nouvelle playlist", isPresented: $creer) { TextField("Nom", text: $nom); Button("Annuler", role: .cancel) {}; Button("Créer") { withAnimation { store.nouvelle(nom.trimmingCharacters(in: .whitespaces)) } } }
    }
}
struct Mosaique: View {
    let films: [Film]
    var body: some View {
        HStack(spacing: -26) {
            ForEach(Array(films.prefix(3).enumerated()), id: \.element.id) { i, f in Poster(path: f.poster, title: f.title, width: 50, size: 185).zIndex(Double(3 - i)) }
            if films.isEmpty { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).frame(width: 50, height: 75).overlay { Image(systemName: "film").foregroundStyle(.secondary) } }
        }
    }
}
struct PlaylistView: View {
    let id: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var filtre = Filtre()
    @State private var ajout = false
    @State private var ordre = false
    @State private var renommer = false
    @State private var nom = ""
    private var p: Playlist? { store.s.playlists.first { $0.id == id } }
    private var i: Int? { store.s.playlists.firstIndex { $0.id == id } }
    var body: some View {
        ScrollView {
            if let p {
                if p.films.isEmpty { ContentUnavailableView("Playlist vide", systemImage: "music.note.list", description: Text("Ajoute des titres avec le bouton +")).padding(.top, 40) }
                GrilleFilms(films: p.films, source: "pl-\(id)", filtre: filtre).padding(.vertical, 12)
            }
        }
        .background(Ambient(path: p?.films.first?.back ?? p?.films.first?.poster)).navigationTitle(p?.nom ?? "").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { FiltreMenu(f: $filtre, films: p?.films ?? []) }
            ToolbarItem(placement: .topBarTrailing) { Button("Ajouter", systemImage: "plus") { ajout = true } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Modifier l’ordre", systemImage: "arrow.up.arrow.down") { ordre = true }
                    Button("Renommer", systemImage: "pencil") { nom = p?.nom ?? ""; renommer = true }
                    if let p { Button("En faire une tier list", systemImage: "square.stack.3d.up") { store.s.tiers.insert(Tier(nom: p.nom, reste: p.films), at: 0); Haptic.ok(); store.say("Tier list créée dans Ma liste") } }
                    Button("Supprimer", systemImage: "trash", role: .destructive) { dismiss(); store.s.playlists.removeAll { $0.id == id } }
                } label: { Label("Plus", systemImage: "ellipsis") }
            }
        }
        .alert("Renommer", isPresented: $renommer) { TextField("Nom", text: $nom); Button("Annuler", role: .cancel) {}; Button("Enregistrer") { if let i, !nom.isEmpty { store.s.playlists[i].nom = nom } } }
        .sheet(isPresented: $ajout) { Choisir(titre: p?.nom ?? "", deja: Set((p?.films ?? []).map(\.id))) { f in store.basculer(f, playlist: id) } }
        .sheet(isPresented: $ordre) {
            NavigationStack {
                List {
                    ForEach(p?.films ?? []) { f in HStack { Poster(path: f.poster, title: f.title, width: 36, size: 185); Text(f.title).lineLimit(1) } }
                        .onMove { a, b in if let i { store.s.playlists[i].films.move(fromOffsets: a, toOffset: b) } }
                        .onDelete { a in if let i { store.s.playlists[i].films.remove(atOffsets: a) } }
                }.environment(\.editMode, .constant(.active)).navigationTitle("Ordre").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("OK") { ordre = false } }
            }
        }
    }
}
/// Choix de titres : recherche, ou ceux déjà dans les listes
struct Choisir: View {
    let titre: String, deja: Set<Int>
    let bascule: (Film) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var trouves: [Film] = []
    @State private var mis: Set<Int> = []
    @State private var source = 0
    private var liste: [Film] { q.count >= 2 ? trouves : [store.likes, store.s.later, store.rated.map(\.film), store.s.seen][source] }
    var body: some View {
        NavigationStack {
            List {
                if q.count < 2 { Picker("Depuis", selection: $source) { Text("J’aime").tag(0); Text("À voir").tag(1); Text("Notés").tag(2); Text("Vus").tag(3) }.pickerStyle(.segmented).listRowBackground(Color.clear) }
                ForEach(liste) { f in
                    Button { Haptic.pick(); if !mis.insert(f.id).inserted { mis.remove(f.id) }; bascule(f) } label: {
                        HStack(spacing: 12) {
                            Poster(path: f.poster, title: f.title, width: 42, size: 185)
                            VStack(alignment: .leading) { Text(f.title).font(.headline).lineLimit(2); Text((f.tv ? "Série · " : "") + f.year).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Image(systemName: mis.contains(f.id) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(mis.contains(f.id) ? Color.or : .secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Films et séries")
            .navigationTitle("Ajouter").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .task(id: q) { guard q.count >= 2 else { return }; try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled, let l = try? await TMDB.search(q) { trouves = l } }
            .onAppear { mis = deja }
        }
    }
}

// MARK: Tier lists
struct TiersView: View {
    @Environment(Store.self) private var store
    @State private var creer = false
    @State private var nom = ""
    var body: some View {
        VStack(spacing: 12) {
            Menu {
                Button("Vide") { nouveau([]) }
                Button("Avec mes coups de cœur") { nouveau(store.likes) }
                Button("Avec mes films vus") { nouveau(store.s.seen) }
                Button("Avec mes films notés") { nouveau(store.rated.map(\.film)) }
                let sagas = Dictionary(grouping: (store.likes + store.s.seen + store.s.later).filter { !(store.s.meta[$0.id]?.saga ?? "").isEmpty }, by: { store.s.meta[$0.id]!.sagaID })
                if !sagas.isEmpty { Menu("Une saga") { ForEach(sagas.keys.sorted(), id: \.self) { k in if let n = store.s.meta[sagas[k]![0].id]?.saga { Button(n) { Task { let l = (try? await TMDB.saga(k)) ?? sagas[k]!; nouveau(l, n) } } } } } }
            } label: { Label("Nouvelle tier list", systemImage: "plus").frame(maxWidth: .infinity).frame(height: 34) }.buttonStyle(.glass)
            ForEach(store.s.tiers) { t in
                NavigationLink(value: Route.tier(t.id)) {
                    HStack(spacing: 14) {
                        Mosaique(films: t.tous)
                        VStack(alignment: .leading, spacing: 4) { Text(t.nom).font(.headline).lineLimit(2).multilineTextAlignment(.leading); Text("\(t.tous.count - t.reste.count) classés sur \(t.tous.count)").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
                    }.card()
                }.buttonStyle(Press())
                .contextMenu { Button("Supprimer", systemImage: "trash", role: .destructive) { withAnimation { store.s.tiers.removeAll { $0.id == t.id } } } }
            }
            if store.s.tiers.isEmpty { ContentUnavailableView("Aucune tier list", systemImage: "square.stack.3d.up", description: Text("Classe tes films de S à F en les faisant glisser.")).padding(.top, 20) }
        }.padding(.horizontal, 18)
    }
    private func nouveau(_ l: [Film], _ n: String? = nil) { withAnimation { store.s.tiers.insert(Tier(nom: n ?? "Tier list \(store.s.tiers.count + 1)", reste: l), at: 0) }; Haptic.ok() }
}
struct TierView: View {
    let id: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var ajout = false
    @State private var renommer = false
    @State private var nom = ""
    @State private var vise: Int?
    @State private var choisi: Film?
    private var i: Int? { store.s.tiers.firstIndex { $0.id == id } }
    private var t: Tier? { i.map { store.s.tiers[$0] } }
    var body: some View {
        ScrollView {
            if let t {
                VStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { r in
                        HStack(spacing: 0) {
                            Text(Tier.lettres[r]).font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(.black).frame(width: 54).frame(maxHeight: .infinity).background(Tier.teintes[r])
                            ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(t.rangs[r]) { vignette($0) } }.padding(6) }.scrollIndicators(.hidden).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 92).background(.white.opacity(vise == r ? 0.18 : 0.06)).clipShape(.rect(cornerRadius: 14))
                        .dropDestination(for: String.self) { l, _ in pose(l, r) } isTargeted: { vise = $0 ? r : vise == r ? nil : vise }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("À classer (\(t.reste.count))").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], spacing: 8) { ForEach(t.reste) { vignette($0) } }.frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    }.padding(14).background(.white.opacity(vise == 9 ? 0.18 : 0.06), in: .rect(cornerRadius: 18)).padding(.top, 12)
                    .dropDestination(for: String.self) { l, _ in pose(l, nil) } isTargeted: { vise = $0 ? 9 : vise == 9 ? nil : vise }
                    Text("Fais glisser une affiche, ou touche-la pour choisir son rang.").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
        }
        .background(Color.fond.ignoresSafeArea()).navigationTitle(t?.nom ?? "").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Ajouter", systemImage: "plus") { ajout = true } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Classer d’après mes notes", systemImage: "star") { notes() }
                    if let t { ShareLink(item: t.nom + "\n" + (0..<6).map { r in Tier.lettres[r] + " : " + t.rangs[r].map(\.title).joined(separator: ", ") }.joined(separator: "\n")) { Label("Partager", systemImage: "square.and.arrow.up") } }
                    Button("Renommer", systemImage: "pencil") { nom = t?.nom ?? ""; renommer = true }
                    Button("Tout remettre à classer", systemImage: "arrow.counterclockwise") { if let i { withAnimation { store.s.tiers[i].reste = store.s.tiers[i].tous; store.s.tiers[i].rangs = Array(repeating: [], count: 6) } } }
                    Button("Supprimer", systemImage: "trash", role: .destructive) { dismiss(); store.s.tiers.removeAll { $0.id == id } }
                } label: { Label("Plus", systemImage: "ellipsis") }
            }
        }
        .confirmationDialog(choisi?.title ?? "", isPresented: Binding { choisi != nil } set: { if !$0 { choisi = nil } }, titleVisibility: .visible, presenting: choisi) { f in
            ForEach(0..<6, id: \.self) { r in Button("Rang \(Tier.lettres[r])") { place(f, r) } }
            Button("À classer") { place(f, nil) }
            Button("Retirer", role: .destructive) { if let i { withAnimation { retirer(f, i) } } }
        }
        .alert("Renommer", isPresented: $renommer) { TextField("Nom", text: $nom); Button("Annuler", role: .cancel) {}; Button("Enregistrer") { if let i, !nom.isEmpty { store.s.tiers[i].nom = nom } } }
        .sheet(isPresented: $ajout) {
            Choisir(titre: t?.nom ?? "", deja: Set((t?.tous ?? []).map(\.id))) { f in
                guard let i else { return }
                if store.s.tiers[i].tous.contains(where: { $0.id == f.id }) { retirer(f, i) } else { store.s.tiers[i].reste.append(f) }
            }
        }
    }
    private func vignette(_ f: Film) -> some View {
        Button { Haptic.tap(); choisi = f } label: { Poster(path: f.poster, title: f.title, width: 54, size: 185) }.buttonStyle(.plain)
            .draggable(String(f.id)) { Poster(path: f.poster, title: f.title, width: 70, size: 185) }.accessibilityLabel(f.title)
    }
    private func retirer(_ f: Film, _ i: Int) { for r in 0..<6 { store.s.tiers[i].rangs[r].removeAll { $0.id == f.id } }; store.s.tiers[i].reste.removeAll { $0.id == f.id } }
    private func place(_ f: Film, _ r: Int?) { guard let i else { return }; Haptic.pick(); withAnimation(.snappy) { store.s.tiers[i].place(f, r) } }
    private func pose(_ l: [String], _ r: Int?) -> Bool {
        guard let k = l.first.flatMap({ Int($0) }), let f = t?.tous.first(where: { $0.id == k }) else { return false }
        place(f, r); return true
    }
    private func notes() {
        guard let i else { return }
        Haptic.ok()
        withAnimation(.snappy) { for f in store.s.tiers[i].reste { if let n = store.s.ratings[f.id]?.stars { store.s.tiers[i].place(f, n >= 5 ? 0 : n >= 4 ? 1 : n >= 3 ? 2 : n >= 2 ? 3 : n >= 1 ? 4 : 5) } } }
    }
}
