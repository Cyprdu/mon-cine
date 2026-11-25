import SwiftUI
import WebKit
import AVFoundation

struct FilmView: View {
    let film: Film
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var d: FilmDetail?
    @State private var err: String?
    @State private var more = false
    @State private var trailer = false
    @State private var rating = false
    @State private var past = false
    @State private var offers: [Offer]?
    @State private var rep: Reprise?
    @State private var bande = false
    @State private var tick = 0
    @State private var saga: [Film] = []
    private var f: Film {   // l’affiche déjà visible est gardée, sans changement à l’arrivée de la fiche
        guard var x = d?.film else { return film }
        x.poster = film.poster ?? x.poster; x.back = film.back ?? x.back
        if x.overview.isEmpty { x.overview = film.overview }
        return x
    }
    /// Film ancien : en salles seulement si la base lui connaît des villes
    private var inCine: Bool {
        if film.tv { return false }
        let annonce = (offers?.contains { $0.kind == "CINEMA" } ?? false) || Affiche.shared.has(film)
        if Affiche.old(f), let r = rep, r.lu != nil { return !r.lieux.isEmpty }
        return annonce
    }
    private var reissue: Bool { inCine && Affiche.old(f) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    actions(proxy)
                    if let err { Note(text: err) { Task { await load() } }.padding(.horizontal, 18) }
                    if let t = d?.tagline, !t.isEmpty { Text(t).font(.headline).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 18) }
                    if !f.overview.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.overview).lineSpacing(4).lineLimit(more ? nil : 4).foregroundStyle(.white.opacity(0.88))
                            if f.overview.count > 180 { Button(more ? "Réduire" : "Lire la suite") { Haptic.tap(); withAnimation(.snappy) { more.toggle() } }.font(.subheadline.weight(.semibold)) }
                        }.padding(.horizontal, 18)
                    }
                    if inCine {
                        VStack(alignment: .leading, spacing: 14) {
                            RailHead(title: reissue ? "Ressortie au cinéma" : "Au cinéma", icon: "popcorn.fill")
                            FilmSeances(film: f, original: d?.original ?? "", runtime: d?.runtime, reprise: rep)
                        }.id("seances")
                    }
                    if let d, !d.saisons.isEmpty { SaisonsView(film: f, saisons: d.saisons) }
                    if let d {
                        if !(d.directors + d.cast).isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                RailHead(title: "Distribution", icon: "person.2.fill")
                                RailScroll(spacing: 14) { ForEach(Array((d.directors + d.cast).enumerated()), id: \.offset) { _, p in face(p) } }
                            }
                        }
                        if let s = d.saga, !saga.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                RailHead(title: "La saga " + s.nom, icon: "square.stack.fill", more: .grid(GridQuery(title: s.nom, path: "", films: saga)))
                                RailScroll { ForEach(saga.filter { $0.id != f.id }) { FilmTile(film: $0, source: "saga-\(f.id)-\($0.id)").railFade() } }
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
            .ignoresSafeArea(edges: .top).scrollEdgeEffectHidden(!past, for: .top)
            .background(Color.fond)
            .onScrollPhaseChange { _, p in if p != .idle { stop() } }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 320 } action: { _, y in past = y }
        }
        .background { Color.fond.ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(f.title).font(.headline).lineLimit(1).frame(maxWidth: 170).opacity(past ? 1 : 0).animation(.easeOut, value: past) }
            if Son.shared.visible && bande { ToolbarItem(placement: .topBarTrailing) { BoutonSon() } }
            ToolbarItem(placement: .topBarTrailing) { MenuPlaylists(film: f) }
            if d?.trailer != nil { ToolbarItem(placement: .topBarTrailing) { Button("Bande-annonce", systemImage: "movieclapper.fill") { Haptic.tap(); stop(); trailer = true } } }
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: f.web, subject: Text(f.title)) }
        }
        .sheet(isPresented: $trailer) { if let k = d?.trailer { TrailerSheet(key: k, title: f.title) } }
        .sheet(isPresented: $rating) { RatingSheet(film: f).presentationDetents([.height(440)]) }
        .onDisappear { bande = false }
        .task(id: "\(tick)|\(d?.trailer ?? "")|\(past)|\(trailer || rating)") {
            bande = false
            guard !calm, !past, !trailer, !rating, d?.trailer != nil, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { bande = true }
        }
        .task(id: d?.saga) { if let s = d?.saga, let l = try? await TMDB.saga(s.id), l.contains(where: { $0.id != film.id }) { withAnimation { saga = l } } }
        .task { if !film.tv { rep = await Registre.shared.reprise(film) } }
        .task { async let a: Void = load(); offers = try? await JustWatch.shared.offers(film); if offers?.isEmpty == true, let o = d?.original, !o.isEmpty { offers = (try? await JustWatch.shared.offers(film, original: o)) ?? [] }; await a }
    }
    private func stop() { if bande { withAnimation(.easeOut(duration: 0.3)) { bande = false } }; tick += 1 }
    private func load() async {
        do { let x = try await TMDB.detail(film.id); withAnimation { d = x; err = nil } } catch is CancellationError {} catch { err = error.localizedDescription }
    }
    /// Une seule grande image sans texte, le logo du film dessus
    private var header: some View {
        let art = Visuel(f, d), ready = d != nil || err != nil
        return ZStack(alignment: .bottom) {
            Color.clear
                .overlay(alignment: .top) { if ready { Pic(url: TMDB.img(art.path, 780)) { Blank(title: "") } } }
                .frame(height: 540)
                .overlay { if bande, let k = d?.trailer { Bande(key: k) } }
                .clipped()
                .overlay { LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.2), .init(color: .clear, location: 0.45), .init(color: .fond.opacity(0.9), location: 0.92), .init(color: .fond, location: 1)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false) }
                .allowsHitTesting(false).accessibilityHidden(true)
            VStack(spacing: 10) {
                if reissue { Ressortie() }
                if let l = d?.logo { Pic(url: TMDB.img(l, 500), mode: .fit) { Text(f.title).font(.largeTitle.bold()) }.frame(maxWidth: 290, maxHeight: 110).shadow(color: .black.opacity(0.5), radius: 10).accessibilityElement().accessibilityLabel(f.title).accessibilityAddTraits(.isHeader) }
                else if ready { Text(f.title).font(.system(size: 34, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(3).shadow(color: .black.opacity(0.6), radius: 10).accessibilityAddTraits(.isHeader) }
                Text([f.upcoming ? "Sortie le " + Jour.jolie(f.release) : f.year, d.flatMap { $0.saisons.isEmpty ? nil : "\($0.saisons.count) saison\($0.saisons.count > 1 ? "s" : "")" + ($0.fini ? "" : ", en cours") }, d?.runtime.map(Jour.duree), d?.genres.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if let n = f.sur5 { Badge(text: n + " / 5", icon: "person.3.fill") }
                    if let p = d?.prochain { Badge(text: "Épisode " + Jour.jolie(p).lowercased(), icon: "calendar") }
                    if let r = store.s.ratings[f.id] { Badge(text: r.stars.fr + " / 5", icon: "star.fill", tint: .or) }
                }
            }.padding(.horizontal, 24).frame(maxWidth: .infinity)
        }.frame(height: 540)
    }
    private func actions(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if inCine { Button { Haptic.tap(); withAnimation(.snappy) { proxy.scrollTo("seances", anchor: .top) } } label: { Label("Séances", systemImage: "ticket.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 34).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.or) }
                if watchable { PlayButton(film: film, offers: offers, known: true) }
            }
            if !inCine && !f.tv && Affiche.old(f) && store.alerte(f.id) { Label("Alerte active : tu seras prévenu de sa ressortie", systemImage: "bell.badge.fill").font(.footnote).foregroundStyle(Color.or) }
            if !inCine && !watchable && loaded { Text(f.upcoming ? "Pas encore sorti" : "Pas disponible en streaming en France pour l’instant").font(.subheadline).foregroundStyle(.secondary) }
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 0) {
                    labelled("J’aime") { HeartButton(film: f, big: true) }
                    round(store.isLater(f.id) ? "bookmark.fill" : "bookmark", "À voir", store.isLater(f.id)) { store.later(f) }
                    round(store.s.ratings[f.id] == nil ? "star" : "star.fill", "Noter", store.s.ratings[f.id] != nil) { Haptic.tap(); rating = true }
                    if !f.tv && Affiche.old(f) { round(store.alerte(f.id) ? "bell.fill" : "bell", "Ressortie", store.alerte(f.id)) { store.alerter(f) } }
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
    private var loaded: Bool { offers != nil && (d != nil || err != nil) }
    /// Au moins une offre hors cinéma ; avant la réponse, seulement pour un film qui n’est pas en salle
    private var watchable: Bool {
        if let o = offers, o.contains(where: { $0.kind != "CINEMA" }) { return true }
        if let d, !(d.stream + d.free + d.rent + d.buy).isEmpty { return true }
        return !loaded && !inCine && !f.upcoming
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

/// Le son choisi vaut pour les bandes-annonces suivantes, jusqu’à la fermeture de l’app
@MainActor @Observable final class Son {
    static let shared = Son()
    var on = false, visible = false
    @ObservationIgnored weak var web: WKWebView?
    func basculer() { on.toggle(); appliquer() }
    /// Commande directe au lecteur, puis vérification : s’il est resté muet ou s’est arrêté, il est relancé avec le son
    func appliquer() {
        let s = AVAudioSession.sharedInstance()
        if on { try? s.setCategory(.playback, mode: .moviePlayback); try? s.setActive(true) }
        web?.evaluateJavaScript("typeof son==='function'&&son(\(on))")
        if on {
            Task { [weak web] in
                for t in [700, 1800] { try? await Task.sleep(for: .milliseconds(t)); if on { _ = try? await web?.evaluateJavaScript("typeof verif==='function'&&verif();1") } }
            }
        } else { try? s.setActive(false, options: .notifyOthersOnDeactivation); try? s.setCategory(.ambient) }
    }
    func fin(_ w: WKWebView) {
        guard web === w else { return }
        web = nil
        Task { if self.web == nil || !self.on { self.visible = false } }
        if on { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
struct BoutonSon: View {
    private var son = Son.shared
    init() {}
    var body: some View {
        Button { Haptic.tap(); son.basculer() } label: { Image(systemName: son.on ? "speaker.wave.2.fill" : "speaker.slash.fill").contentTransition(.symbolEffect(.replace)) }.accessibilityLabel(son.on ? "Couper le son" : "Activer le son")
    }
}
/// Bande-annonce sans lecteur ; l’image reste devant tant que la vidéo n’a pas vraiment démarré.
struct Bande: View {
    let key: String
    @State private var visible = false
    var body: some View {
        GeometryReader { g in
            // Page rendue en 1920 × 1080 pour que YouTube choisisse la HD, puis mise à l’échelle : remplit tout le cadre, bandes noires du format large comprises
            let k = max(g.size.width / 1920, g.size.height / 1080) * 1.34
            BandeWeb(key: key, visible: $visible).frame(width: 1920, height: 1080).scaleEffect(k).position(x: g.size.width / 2, y: g.size.height / 2)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipped().opacity(visible ? 1 : 0).animation(.easeInOut(duration: 0.8), value: visible)
        .onChange(of: visible) { withAnimation { Son.shared.visible = visible }; if visible && Son.shared.on { Son.shared.appliquer() } }
    }
}
struct BandeWeb: UIViewRepresentable {
    let key: String
    @Binding var visible: Bool
    final class C: NSObject, WKScriptMessageHandler {
        let set: (Bool) -> Void
        init(_ s: @escaping (Bool) -> Void) { set = s }
        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { set(m.body as? String == "on") }
    }
    func makeCoordinator() -> C { C { v in visible = v } }
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true; c.mediaTypesRequiringUserActionForPlayback = []
        c.userContentController.add(context.coordinator, name: "etat")
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false; w.backgroundColor = .clear; w.scrollView.isScrollEnabled = false; w.isUserInteractionEnabled = false
        Son.shared.web = w
        w.scrollView.contentInsetAdjustmentBehavior = .never   // sinon une marge reste en haut, sous l’heure
        w.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=1920,initial-scale=1,viewport-fit=cover"><meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#p{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;border:0}</style><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        function dis(m){webkit.messageHandlers.etat.postMessage(m)}
        var vu=false;
        var P;
        function soustitres(p){try{p.unloadModule('captions');p.unloadModule('cc');p.setOption('captions','track',{})}catch(e){}}
        function son(v){if(P&&P.mute){if(v){P.unMute();P.setVolume(100)}else{P.mute()}}}
        function verif(){if(!P||!P.isMuted)return;if(P.isMuted()||(P.getPlayerState()!==1&&P.getPlayerState()!==3)){var t=P.getCurrentTime()||4;P.unMute();P.setVolume(100);P.loadVideoById({videoId:'\(key)',startSeconds:t});P.unMute();setTimeout(function(){P.unMute();P.setVolume(100);P.playVideo()},400)}}
        function onYouTubeIframeAPIReady(){P=new YT.Player('p',{width:'100%',height:'100%',videoId:'\(key)',host:'https://www.youtube-nocookie.com',
        playerVars:{autoplay:1,mute:1,controls:0,disablekb:1,fs:0,modestbranding:1,playsinline:1,rel:0,iv_load_policy:3,start:4,origin:'https://fr.cyprdu.moncine'},
        events:{onReady:function(e){e.target.mute();soustitres(e.target);e.target.playVideo()},onApiChange:function(e){soustitres(e.target)},onError:function(){dis('off')},
        onStateChange:function(e){if(e.data===1){soustitres(e.target)}if(e.data===1&&!vu){vu=true;e.target.setPlaybackQuality('hd1080');setTimeout(function(){dis('on')},2600)}if(e.data===0)dis('off')}}})
        var f=document.getElementById('p');if(f&&f.setAttribute)f.setAttribute('allow','autoplay; encrypted-media; picture-in-picture')}
        </script>
        """, baseURL: URL(string: "https://fr.cyprdu.moncine")!)
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
    static func dismantleUIView(_ w: WKWebView, coordinator: C) {
        Son.shared.fin(w)
        w.configuration.userContentController.removeScriptMessageHandler(forName: "etat")
        w.loadHTMLString("", baseURL: nil)
    }
}

// MARK: Saisons et épisodes
struct SaisonsView: View {
    let film: Film, saisons: [Saison]
    @Environment(Store.self) private var store
    @State private var sel: Int?
    @State private var list: [Episode] = []
    @State private var all = false
    @State private var err: String?
    private var n: Int { sel ?? saisons.first?.id ?? 1 }
    private func cle(_ e: Episode) -> String { "\(abs(film.id))-\(n)-\(e.n)" }
    var body: some View {
        let vus = list.filter { store.s.episodes.contains(cle($0)) }.count
        VStack(alignment: .leading, spacing: 14) {
            RailHead(title: "Épisodes", icon: "tv.fill")
            ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(saisons) { s in Chip(text: s.nom, on: s.id == n) { sel = s.id; all = false } } }.padding(.horizontal, 18) }.scrollIndicators(.hidden).scrollClipDisabled()
            if !list.isEmpty {
                HStack {
                    Text("\(list.count) épisodes" + (vus > 0 ? " · \(vus) vu\(vus > 1 ? "s" : "")" : "")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(vus == list.count ? "Tout décocher" : "Tout marquer vu") { Haptic.ok(); let k = list.map(cle); if vus == list.count { store.s.episodes.subtract(k) } else { store.s.episodes.formUnion(k) } }.font(.subheadline.weight(.semibold))
                }.padding(.horizontal, 18)
            }
            if let err { Note(text: err).padding(.horizontal, 18) }
            VStack(spacing: 0) {
                ForEach(all ? list : Array(list.prefix(6))) { e in ligne(e) }
                if list.count > 6 { Button(all ? "Réduire" : "Voir les \(list.count) épisodes") { Haptic.tap(); withAnimation(.snappy) { all.toggle() } }.buttonStyle(.glass).padding(.top, 10) }
            }
            if list.isEmpty && err == nil { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)).frame(height: 76).modifier(Shimmer()) }.padding(.horizontal, 18) }
        }
        .task(id: n) { do { let l = try await TMDB.saison(film.id, n); await ImageBank.shared.prefetch(l.prefix(6).map { TMDB.img($0.image, 300) }); withAnimation { list = l; err = nil } } catch is CancellationError {} catch { list = []; err = error.localizedDescription } }
    }
    private func ligne(_ e: Episode) -> some View {
        let vu = store.s.episodes.contains(cle(e))
        return HStack(spacing: 12) {
            Color.white.opacity(0.07).frame(width: 124, height: 70).overlay { Pic(url: TMDB.img(e.image, 300)) { Image(systemName: "tv").foregroundStyle(.secondary) } }.clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(e.n). \(e.titre)").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([e.date.isEmpty ? nil : Jour.jolie(e.date), e.min.map(Jour.duree)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if !e.texte.isEmpty { Text(e.texte).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { Haptic.pick(); if vu { store.s.episodes.remove(cle(e)) } else { store.s.episodes.insert(cle(e)) } } label: { Image(systemName: vu ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(vu ? Color.or : .secondary).frame(width: 44, height: 44).contentTransition(.symbolEffect(.replace)) }.buttonStyle(.plain).accessibilityLabel(vu ? "Marquer non vu" : "Marquer vu")
        }.padding(.horizontal, 18).padding(.vertical, 7)
    }
}
