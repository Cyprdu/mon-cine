import SwiftUI
import WebKit

struct FilmView: View {
    let film: Film
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var d: FilmDetail?
    @State private var err: String?
    @State private var more = false
    @State private var trailer = false
    @State private var rating = false
    @State private var past = false
    @State private var offers: [Offer]?
    @State private var showSeances = false
    private var f: Film {   // l’affiche déjà visible est gardée, sans changement à l’arrivée de la fiche
        guard var x = d?.film else { return film }
        x.poster = film.poster ?? x.poster; x.back = film.back ?? x.back
        if x.overview.isEmpty { x.overview = film.overview }
        return x
    }
    private var inCine: Bool { offers?.contains { $0.kind == "CINEMA" } ?? Affiche.shared.has(film) || Affiche.shared.has(film) }
    private var reissue: Bool { inCine && Affiche.old(f) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    actions(proxy)
                    if let err { Note(text: err) { Task { await load() } }.padding(.horizontal, 18) }
                    if let t = d?.tagline, !t.isEmpty { Text(t).font(.title3.weight(.semibold)).italic().padding(.horizontal, 18) }
                    if !f.overview.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.overview).lineSpacing(4).lineLimit(more ? nil : 4).foregroundStyle(.white.opacity(0.88))
                            if f.overview.count > 180 { Button(more ? "Réduire" : "Lire la suite") { Haptic.tap(); withAnimation(.snappy) { more.toggle() } }.font(.subheadline.weight(.semibold)) }
                        }.padding(.horizontal, 18)
                    }
                    watch
                    VStack(alignment: .leading, spacing: 14) {
                        RailHead(title: "Au cinéma", icon: "popcorn.fill")
                        if inCine || showSeances { FilmSeances(film: f, original: d?.original ?? "") } else {
                            Button { Haptic.tap(); withAnimation(.snappy) { showSeances = true } } label: { Label("Chercher des séances", systemImage: "magnifyingglass").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass).padding(.horizontal, 18)
                        }
                    }.id("seances")
                    if let d {
                        if !(d.directors + d.cast).isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                RailHead(title: "Distribution", icon: "person.2.fill")
                                RailScroll(spacing: 14) { ForEach(Array((d.directors + d.cast).enumerated()), id: \.offset) { _, p in face(p) } }
                            }
                        }
                        if !d.similar.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                RailHead(title: "Dans le même esprit", icon: "sparkles")
                                RailScroll { ForEach(d.similar) { FilmTile(film: $0, source: "sim-\(f.id)-\($0.id)").railFade() } }
                            }
                        }
                    }
                }.padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 320 } action: { _, y in past = y }
        }
        .background { Ambient(path: f.back ?? f.poster) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(f.title).font(.headline).lineLimit(1).opacity(past ? 1 : 0).animation(.easeOut, value: past) }
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: URL(string: "https://www.themoviedb.org/movie/\(f.id)?language=fr-FR")!, subject: Text(f.title)) }
        }
        .sheet(isPresented: $trailer) { if let k = d?.trailer { TrailerSheet(key: k, title: f.title) } }
        .sheet(isPresented: $rating) { RatingSheet(film: f).presentationDetents([.height(440)]) }
        .task { async let a: Void = load(); offers = try? await JustWatch.shared.offers(film); if offers?.isEmpty == true, let o = d?.original, !o.isEmpty { offers = (try? await JustWatch.shared.offers(film, original: o)) ?? [] }; await a }
    }
    private func load() async {
        do { let x = try await TMDB.detail(film.id); withAnimation { d = x; err = nil } } catch is CancellationError {} catch { err = error.localizedDescription }
    }
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay { ZStack { Pic(url: TMDB.img(film.poster, 342)) { Color.clear }.blur(radius: 24); Pic(url: TMDB.img(f.back ?? f.poster, 1280)) { Blank(title: "") } } }
                .clipped()
                .mask { LinearGradient(stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }
                .visualEffect { v, g in
                    let y = max(0, g.frame(in: .scrollView).minY), h = max(1, g.size.height)
                    return v.scaleEffect(1 + y / h, anchor: .bottom)
                }
            HStack(alignment: .bottom, spacing: 16) {
                Poster(path: f.poster, title: f.title, width: 118, size: 500).shadow(color: .black.opacity(0.6), radius: 18, y: 10)
                VStack(alignment: .leading, spacing: 8) {
                    if reissue { Ressortie() }
                    if let l = d?.logo { Pic(url: TMDB.img(l, 500), mode: .fit) { Color.clear }.frame(maxWidth: 210, maxHeight: 80, alignment: .leading).accessibilityLabel(f.title) }
                    else { Text(f.title).font(.system(.title, design: .rounded, weight: .heavy)).minimumScaleFactor(0.7).lineLimit(4) }
                    Text([f.upcoming ? "Sortie le " + Jour.jolie(f.release) : f.year, d?.runtime.map(Jour.duree)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.semibold))
                    if let g = d?.genres, !g.isEmpty { Text(g.prefix(3).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        if let n = f.note, n > 0 { Badge(text: n.fr + " / 10", icon: "person.3.fill") }
                        if let r = store.s.ratings[f.id] { Badge(text: r.stars.fr + " / 5", icon: "star.fill", tint: .or) }
                    }
                }
            }.padding(.horizontal, 18)
        }.frame(height: 480)
    }
    private func actions(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if inCine { Button { Haptic.tap(); withAnimation(.snappy) { proxy.scrollTo("seances", anchor: .top) } } label: { Label("Séances", systemImage: "ticket.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 34).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.or) }
                if !inCine || offers.flatMap({ store.direct($0) }) != nil { PlayButton(film: film, offers: offers, known: true) }
                if d?.trailer != nil { Button { Haptic.tap(); trailer = true } label: { Label("Bande-annonce", systemImage: "film").labelStyle(.titleOnly).font(.headline).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity).frame(height: 34) }.buttonStyle(.glass) }
            }
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 0) {
                    labelled("J’aime") { HeartButton(film: f, big: true) }
                    round(store.isLater(f.id) ? "bookmark.fill" : "bookmark", "À voir", store.isLater(f.id)) { store.later(f) }
                    round(store.s.ratings[f.id] == nil ? "star" : "star.fill", "Noter", store.s.ratings[f.id] != nil) { Haptic.tap(); rating = true }
                    round(store.isSeen(f.id) ? "eye.fill" : "eye", "Vu", store.isSeen(f.id)) { store.seen(f) }
                }
            }
        }.padding(.horizontal, 18)
    }
    private func labelled<V: View>(_ t: String, @ViewBuilder _ v: () -> V) -> some View { VStack(spacing: 6) { v(); Text(t).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
    private func round(_ icon: String, _ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        labelled(t) {
            Button(action: a) { Image(systemName: icon).font(.title3).foregroundStyle(on ? Color.or : .white).contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: on).frame(width: 48, height: 48) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel(t)
        }
    }
    // MARK: Streaming
    @ViewBuilder private var watch: some View {
        if let offers, offers.contains(where: { $0.kind != "CINEMA" }) {
            VStack(alignment: .leading, spacing: 14) {
                RailHead(title: "Où regarder", icon: "play.rectangle.fill")
                OfferList(offers: offers).padding(.horizontal, 18)
                Text("Disponibilités en France : JustWatch.").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 18)
            }
        } else if offers != nil || err != nil, let d, !(d.stream + d.free + d.rent + d.buy).isEmpty {
            VStack(alignment: .leading, spacing: 14) { RailHead(title: "Où regarder", icon: "play.rectangle.fill"); ProviderList(film: film, d: d).padding(.horizontal, 18) }
        } else if offers != nil, !inCine, !f.upcoming {
            Text("Pas disponible en streaming en France pour l’instant.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 18)
        }
    }
    private func face(_ p: Person) -> some View {
        NavigationLink(value: Route.person(p)) {
            VStack(spacing: 5) {
                Pic(url: TMDB.img(p.photo, 185)) { Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.08)) }.frame(width: 82, height: 82).clipShape(.circle)
                Text(p.name).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true)
                Text(p.role == "Director" ? "Réalisation" : p.role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.multilineTextAlignment(.center).frame(width: 92)
        }.buttonStyle(Press())
    }
}

