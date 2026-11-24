import SwiftUI
import EventKitUI
import MapKit

// MARK: Bandeau des jours et filtres
struct DayStrip: View {
    @Binding var day: String
    var body: some View {
        let days = (0..<14).map { Jour.shift(Jour.cine(.now), $0) }, list = days.contains(day) ? days : days + [day]
        ScrollViewReader { p in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(list, id: \.self) { d in
                            let on = d == day, date = Jour.parse(d, "yyyy-MM-dd") ?? .now
                            Button { Haptic.pick(); withAnimation(.snappy) { day = d } } label: {
                                VStack(spacing: 1) {
                                    Text(d == days[0] ? "Auj." : Jour.fmt(date, "EEE").replacingOccurrences(of: ".", with: "").capitalized).font(.caption2.weight(.semibold))
                                    Text(Jour.fmt(date, "d")).font(.title3.weight(.bold)).monospacedDigit()
                                    Text(Jour.fmt(date, "MMM").replacingOccurrences(of: ".", with: "")).font(.caption2)
                                }.frame(width: 56, height: 68).foregroundStyle(on ? .black : .white)
                            }.buttonStyle(.plain).glassEffect(on ? .regular.tint(.or).interactive() : .regular.interactive(), in: .rect(cornerRadius: 20)).id(d).accessibilityLabel(Jour.jolie(d, long: true)).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }.padding(.horizontal, 18)
            }.scrollIndicators(.hidden).scrollClipDisabled()
            .onChange(of: day) { withAnimation { p.scrollTo(day, anchor: .center) } }
        }
    }
}
struct Slot: View {
    let seance: Seance, saved: Bool
    let action: () -> Void
    var body: some View {
        Button { Haptic.tap(); action() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Jour.heure(seance.start)).font(.headline).monospacedDigit()
                if let e = seance.end { Text("fin " + Jour.heure(e)).font(.caption2).foregroundStyle(.secondary) }
                Text(([seance.label, seance.version] + seance.formats).filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2.weight(.semibold)).foregroundStyle(saved ? .white : Color.or).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                .background(saved ? Color.or.opacity(0.35) : .white.opacity(0.08), in: .rect(cornerRadius: 15))
        }.buttonStyle(Press())
    }
}
struct Slots: View {
    let seances: [Seance], cinema: Cinema, title: String, poster: String?, filmID: Int?, acID: Int
    @Environment(Store.self) private var store
    @State private var open: AgendaItem?
    private func item(_ s: Seance) -> AgendaItem {
        let id = "cine-\(acID)-\(cinema.id)-\(Jour.fmt(s.start, "yyyyMMddHHmm"))-\(s.version)"
        return store.inAgenda(id) ?? AgendaItem(id: id, filmID: filmID, title: title, poster: poster, cinema: cinema, start: s.start, end: s.end ?? s.start.addingTimeInterval(7200), version: s.version, formats: s.formats, url: s.url)
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(seances) { s in let a = item(s); Slot(seance: s, saved: store.inAgenda(a.id) != nil) { open = a } }
        }
        .sheet(item: $open) { SeanceSheet(item: $0) }
    }
}
func garde(_ l: [Seance], _ ver: String) -> [Seance] { l.filter { $0.start > .now && (ver.isEmpty || $0.version.hasPrefix(ver)) } }

