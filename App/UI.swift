import SwiftUI
import CoreHaptics

// MARK: Vibrations
@MainActor enum Haptic {
    private static var engine: CHHapticEngine?
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7) }
    static func pick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func ok() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    /// Deux battements, comme un cœur
    static func heart() { play([(0, 0.6, 0.3), (0.12, 1, 0.6)]) }
    /// Montée de cinq petits chocs pour la note maximale
    static func stars() { play((0..<5).map { (Double($0) * 0.07, 0.4 + Float($0) * 0.15, 0.3 + Float($0) * 0.15) }) }
    private static func play(_ l: [(Double, Float, Float)]) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil { engine = try CHHapticEngine(); engine?.isAutoShutdownEnabled = true }
            try engine?.start()
            let ev = l.map { CHHapticEvent(eventType: .hapticTransient, parameters: [.init(parameterID: .hapticIntensity, value: $0.1), .init(parameterID: .hapticSharpness, value: $0.2)], relativeTime: $0.0) }
            try engine?.makePlayer(with: CHHapticPattern(events: ev, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch { engine = nil; ok() }
    }
}

// MARK: Navigation
enum Route: Hashable { case film(Film, String), cinema(Cinema), person(Person), grid(GridQuery), settings }
struct GridQuery: Hashable { var title: String, path: String, params: [String: String] = [:], films: [Film]? = nil }
extension EnvironmentValues { @Entry var zoomNS: Namespace.ID? }

struct Pile<Content: View>: View {
    @Namespace private var ns
    @Binding var path: [Route]
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack(path: $path) {
            content.navigationDestination(for: Route.self) { r in
                Group {
                    switch r {
                    case .film(let f, let src): FilmView(film: f).navigationTransition(.zoom(sourceID: src, in: ns))
                    case .cinema(let c): CinemaView(cinema: c)
                    case .person(let p): PersonView(person: p)
                    case .grid(let g): GridScreen(q: g)
                    case .settings: SettingsView()
                    }
                }.environment(\.zoomNS, ns)
            }
        }.environment(\.zoomNS, ns)
    }
}
struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNS) private var ns
    func body(content: Content) -> some View { if let ns { content.matchedTransitionSource(id: id, in: ns) } else { content } }
}

// MARK: Images
final class ImageBank {
    static let shared = ImageBank()
    let mem = NSCache<NSURL, UIImage>()
    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 400 << 20); c.requestCachePolicy = .returnCacheDataElseLoad; c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()
    init() { mem.totalCostLimit = 150 << 20 }
    func load(_ u: URL) async -> UIImage? {
        if let i = mem.object(forKey: u as NSURL) { return i }
        guard let (d, _) = try? await session.data(from: u), let i = UIImage(data: d), let p = await i.byPreparingForDisplay() else { return nil }
        mem.setObject(p, forKey: u as NSURL, cost: Int(p.size.width * p.size.height * p.scale * p.scale * 4))
        return p
    }
}
struct Pic<P: View>: View {
    let url: URL?
    var mode: ContentMode = .fill
    @ViewBuilder var placeholder: P
    @State private var img: UIImage?
    @State private var shown: URL?
    var body: some View {
        ZStack {
            if let img, shown == url { Image(uiImage: img).resizable().aspectRatio(contentMode: mode).transition(.opacity) } else { placeholder }
        }
        .task(id: url) {
            guard let url else { img = nil; return }
            if let i = ImageBank.shared.mem.object(forKey: url as NSURL) { img = i; shown = url; return }
            let i = await ImageBank.shared.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { img = i; shown = url }
        }
    }
}
/// Affiche 2:3 ; sans image, un dégradé propre au titre
struct Poster: View {
    let path: String?, title: String
    var width: CGFloat? = nil, size = 342
    var body: some View {
        Color.clear.aspectRatio(2 / 3, contentMode: .fit).frame(width: width)
            .overlay { Pic(url: TMDB.img(path, size)) { Blank(title: title) } }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.7) }
    }
}
struct Blank: View {
    let title: String
    var body: some View {
        let h = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.55), Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay { Text(title).font(.system(.headline, design: .rounded, weight: .bold)).multilineTextAlignment(.center).minimumScaleFactor(0.5).padding(10).foregroundStyle(.white.opacity(0.9)) }
    }
}