struct RatingSheet: View {
    let film: Film
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var v = 0.0
    @State private var text = ""
    var body: some View {
        VStack(spacing: 20) {
            Text(film.title).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
            Text(v.fr).font(.system(size: 56, weight: .black, design: .rounded)).contentTransition(.numericText(value: v)).foregroundStyle(Color.or).animation(.bouncy, value: v)
            Stars(value: $v, size: 46)
            TextField("Un mot sur le film (facultatif)", text: $text, axis: .vertical).lineLimit(1...3).padding(14).glassEffect(.regular, in: .rect(cornerRadius: 18))
            HStack {
                if store.s.ratings[film.id] != nil { Button("Retirer", role: .destructive) { store.rate(film, 0); dismiss() }.buttonStyle(.glass) }
                Button { store.rate(film, v, text); Haptic.ok(); dismiss() } label: { Text("Enregistrer").frame(maxWidth: .infinity).foregroundStyle(.black) }.buttonStyle(.glassProminent).disabled(v == 0)
            }.controlSize(.large)
        }
        .padding(24)
        .onAppear { if let r = store.s.ratings[film.id] { v = r.stars; text = r.comment } }
    }
}

struct TrailerSheet: View {
    let key: String, title: String
    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.headline).padding(.top, 24)
            YouTube(key: key).aspectRatio(16 / 9, contentMode: .fit).clipShape(.rect(cornerRadius: 20)).padding(.horizontal, 14)
            Link(destination: URL(string: "https://www.youtube.com/watch?v=\(key)")!) { Label("Ouvrir dans YouTube", systemImage: "arrow.up.right").frame(maxWidth: .infinity).frame(height: 34) }.buttonStyle(.glass).padding(.horizontal, 18)
            Spacer()
        }.presentationDetents([.medium, .large])
    }
}
struct YouTube: UIViewRepresentable {
    let key: String
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true; c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false; w.backgroundColor = .black; w.scrollView.isScrollEnabled = false
        var r = URLRequest(url: URL(string: "https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&playsinline=1&rel=0&hl=fr")!)
        r.setValue("https://fr.cyprdu.moncine", forHTTPHeaderField: "Referer")   // YouTube exige un référent pour les lecteurs intégrés
        w.load(r)
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
    static func dismantleUIView(_ w: WKWebView, coordinator: ()) { w.loadHTMLString("", baseURL: nil) }
}