// MARK: Séances d’un film
struct FilmSeances: View {
    let film: Film, original: String
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @State private var day = Jour.cine(.now)
    @State private var ver = ""
    @State private var mine = true
    @State private var wave = 8
    @State private var got: [String: Programme] = [:]
    @State private var err: String?
    @State private var busy = false
    @State private var jumping = false
    @State private var retry = 0
    @State private var add = false
    private var useMine: Bool { mine && !store.cinemas.isEmpty }
    private var salles: [Cinema] {
        if useMine { return Array(store.cinemas.prefix(8)) }
        let fav = store.cinemas, near = Salles.search("", near: pos.best, max: wave + fav.count)
        return Array((fav + near.filter { c in !fav.contains { $0.id == c.id } }).prefix(max(wave, fav.count)))
    }
    private func films(_ p: Programme?) -> [ACFilm] { (p?.films ?? []).filter { Match.same(title: film.title, original: original, year: Int(film.year), $0) } }
    var body: some View {
        let list = salles
        let rows = list.flatMap { c in films(got[c.id]).map { (c, $0, garde($0.seances, ver)) } }.filter { !$0.2.isEmpty }
        let any = list.contains { c in films(got[c.id]).contains { !garde($0.seances, "").isEmpty } }
        VStack(alignment: .leading, spacing: 14) {
            DayStrip(day: $day)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if !store.cinemas.isEmpty { Chip(text: "Mes cinémas", on: mine) { mine = true }; Chip(text: "Autour", icon: "location.fill", on: !mine) { mine = false; pos.ask() } }
                    Chip(text: "VF", on: ver == "VF") { ver = ver == "VF" ? "" : "VF" }
                    Chip(text: "VO", on: ver == "VO") { ver = ver == "VO" ? "" : "VO" }
                    Chip(text: "Cinémas", icon: "plus") { add = true }
                }.padding(.horizontal, 18)
            }.scrollIndicators(.hidden).scrollClipDisabled()
            ForEach(rows, id: \.1) { c, f, s in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: Route.cinema(c)) { CinemaLine(cinema: c) }.buttonStyle(.plain)
                    Slots(seances: s, cinema: c, title: film.title, poster: film.poster ?? f.poster, filmID: film.id, acID: f.movie)
                }.card().padding(.horizontal, 18).transition(.blurReplace)
            }
            VStack(spacing: 10) {
                if busy { HStack { ProgressView(); Text("Lecture des programmes : \(list.filter { got[$0.id] != nil }.count) sur \(list.count)").font(.subheadline).foregroundStyle(.secondary).contentTransition(.numericText()) }.frame(maxWidth: .infinity) }
                if let err { Note(text: err, icon: "exclamationmark.triangle") { retry += 1 } }
                if !busy && err == nil && rows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text(any ? "Aucune séance dans cette version" : "Aucune séance \(useMine ? "dans tes cinémas" : "dans ces cinémas") ce jour-là").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        if any { Button("Retirer le filtre") { ver = "" }.buttonStyle(.glass) } else {
                            Button { Task { await jump() } } label: { if jumping { ProgressView() } else { Text("Voir le prochain jour de séance") } }.buttonStyle(.glass).disabled(jumping)
                        }
                    }.frame(maxWidth: .infinity).card()
                }
                if !useMine && !busy { Button("Chercher dans 8 cinémas de plus", systemImage: "plus") { wave += 8 }.buttonStyle(.glass).frame(maxWidth: .infinity) }
                if list.contains(where: { got[$0.id]?.stale == true }) { Text("Certains horaires ont été enregistrés plus tôt : mise à jour indisponible.").font(.caption).foregroundStyle(.secondary) }
                if list.contains(where: { got[$0.id]?.partial == true }) { Text("Liste incomplète : certaines séances n’ont pas pu être lues.").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18)
        }
        .task(id: "\(day)|\(useMine)|\(wave)|\(retry)|\(store.cinemas.count)|\(pos.here?.latitude ?? 0)") { await load() }
        .onChange(of: day) { got = [:] }
        .sheet(isPresented: $add) { CinemaPicker() }
    }
    private func load() async {
        busy = true; err = nil
        defer { busy = false }
        let d = day
        for c in salles where got[c.id] == nil {
            do {
                let p = try await AlloCine.shared.programme(c.id, d)
                if Task.isCancelled || d != day { return }
                withAnimation(.snappy) { got[c.id] = p }
            } catch is CancellationError { return } catch { if Task.isCancelled { return }; err = error.localizedDescription; if (error as? Oops)?.quota == true { return } }
        }
    }
    /// Jour après jour, en sautant les journées vides annoncées par AlloCiné ; une semaine par appui
    private func jump() async {
        jumping = true; defer { jumping = false }
        let l = Array(salles.prefix(3))
        var skip: [String: String] = [:]
        for i in 1...7 {
            let d = Jour.shift(day, i)
            for c in l where d >= skip[c.id] ?? "" {
                do {
                    let p = try await AlloCine.shared.programme(c.id, d)
                    if films(p).contains(where: { !garde($0.seances, "").isEmpty }) { Haptic.ok(); withAnimation(.snappy) { day = d }; return }
                    if p.films.isEmpty, let n = p.next { skip[c.id] = n }
                } catch { store.say(error.localizedDescription); return }
            }
        }
        Haptic.warn(); store.say("Rien trouvé dans les 7 jours suivants")
    }
}
struct CinemaLine: View {
    let cinema: Cinema
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cinema.name).font(.headline).multilineTextAlignment(.leading)
                let k = Salles.km(cinema, pos.best)
                Text([pos.here != nil && k < 80 ? k.fr + " km" : nil, cinema.address].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { store.toggle(cinema) } label: { Image(systemName: store.isCinema(cinema.id) ? "heart.fill" : "heart").foregroundStyle(store.isCinema(cinema.id) ? Color.rose : .secondary).contentTransition(.symbolEffect(.replace)).frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(store.isCinema(cinema.id) ? "Retirer de mes cinémas" : "Ajouter à mes cinémas")
        }
    }
}