// MARK: Cœur animé
struct HeartButton: View {
    let film: Film
    var big = false
    @Environment(Store.self) private var store
    @State private var burst = 0
    var body: some View {
        let on = store.liked(film.id)
        Button {
            if !on { burst += 1 }
            store.like(film)
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(big ? .title3 : .subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.rose : .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: on)
                .frame(width: big ? 48 : 34, height: big ? 48 : 34)
                .background { Sparks(trigger: burst) }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(on ? "Retirer des favoris" : "Ajouter aux favoris")
    }
}
struct Sparks: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var calm
    var body: some View {
        ZStack {
            if !calm {
                ForEach(0..<10, id: \.self) { i in
                    let a = Double(i) / 10 * 2 * .pi
                    Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(i.isMultiple(of: 2) ? Color.rose : .or)
                        .keyframeAnimator(initialValue: 0.0, trigger: trigger) { v, t in
                            v.offset(x: cos(a) * 46 * t, y: sin(a) * 46 * t).scaleEffect(1.2 - t * 0.9).opacity(t == 0 ? 0 : 1 - t)
                        } keyframes: { _ in
                            KeyframeTrack { CubicKeyframe(0.01, duration: 0.02); CubicKeyframe(1, duration: 0.65); LinearKeyframe(0, duration: 0.01) }
                        }
                }
            }
        }.allowsHitTesting(false)
    }
}

// MARK: Étoiles (demi-points, glisser ou toucher)
struct Stars: View {
    @Binding var value: Double
    var size: CGFloat = 40
    @State private var last = -1.0
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: value >= Double(i) ? "star.fill" : value >= Double(i) - 0.5 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size * 0.8)).frame(width: size, height: size)
                    .foregroundStyle(value >= Double(i) - 0.5 ? Color.or : .white.opacity(0.35))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(value.rounded(.up) == Double(i) ? 1.15 : 1)
            }
        }
        .animation(.bouncy(duration: 0.25), value: value)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let v = min(5, max(0, (g.location.x / (size + 6) * 2).rounded(.up) / 2))
            if v != last { last = v; value = v; v == 5 ? Haptic.stars() : Haptic.pick() }
        })
        .accessibilityElement().accessibilityLabel("Note").accessibilityValue("\(value.fr) sur 5")
        .accessibilityAdjustableAction { d in value = min(5, max(0, value + (d == .increment ? 0.5 : -0.5))) }
    }
}

// MARK: Tuiles
struct FilmTile: View {
    let film: Film, source: String
    var width: CGFloat? = 132
    var caption: String? = nil
    @Environment(Store.self) private var store
    var body: some View {
        NavigationLink(value: Route.film(film, source)) {
            VStack(alignment: .leading, spacing: 7) {
                Poster(path: film.poster, title: film.title, width: width)
                    .overlay(alignment: .bottomLeading) {
                        if let r = store.s.ratings[film.id] { Badge(text: r.stars.fr, icon: "star.fill", tint: .or).padding(7) }
                        else if let n = film.note, n > 0 { Badge(text: n.fr, icon: "chart.bar.fill", tint: .white).padding(7) }
                    }
                    .overlay(alignment: .topTrailing) { if store.liked(film.id) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.rose).padding(8).background(.black.opacity(0.45), in: .circle).padding(6).transition(.scale.combined(with: .opacity)) } }
                    .modifier(ZoomSource(id: source))
                Text(film.title).font(.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                Text(caption ?? (film.upcoming ? "Le " + Jour.jolie(film.release) : film.year)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: width)
        }
        .buttonStyle(Press())
        .contextMenu {
            Button(store.liked(film.id) ? "Retirer des favoris" : "J’aime", systemImage: store.liked(film.id) ? "heart.slash" : "heart") { store.like(film) }
            Button(store.isLater(film.id) ? "Retirer de « À voir »" : "À voir", systemImage: "bookmark") { store.later(film) }
            Button(store.isSeen(film.id) ? "Marquer non vu" : "Déjà vu", systemImage: "eye") { store.seen(film) }
            ShareLink(item: URL(string: "https://www.themoviedb.org/movie/\(film.id)?language=fr-FR")!) { Label("Partager", systemImage: "square.and.arrow.up") }
        } preview: { Poster(path: film.poster, title: film.title, width: 260, size: 500) }
    }
}
struct Badge: View {
    let text: String, icon: String
    var tint: Color = .white
    var body: some View {
        HStack(spacing: 3) { Image(systemName: icon).font(.system(size: 8)); Text(text).font(.caption2.weight(.bold)).monospacedDigit() }
            .foregroundStyle(tint).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.6), in: .capsule)
    }
}
struct Press: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.scaleEffect(c.isPressed ? 0.95 : 1).brightness(c.isPressed ? 0.06 : 0).animation(.bouncy(duration: 0.28), value: c.isPressed)
            .onChange(of: c.isPressed) { _, p in if p { Haptic.soft() } }
    }
}
struct RailScroll<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: spacing) { content }.scrollTargetLayout() }
            .scrollIndicators(.hidden).contentMargins(.horizontal, 18, for: .scrollContent).scrollTargetBehavior(.viewAligned).scrollClipDisabled()
    }
}
extension View {
    /// Les tuiles s’effacent doucement aux bords
    func railFade() -> some View { scrollTransition(.interactive, axis: .horizontal) { v, p in v.scaleEffect(p.isIdentity ? 1 : 0.9).opacity(p.isIdentity ? 1 : 0.55) } }
    func card(_ r: CGFloat = 24) -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: r, style: .continuous)) }
}
struct RailHead: View {
    let title: String
    var icon: String? = nil, more: Route? = nil, logo: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let logo { Pic(url: TMDB.img(logo, 92)) { Color.white.opacity(0.1) }.frame(width: 26, height: 26).clipShape(.rect(cornerRadius: 7)) }
            else if let icon { Image(systemName: icon).foregroundStyle(Color.or) }
            Text(title).font(.title3.weight(.bold)).lineLimit(1)
            Spacer()
            if let more { NavigationLink(value: more) { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).frame(width: 32, height: 32) }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Voir tout") }
        }.padding(.horizontal, 18)
    }
}
struct Shimmer: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View { content.opacity(on ? 0.45 : 1).onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } } }
}
struct GhostRail: View {
    var body: some View {
        HStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08)).frame(width: 132, height: 198) } }
            .padding(.horizontal, 18).frame(maxWidth: .infinity, alignment: .leading).clipped().modifier(Shimmer())
    }
}
struct Chip: View {
    let text: String
    var icon: String? = nil, on = false
    let action: () -> Void
    var body: some View {
        Button { Haptic.pick(); withAnimation(.snappy) { action() } } label: {
            HStack(spacing: 6) { if let icon { Image(systemName: icon) }; Text(text) }.font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(minHeight: 44)
                .foregroundStyle(on ? .black : .white)
        }
        .buttonStyle(.plain).glassEffect(on ? .regular.tint(.white).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
struct Note: View {
    let text: String
    var icon = "info.circle", retry: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.or)
            Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("Réessayer", action: retry).buttonStyle(.glass) }
        }.card(20)
    }
}
struct Ambient: View {
    let path: String?
    var body: some View {
        ZStack {
            Color.fond
            if let path {
                Pic(url: TMDB.img(path, 300)) { Color.clear }.blur(radius: 70).opacity(0.5).id(path).transition(.opacity)
            }
            LinearGradient(colors: [.clear, .fond.opacity(0.55), .fond], startPoint: .top, endPoint: .bottom)
        }.animation(.easeInOut(duration: 1), value: path).ignoresSafeArea()
    }
}