// MARK: Programme d’un cinéma
struct Programmation: View {
    let cinema: Cinema
    @Environment(Store.self) private var store
    @State private var day = Jour.cine(.now)
    @State private var ver = ""
    @State private var p: Programme?
    @State private var err: String?
    @State private var retry = 0
    var body: some View {
        let rows = (p?.films ?? []).map { ($0, garde($0.seances, ver)) }.filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 14) {
            DayStrip(day: $day)
            HStack(spacing: 8) { Chip(text: "VF", on: ver == "VF") { ver = ver == "VF" ? "" : "VF" }; Chip(text: "VO", on: ver == "VO") { ver = ver == "VO" ? "" : "VO" }; Spacer() }.padding(.horizontal, 18)
            if let err { Note(text: err, icon: "exclamationmark.triangle") { retry += 1 }.padding(.horizontal, 18) }
            else if p == nil { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.07)).frame(height: 150).modifier(Shimmer()) }.padding(.horizontal, 18) }
            else if rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Plus aucune séance ce jour-là").font(.headline)
                    Button("Jour suivant") { day = (p?.next).flatMap { $0 > day ? $0 : nil } ?? Jour.shift(day, 1) }.buttonStyle(.glass)
                }.frame(maxWidth: .infinity).card().padding(.horizontal, 18)
            }
            ForEach(rows, id: \.0.id) { f, s in
                HStack(alignment: .top, spacing: 14) {
                    ACTile(film: f, caption: "", width: 86, badge: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.title).font(.headline)
                        if f.reissue { Ressortie() }
                        Text([f.runtime.map(Jour.duree), f.genres.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if !f.director.isEmpty { Text("De " + f.director).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Slots(seances: s, cinema: cinema, title: f.title, poster: f.poster, filmID: nil, acID: f.movie).padding(.top, 6)
                    }
                }.card().padding(.horizontal, 18).scrollTransition { v, x in v.opacity(x.isIdentity ? 1 : 0.5).scaleEffect(x.isIdentity ? 1 : 0.96) }
            }
            if let p { Text("Horaires vérifiés \(p.at.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR"))))" + (p.stale ? " · mise à jour indisponible" : "") + (p.partial ? " · liste incomplète" : "")).font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18) }
        }
        .task(id: "\(cinema.id)|\(day)|\(retry)") {
            p = nil; err = nil
            do { let x = try await AlloCine.shared.programme(cinema.id, day, fresh: retry > 0); withAnimation(.snappy) { p = x } } catch is CancellationError {} catch { if !Task.isCancelled { err = error.localizedDescription } }
        }
    }
}
struct CinemaView: View {
    let cinema: Cinema
    @Environment(Store.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    CinemaLine(cinema: cinema)
                    Button("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond.fill") { Plan.open(cinema) }.buttonStyle(.glass)
                }.card().padding(.horizontal, 18)
                Programmation(cinema: cinema)
            }.padding(.bottom, 40)
        }.background(Ambient(path: nil)).navigationTitle(cinema.name).navigationBarTitleDisplayMode(.inline)
    }
}
enum Plan {
    static func open(_ c: Cinema) {
        let i = MKMapItem(location: CLLocation(latitude: c.lat, longitude: c.lon), address: nil)
        i.name = c.name
        i.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

// MARK: Onglet Séances
struct CineTab: View {
    @Environment(Store.self) private var store
    @State private var sel: String?
    @State private var add = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.upcoming.isEmpty { RailHead(title: "Mes prochaines séances", icon: "calendar"); RailScroll { ForEach(store.upcoming) { AgendaCard(item: $0).frame(width: 320) } } }
                if let c = store.cinemas.first(where: { $0.id == sel }) ?? store.cinemas.first {
                    ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(store.cinemas) { x in Chip(text: x.name, on: x.id == c.id) { sel = x.id } } }.padding(.horizontal, 18) }.scrollIndicators(.hidden).scrollClipDisabled()
                    Programmation(cinema: c).id(c.id).transition(.blurReplace)
                } else {
                    ContentUnavailableView { Label("Choisis tes cinémas", systemImage: "popcorn") } description: { Text("Leur programme s’affichera ici, avec les horaires et la réservation.") } actions: { Button("Ajouter un cinéma") { add = true }.buttonStyle(.glassProminent) }
                }
            }.padding(.vertical, 12)
        }
        .background(Ambient(path: nil)).navigationTitle("Séances")
        .toolbar { Button("Ajouter un cinéma", systemImage: "plus") { add = true } }
        .sheet(isPresented: $add) { CinemaPicker() }
    }
}
struct CinemaPicker: View {
    @Environment(Store.self) private var store
    @Environment(Position.self) private var pos
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    var body: some View {
        NavigationStack {
            List {
                if pos.here == nil { Button { pos.ask() } label: { Label("Trier depuis ma position", systemImage: "location.fill") } }
                if q.isEmpty && !store.cinemas.isEmpty { Section("Mes cinémas") { ForEach(store.cinemas) { CinemaLine(cinema: $0) }.onMove { a, b in store.s.cinemas.move(fromOffsets: a, toOffset: b) } } }
                Section(q.isEmpty ? "À proximité" : "Résultats") { ForEach(Salles.search(q, near: pos.best, max: 40)) { CinemaLine(cinema: $0) } }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom, ville, code postal")
            .navigationTitle("Cinémas").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK", systemImage: "checkmark") { dismiss() } } }
        }
    }
}

// MARK: Séance enregistrée
struct AgendaCard: View {
    let item: AgendaItem
    @Environment(Store.self) private var store
    @State private var open = false
    var body: some View {
        Button { Haptic.tap(); open = true } label: {
            HStack(spacing: 14) {
                Poster(path: item.poster, title: item.title, width: 62, size: 185)
                VStack(alignment: .leading, spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 60)) { t in
                        Text(item.start > t.date ? "\(Jour.jolie(Jour.cine(item.start))) · \(Jour.heure(item.start))" : "En cours").font(.caption.weight(.bold)).foregroundStyle(Color.or)
                    }
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text([item.cinema.name, item.version].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !item.tickets.isEmpty { Label("\(item.tickets.count) billet\(item.tickets.count > 1 ? "s" : "")", systemImage: "qrcode").font(.caption2.weight(.semibold)) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }.card()
        }.buttonStyle(Press())
        .sheet(isPresented: $open) { SeanceSheet(item: item) }
    }
}

struct SeanceSheet: View {
    @State var item: AgendaItem
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var calendar = false
    @State private var show: Ticket?
    @State private var pickTickets = false
    @State private var booked = false
    @State private var left = false
    @State private var drop = false
    private var saved: Bool { store.inAgenda(item.id) != nil }
    private var mine: [Ticket] { item.tickets.compactMap { id in store.tickets.first { $0.id == id } } }
    private var clash: [AgendaItem] { store.s.agenda.filter { $0.id != item.id && $0.start < item.end && $0.end > item.start } }
    private var book: URL? {
        if let u = item.url, let x = URL(string: u) { return x }
        return item.cinema.isPathe ? URL(string: "https://www.pathe.fr/cinemas") : nil
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        Poster(path: item.poster, title: item.title, width: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.title2.bold())
                            Text(([item.version] + item.formats).filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.or)
                            if saved { Label("Dans mes séances", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).transition(.scale) }
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        let night = Jour.iso(item.start) != Jour.cine(item.start)
                        info("calendar", Jour.jolie(Jour.iso(item.start), long: true), night ? "Séance de nuit, soirée du \(Jour.jolie(Jour.cine(item.start)).lowercased())" : nil)
                        info("clock", "\(Jour.heure(item.start)) – \(Jour.heure(item.end))", "Fin estimée, hors bandes-annonces")
                        Button { Plan.open(item.cinema) } label: { info("mappin.and.ellipse", item.cinema.name, item.cinema.address) }.buttonStyle(.plain)
                        ForEach(clash) { c in info("exclamationmark.triangle.fill", "Chevauche « \(c.title) »", "\(Jour.heure(c.start)) – \(Jour.heure(c.end))") }
                    }.card()
                    ForEach(mine) { t in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { VStack(alignment: .leading) { Text(t.title).font(.headline); Text(t.number).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled); if !t.pin.isEmpty { Text("PIN \(t.pin)").font(.caption).foregroundStyle(.secondary) } }; Spacer(); Image(systemName: "qrcode").font(.title) }
                            HStack { Button("QR", systemImage: "qrcode") { show = t }; Button("Copier", systemImage: "doc.on.doc") { copy([t]) }; Spacer(); Button("Dissocier", systemImage: "xmark") { item.tickets.removeAll { $0 == t.id }; if saved { store.put(item) }; Haptic.tap() }.labelStyle(.iconOnly) }.buttonStyle(.glass)
                        }.card()
                    }
                    if booked && !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Réservation terminée ?", systemImage: "ticket.fill").font(.headline)
                            Text("Si les codes ont été acceptés, retire les places utilisées. Sinon elles restent disponibles.").font(.subheadline).foregroundStyle(.secondary)
                            Button { for t in mine { store.useOne(t) }; item.tickets = []; store.put(item); booked = false } label: { Text("Oui, places utilisées").frame(maxWidth: .infinity) }.buttonStyle(.glassProminent)
                        }.card().transition(.blurReplace)
                    }
                    if !item.past {
                        if !store.usable(for: item).isEmpty { Button { pickTickets = true } label: { Label(mine.isEmpty ? "Utiliser une place prépayée" : "Ajouter une autre place", systemImage: "wallet.pass.fill").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass) }
                        if let book {
                            Button {
                                if !mine.isEmpty { copy(mine); left = true }
                                if !saved { store.put(item) }
                                openURL(book)
                            } label: { Label(mine.isEmpty ? "Réserver" : "Copier le code et réserver", systemImage: "arrow.up.right").font(.headline).frame(maxWidth: .infinity).frame(height: 36).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.or)
                        } else { Text("Pas de réservation en ligne annoncée pour cette séance.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Button { calendar = true } label: { Label("Ajouter au Calendrier iPhone", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass)
                    if saved { Button(role: .destructive) { drop = true } label: { Text("Retirer de mes séances").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass) }
                    else { Button { withAnimation(.bouncy) { store.put(item) }; Haptic.ok() } label: { Label("Ajouter à mes séances (rappel 1 h 30 avant)", systemImage: "bell.badge").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass) }
                }.padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fermer", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: "\(item.title), \(Jour.jolie(Jour.iso(item.start), long: true)) à \(Jour.heure(item.start)), \(item.cinema.name)") }
            }
        }
        .presentationDetents([.large])
        .onChange(of: phase) { _, p in if p == .active && left { left = false; withAnimation { booked = true } } }
        .confirmationDialog("Retirer cette séance ?", isPresented: $drop, titleVisibility: .visible) { Button("Retirer", role: .destructive) { store.drop(item); Haptic.tap(); dismiss() } }
        .sheet(isPresented: $calendar) { EventEditor(item: item) { ok in calendar = false; if ok { Haptic.ok(); store.put(item); store.say("Ajouté au calendrier") } }.ignoresSafeArea() }
        .sheet(item: $show) { TicketSheet(ticket: $0) }
        .sheet(isPresented: $pickTickets) {
            NavigationStack {
                List(store.usable(for: item)) { t in
                    Button { item.tickets.append(t.id); if saved { store.put(item) }; Haptic.ok(); pickTickets = false } label: {
                        VStack(alignment: .leading) { Text(t.title).font(.headline); Text([t.until.map { "Valable jusqu’au " + Jour.fmt($0, "d MMM yyyy") }, t.total > 1 ? "\(store.freePlaces(t, except: item.id)) places libres" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(item.tickets.filter { $0 == t.id }.count >= store.freePlaces(t, except: item.id))
                }.navigationTitle("Choisir une place").navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large])
        }
    }
    private func copy(_ l: [Ticket]) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: l.map(\.number).joined(separator: "\n")]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(900)])
        Haptic.ok(); store.say("Code copié")
    }
    private func info(_ i: String, _ a: String, _ b: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: i).foregroundStyle(Color.or).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) { Text(a).font(.subheadline.weight(.semibold)); if let b, !b.isEmpty { Text(b).font(.caption).foregroundStyle(.secondary) } }.multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }.contentShape(.rect)
    }
}
/// L’éditeur système ne demande aucun accès au calendrier
struct EventEditor: UIViewControllerRepresentable {
    let item: AgendaItem
    let done: (Bool) -> Void
    final class C: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void
        init(_ d: @escaping (Bool) -> Void) { done = d }
        func eventEditViewController(_ c: EKEventEditViewController, didCompleteWith a: EKEventEditViewAction) { done(a == .saved) }
    }
    func makeCoordinator() -> C { C(done) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let s = EKEventStore(), e = EKEvent(eventStore: s), v = EKEventEditViewController()
        e.title = "🎬 " + item.title; e.startDate = item.start; e.endDate = item.end; e.timeZone = Jour.paris
        e.location = item.cinema.name + ", " + item.cinema.address
        e.notes = ([item.version] + item.formats).filter { !$0.isEmpty }.joined(separator: " · ")
        e.url = item.url.flatMap(URL.init)
        e.addAlarm(EKAlarm(relativeOffset: -5400))
        v.eventStore = s; v.event = e; v.editViewDelegate = context.coordinator
        return v
    }
    func updateUIViewController(_ v: EKEventEditViewController, context: Context) {}
}