// MARK: Grille
struct GridScreen: View {
    let q: GridQuery
    @State private var films: [Film] = []
    @State private var page = 0
    @State private var done = false
    @State private var err: String?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                ForEach(q.films ?? films) { f in
                    FilmTile(film: f, source: "g-\(f.id)", width: nil)
                        .scrollTransition { v, p in v.opacity(p.isIdentity ? 1 : 0.4).scaleEffect(p.isIdentity ? 1 : 0.94) }
                        .onAppear { if f.id == films.last?.id { Task { await more() } } }
                }
            }.padding(18)
            if let err { Note(text: err) { Task { await more() } }.padding(18) } else if films.isEmpty && q.films == nil && !done { ProgressView().padding(40) }
        }
        .background(Color.fond.ignoresSafeArea()).navigationTitle(q.title).navigationBarTitleDisplayMode(.large)
        .task { if films.isEmpty { await more() } }
    }
    private func more() async {
        guard q.films == nil, !done, page < 25 else { return }
        do {
            let l = try await TMDB.list(q.path, q.params, page: page + 1)
            page += 1; err = nil
            let new = l.filter { x in !films.contains { $0.id == x.id } }
            if l.isEmpty { done = true }
            withAnimation { films += new }
        } catch is CancellationError {} catch { err = error.localizedDescription }
    }
}
struct PersonView: View {
    let person: Person
    @State private var films: [Film] = []
    @State private var err: String?
    @State private var bio = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Pic(url: TMDB.img(person.photo, 342)) { Blank(title: person.name) }.frame(width: 150, height: 150).clipShape(.circle).glassEffect(.regular, in: .circle)
                Text(person.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                if !bio.isEmpty { Text(bio).font(.subheadline).foregroundStyle(.secondary).lineLimit(6).padding(.horizontal, 18) }
                if let err { Note(text: err).padding(18) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) { ForEach(films) { FilmTile(film: $0, source: "p-\($0.id)", width: nil) } }.padding(18)
            }
        }
        .background(Ambient(path: person.photo)).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let j = try await TMDB.get("/person/\(person.id)", ["append_to_response": "movie_credits"], ttl: 7 * 86400)
                bio = j["biography"] as? String ?? ""
                let c = j["movie_credits"] as? J, dir = person.role == "Director"
                let l = dir ? ((c?["crew"] as? [J]) ?? []).filter { $0["job"] as? String == "Director" } : (c?["cast"] as? [J]) ?? []
                var seen = Set<Int>()
                films = l.sorted { ($0["popularity"] as? Double ?? 0) > ($1["popularity"] as? Double ?? 0) }.compactMap(TMDB.film).filter { $0.poster != nil && seen.insert($0.id).inserted }
            } catch is CancellationError {} catch { err = error.localizedDescription }
        }
    }
}
