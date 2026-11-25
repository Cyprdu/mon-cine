import SwiftUI
import Vision
import VisionKit
import AVFoundation
import PDFKit
import PhotosUI
import CoreImage.CIFilterBuiltins
import LocalAuthentication

// MARK: Lecture et dessin des codes
enum Code {
    static func draw(_ payload: String, _ sym: String) -> UIImage? {
        let data = payload.data(using: .isoLatin1) ?? Data(payload.utf8)
        let out: CIImage?
        switch sym {
        case "QR": let f = CIFilter.qrCodeGenerator(); f.message = data; f.correctionLevel = "M"; out = f.outputImage
        case "Aztec": let f = CIFilter.aztecCodeGenerator(); f.message = data; out = f.outputImage
        case "PDF417": let f = CIFilter.pdf417BarcodeGenerator(); f.message = data; out = f.outputImage
        case "Code128": guard payload.allSatisfy(\.isASCII) else { return nil }; let f = CIFilter.code128BarcodeGenerator(); f.message = data; f.barcodeHeight = 40; out = f.outputImage
        default: return nil
        }
        guard let out, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    static func name(_ s: VNBarcodeSymbology) -> String {
        switch s { case .qr: "QR"; case .aztec: "Aztec"; case .pdf417: "PDF417"; case .code128: "Code128"; case .ean13: "EAN13"; case .dataMatrix: "DataMatrix"; default: "Autre" }
    }
    static func read(_ img: CGImage) -> [(payload: String?, sym: String, crop: UIImage?)] {
        let r = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: img).perform([r])
        if (r.results ?? []).isEmpty {   // second lecteur, pour les QR
            let d = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            return (d?.features(in: CIImage(cgImage: img)) ?? []).compactMap { $0 as? CIQRCodeFeature }.map { q in
                let b = q.bounds, c = CGRect(x: b.minX, y: CGFloat(img.height) - b.maxY, width: b.width, height: b.height).insetBy(dx: -b.width * 0.08, dy: -b.height * 0.08)
                return (q.messageString, "QR", img.cropping(to: c).map { UIImage(cgImage: $0) })
            }
        }
        return (r.results ?? []).map { o in
            let b = VNImageRectForNormalizedRect(o.boundingBox, img.width, img.height)
            let flip = CGRect(x: b.minX, y: CGFloat(img.height) - b.maxY, width: b.width, height: b.height).insetBy(dx: -b.width * 0.08, dy: -b.height * 0.08)
            return (o.payloadStringValue, name(o.symbology), img.cropping(to: flip).map { UIImage(cgImage: $0) })
        }
    }
    /// Le code redessiné est relu : s’il diffère, l’image d’origine est gardée
    static func faithful(_ payload: String, _ sym: String) -> Bool {
        guard let i = draw(payload, sym)?.cgImage else { return false }
        let s = max(4, 600 / i.width), w = i.width * s, h = i.height * s, m = 40
        guard let c = CGContext(data: nil, width: w + 2 * m, height: h + 2 * m, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.setFillColor(UIColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: w + 2 * m, height: h + 2 * m))
        c.interpolationQuality = .none; c.draw(i, in: CGRect(x: m, y: m, width: w, height: h))
        return c.makeImage().map { read($0).contains { $0.payload == payload } } ?? false
    }
    static func text(_ img: CGImage) -> String {
        let r = VNRecognizeTextRequest()
        r.recognitionLanguages = ["fr-FR"]; r.recognitionLevel = .accurate; r.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: img).perform([r])
        return (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
enum Importer {
    static func pdf(_ u: URL) -> [Ticket] {
        let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: u) else { return [] }
        var out: [Ticket] = []
        for i in 0..<min(doc.pageCount, 30) {
            guard let p = doc.page(at: i) else { continue }
            let b = p.bounds(for: .mediaBox), k = 2400 / max(b.width, b.height, 1)
            guard let cg = p.thumbnail(of: CGSize(width: b.width * k, height: b.height * k), for: .mediaBox).cgImage else { continue }
            out += image(cg, text: p.string)
        }
        return dedup(out)
    }
    static func file(_ u: URL) -> [Ticket] {
        if u.pathExtension.lowercased() == "pdf" { return pdf(u) }
        let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
        return (try? Data(contentsOf: u)).map(data) ?? []
    }
    static func data(_ d: Data) -> [Ticket] {
        guard let i = UIImage(data: d) else { return [] }
        // Redessinée pour respecter l’orientation de la photo
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let k = min(1, 3000 / max(i.size.width * i.scale, i.size.height * i.scale)), s = CGSize(width: i.size.width * i.scale * k, height: i.size.height * i.scale * k)
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in i.draw(in: CGRect(origin: .zero, size: s)) }.cgImage.map { dedup(image($0, text: nil)) } ?? []
    }
    static func image(_ cg: CGImage, text: String?) -> [Ticket] {
        let t = (text ?? "").count > 30 ? text! : Code.text(cg)
        return Code.read(cg).compactMap { r in
            guard r.payload != nil || r.crop != nil else { return nil }
            var x = parse(t, r.payload)
            x.symbology = r.sym
            if r.payload.map({ !Code.faithful($0, r.sym) }) ?? true { x.image = r.crop?.pngData() }
            return x
        }
    }
    static func scan(_ payload: String?, _ sym: String) -> Ticket { var t = parse("", payload); t.symbology = sym; return t }
    static func dedup(_ l: [Ticket]) -> [Ticket] { var s = Set<String>(); return l.filter { t in t.payload.map { s.insert($0).inserted } ?? true } }
    /// Suggestions tirées du texte ; tout reste modifiable avant l’enregistrement
    static func parse(_ text: String, _ payload: String?) -> Ticket {
        var t = Ticket(payload: payload)
        t.brand = Brand.guess(text)
        t.number = payload.flatMap { $0.count <= 30 && !$0.contains("://") ? $0 : nil } ?? text.firstMatch(of: /(?i)(?:code|n°|num[ée]ro|r[ée]f\S*)\s*(?:de\s+\w+\s*)?:?\s*([A-Z0-9-]{6,24})\b/).map { String($0.1) } ?? ""
        if let m = text.firstMatch(of: /(?i)\bpin\b[^0-9]{0,12}(\d{3,8})/) { t.pin = String(m.1) }
        let dates = dates(text)
        let flat = Match.plat(text)
        if flat.contains("valable") || flat.contains("expire") || flat.contains("validite") || flat.contains("jusqu au") || flat.contains("cinecarte") || t.brand == .cinecheque {
            t.until = dates.max()
            if flat.contains("cinecarte") { t.name = "CinéCarte" }
        } else if let d = dates.first(where: { $0 > .now.addingTimeInterval(-86400) }), let h = text.firstMatch(of: /\b([01]?\d|2[0-3])\s?[hH:]\s?([0-5]\d)\b/), let hh = Int(h.1), let mm = Int(h.2) {
            t.prepaid = false
            t.seance = Jour.cal.date(bySettingHour: hh, minute: mm, second: 0, of: d)
            if let s = text.firstMatch(of: /(?i)(?:si[èe]ges?|places?|fauteuils?)\s*:?\s*([A-Z]{1,2}\s?-?\d{1,2}(?:\s*,\s*[A-Z]{1,2}\s?-?\d{1,2})*)/) { t.seat = String(s.1) }
        }
        return t
    }
    static func dates(_ s: String) -> [Date] {
        let months = ["janv", "fev", "mars", "avr", "mai", "juin", "juil", "aou", "sept", "oct", "nov", "dec"]
        var out: [Date] = []
        for m in s.matches(of: /\b(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4}|\d{2})\b/) {
            if let d = Int(m.1), let mo = Int(m.2), let y = Int(m.3), (1...31).contains(d), (1...12).contains(mo), let x = Jour.cal.date(from: DateComponents(year: y < 100 ? 2000 + y : y, month: mo, day: d, hour: 12)) { out.append(x) }
        }
        for m in Match.plat(s).matches(of: /\b(\d{1,2})(?:er)? ([a-z]{3,9}) (20\d\d)\b/) {
            if let mo = months.firstIndex(where: { m.2.hasPrefix($0) }), let d = Int(m.1), let y = Int(m.3), let x = Jour.cal.date(from: DateComponents(year: y, month: mo + 1, day: d, hour: 12)) { out.append(x) }
        }
        return out
    }
}

// MARK: Carte
struct Pass: View {
    let t: Ticket
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.brand.label).font(.system(.title3, design: .rounded, weight: .heavy))
                Spacer()
                Text(t.prepaid ? (t.total > 1 ? "\(t.left) / \(t.total) places" : (t.name.isEmpty ? "Prépayé" : t.name)) : "Billet").font(.subheadline.weight(.semibold)).opacity(0.8).contentTransition(.numericText(value: Double(t.left)))
            }
            Spacer(minLength: 14)
            if !t.prepaid, !t.film.isEmpty { Text(t.film).font(.headline).lineLimit(1) }
            Text(t.number.isEmpty ? t.title : "••••  " + t.number.suffix(4)).font(.system(.title3, design: .monospaced, weight: .semibold)).lineLimit(1)
            HStack {
                if let s = t.seance { Text(Jour.jolie(Jour.cine(s)) + " · " + Jour.heure(s) + (t.seat.isEmpty ? "" : " · " + t.seat)) }
                else if let u = t.until { Text((t.expired() ? "Expiré le " : "Jusqu’au ") + Jour.fmt(u, "d MMMM yyyy")) }
                Spacer()
                Image(systemName: t.symbology == "Code128" || t.symbology == "PDF417" || t.symbology == "EAN13" ? "barcode" : "qrcode").font(.title2)
            }.font(.footnote.weight(.medium)).opacity(0.85)
        }
        .foregroundStyle(.black.opacity(0.85)).padding(20).frame(maxWidth: .infinity, minHeight: 158, alignment: .leading)
        .background {
            LinearGradient(colors: t.brand.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) { Circle().fill(.white.opacity(0.22)).frame(width: 190).blur(radius: 30).offset(x: 60, y: -80) }
        }
        .clipShape(.rect(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
        .saturation(t.used || t.expired() ? 0.15 : 1)
        .accessibilityElement(children: .combine)
    }
}
struct CodeView: View {
    let t: Ticket
    var body: some View {
        Group {
            if let d = t.image, let i = UIImage(data: d) { Image(uiImage: i).resizable().interpolation(.none).scaledToFit() }
            else if let p = t.payload, let i = Code.draw(p, t.symbology) { Image(uiImage: i).resizable().interpolation(.none).scaledToFit() }
            else { VStack { Image(systemName: "number"); Text(t.number).font(.title.monospaced()) }.foregroundStyle(.black) }
        }
        .padding(26).frame(maxWidth: 320, maxHeight: 320).background(.white, in: .rect(cornerRadius: 24)).accessibilityLabel("Code du billet")
    }
}

// MARK: Onglet Billets
struct TicketsView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var open: Ticket?
    @State private var drafts: Drafts?
    @State private var scanner = false
    @State private var photos = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var files = false
    @State private var busy = false
    @State private var unlocked = false
    @Namespace private var ns
    struct Drafts: Identifiable { let id = UUID(); var list: [Ticket] }
    private var locked: Bool { store.s.lock && !unlocked }
    var body: some View {
        let active = store.tickets.filter { !$0.used && !$0.expired() && ($0.seance ?? .distantFuture) > .now.addingTimeInterval(-14400) }
        let cards = active.filter(\.prepaid).sorted { ($0.until ?? .distantFuture) < ($1.until ?? .distantFuture) }
        let seats = active.filter { !$0.prepaid }.sorted { ($0.seance ?? .distantFuture) < ($1.seance ?? .distantFuture) }
        let old = store.tickets.filter { t in !active.contains { $0.id == t.id } }
        ScrollView {
            if locked { ContentUnavailableView { Label("Billets protégés", systemImage: "faceid") } actions: { Button("Déverrouiller") { unlock() }.buttonStyle(.glassProminent) }.padding(.top, 80) }
            else if store.tickets.isEmpty {
                ContentUnavailableView { Label("Aucun billet", systemImage: "ticket") } description: { Text("Scanne une carte Pathé ou un e-CinéChèque, ou importe un PDF ou une capture. Tu peux aussi partager un PDF vers Mon Ciné depuis Mail ou Fichiers.") } actions: { menu.buttonStyle(.glassProminent) }.padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    section("Billets de séance", seats); section("Cartes et chèques prépayés", cards); section("Utilisés ou expirés", old)
                }.padding(18)
            }
        }
        .background(Ambient(path: nil)).navigationTitle("Billets")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if busy { ProgressView() } else if !locked { menu } } }
        .sheet(item: $open) { TicketSheet(ticket: $0).navigationTransition(.zoom(sourceID: $0.id, in: ns)) }
        .sheet(item: $drafts) { ImportReview(drafts: $0.list) }
        .sheet(isPresented: $scanner) { Scanner { p, s in scanner = false; Haptic.ok(); Task { try? await Task.sleep(for: .seconds(0.5)); run { [Importer.scan(p, s)] } } } }
        .photosPicker(isPresented: $photos, selection: $picked, maxSelectionCount: 12, matching: .images)
        .fileImporter(isPresented: $files, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { r in if let l = try? r.get() { run { l.flatMap(Importer.file) } } }
        .onChange(of: picked) {
            let l = picked; guard !l.isEmpty else { return }
            picked = []; busy = true
            Task { var d: [Data] = []; for i in l { if let x = try? await i.loadTransferable(type: Data.self) { d.append(x) } }; let all = d; run { all.flatMap(Importer.data) } }
        }
        .onChange(of: store.pendingFile, initial: true) { if let u = store.pendingFile { store.pendingFile = nil; run { let l = Importer.file(u); try? FileManager.default.removeItem(at: u); return l } } }
        .onChange(of: phase) { _, p in if p == .background { unlocked = false } }
        .onAppear { if locked { unlock() } }
    }
    private var menu: some View {
        Menu {
            if DataScannerViewController.isSupported { Button("Scanner avec l’appareil photo", systemImage: "qrcode.viewfinder") { if DataScannerViewController.isAvailable { scanner = true } else { requestCamera() } } }
            Button("Depuis mes photos", systemImage: "photo.on.rectangle") { photos = true }
            Button("Depuis un PDF ou un fichier", systemImage: "doc") { files = true }
            Button("Saisir à la main", systemImage: "keyboard") { drafts = Drafts(list: [Ticket()]) }
        } label: { Label("Ajouter", systemImage: "plus") }
    }
    private func requestCamera() { AVCaptureDevice.requestAccess(for: .video) { ok in Task { @MainActor in if ok { scanner = true } else { store.say("Autorise l’appareil photo dans Réglages") } } } }
    @ViewBuilder private func section(_ t: String, _ l: [Ticket]) -> some View {
        if !l.isEmpty {
            Text(t).font(.title3.bold()).padding(.top, 8)
            ForEach(l) { x in
                Button { Haptic.tap(); open = x } label: { Pass(t: x) }.buttonStyle(Press()).matchedTransitionSource(id: x.id, in: ns)
                    .scrollTransition { v, p in v.scaleEffect(p.isIdentity ? 1 : 0.92).opacity(p.isIdentity ? 1 : 0.5).rotation3DEffect(.degrees(p.value * -14), axis: (1, 0, 0)) }
            }
        }
    }
    private func run(_ f: @escaping @Sendable () -> [Ticket]) {
        busy = true
        Task {
            let l = await Task.detached(priority: .userInitiated, operation: f).value
            busy = false
            let new = l.filter { t in t.payload == nil || !store.tickets.contains { $0.payload == t.payload } }
            if l.isEmpty { Haptic.warn(); store.say("Aucun code trouvé") } else if new.isEmpty { Haptic.warn(); store.say("Déjà dans tes billets") } else { Haptic.ok(); drafts = Drafts(list: new) }
        }
    }
    private func unlock() {
        let c = LAContext()
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { unlocked = true; return }   // aucun code sur l’iPhone
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Afficher tes billets") { ok, _ in Task { @MainActor in withAnimation { unlocked = ok } } }
    }
}
struct Scanner: UIViewControllerRepresentable {
    let found: (String?, String) -> Void
    final class C: NSObject, DataScannerViewControllerDelegate {
        let found: (String?, String) -> Void
        var done = false
        init(_ f: @escaping (String?, String) -> Void) { found = f }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if !done, let p = b.payloadStringValue { done = true; s.stopScanning(); found(p, Code.name(b.observation.symbology)); return } }
        }
    }
    func makeCoordinator() -> C { C(found) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let v = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .accurate, isHighlightingEnabled: true)
        v.delegate = context.coordinator
        return v
    }
    func updateUIViewController(_ v: DataScannerViewController, context: Context) { if !context.coordinator.done { try? v.startScanning() } }
}

// MARK: Billet en grand, luminosité maximale
struct TicketSheet: View {
    @State var ticket: Ticket
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var before: CGFloat?
    @State private var use = false
    @State private var del = false
    @State private var edit = false
    private var t: Ticket { store.tickets.first { $0.id == ticket.id } ?? ticket }
    private var screen: UIScreen? { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CodeView(t: t).opacity(t.used ? 0.25 : 1).overlay { if t.used { Text("UTILISÉ").font(.largeTitle.weight(.black)).foregroundStyle(Color.rose).rotationEffect(.degrees(-14)) } }
                    Text(t.title).font(.title2.bold())
                    if !t.number.isEmpty { Text(t.number).font(.system(.title2, design: .monospaced, weight: .semibold)).textSelection(.enabled).multilineTextAlignment(.center) }
                    VStack(alignment: .leading, spacing: 10) {
                        if !t.pin.isEmpty { LabeledContent("Code PIN", value: t.pin) }
                        if let u = t.until { LabeledContent("Valable jusqu’au", value: Jour.fmt(u, "d MMMM yyyy")) }
                        if t.prepaid { LabeledContent("Places restantes", value: "\(t.left) sur \(t.total)") }
                        if let s = t.seance { LabeledContent("Séance", value: Jour.jolie(Jour.cine(s)) + " à " + Jour.heure(s)) }
                        if !t.place.isEmpty { LabeledContent("Cinéma", value: t.place) }
                        if !t.seat.isEmpty { LabeledContent("Siège", value: t.seat) }
                        if let u = t.usedAt { LabeledContent("Utilisé le", value: Jour.fmt(u, "d MMMM yyyy")) }
                    }.card()
                    if !t.number.isEmpty { Button { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: t.number]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(900)]); Haptic.ok(); store.say("Code copié") } label: { Label("Copier le code", systemImage: "doc.on.doc").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass) }
                    if t.used || t.left < t.total { Button { store.restore(t) } label: { Text("Remettre une place").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.glass) }
                    if !t.used { Button { use = true } label: { Text(t.total > 1 ? "Utiliser une place" : "Marquer comme utilisé").frame(maxWidth: .infinity).frame(height: 34).foregroundStyle(.black) }.buttonStyle(.glassProminent).tint(.or) }
                }.padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fermer", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Menu { Button("Modifier", systemImage: "pencil") { edit = true }; Button("Supprimer", systemImage: "trash", role: .destructive) { del = true } } label: { Image(systemName: "ellipsis") } }
            }
        }
        .confirmationDialog("Confirmer : place utilisée ?", isPresented: $use, titleVisibility: .visible) { Button("Oui, utilisée") { store.useOne(t) } }
        .confirmationDialog("Supprimer définitivement ce billet ?", isPresented: $del, titleVisibility: .visible) { Button("Supprimer", role: .destructive) { store.delete(t); dismiss() } }
        .sheet(isPresented: $edit) { ImportReview(drafts: [t], editing: true) }
        .onAppear { light(true) }.onDisappear { light(false) }
        .onChange(of: phase) { _, p in light(p == .active) }
    }
    private func light(_ on: Bool) {
        guard let screen else { return }
        if on { if before == nil { before = screen.brightness }; screen.brightness = 1 } else if let b = before { screen.brightness = b; before = nil }
    }
}

// MARK: Vérification avant enregistrement
struct ImportReview: View {
    @State var drafts: [Ticket]
    var editing = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                ForEach($drafts) { $t in
                    Section {
                        if t.payload != nil || t.image != nil { HStack { Spacer(); CodeView(t: t).scaleEffect(0.5).frame(width: 160, height: 160); Spacer() } }
                        Picker("Type", selection: $t.prepaid) { Text("Carte ou chèque prépayé").tag(true); Text("Billet de séance").tag(false) }
                        Picker("Enseigne", selection: $t.brand) { ForEach(Brand.allCases) { Text($0.label).tag($0) } }
                        TextField("Nom (ex. CinéCarte)", text: $t.name)
                        TextField("Code", text: $t.number).fontDesign(.monospaced).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        if t.prepaid {
                            TextField("Code PIN (facultatif)", text: $t.pin).keyboardType(.numberPad)
                            OptionalDate(title: "Date d’expiration", date: $t.until, parts: .date)
                            Stepper("Places : \(t.total)", value: Binding { t.total } set: { n in let usedUp = t.total - t.left; t.total = n; t.left = max(0, n - usedUp); t.usedAt = t.left == 0 ? (t.usedAt ?? .now) : nil }, in: 1...50)
                        } else {
                            TextField("Film", text: $t.film); TextField("Cinéma", text: $t.place); TextField("Siège", text: $t.seat)
                            OptionalDate(title: "Séance", date: $t.seance, parts: [.date, .hourAndMinute])
                        }
                        if t.payload == nil && t.image == nil && !t.number.isEmpty { Button("Créer un QR avec ce code", systemImage: "qrcode") { t.payload = t.number; t.symbology = "QR" } }
                        if drafts.count > 1 { Button("Ne pas importer", role: .destructive) { drafts.removeAll { $0.id == t.id } } }
                    } footer: { if t.prepaid { Text("Vérifie le code et la date avant d’enregistrer.") } }
                }
            }
            .navigationTitle(editing ? "Modifier" : drafts.count > 1 ? "\(drafts.count) billets trouvés" : "Nouveau billet").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer", systemImage: "checkmark") { for t in drafts { store.upsert(t) }; Haptic.ok(); if !editing { store.say(drafts.count > 1 ? "\(drafts.count) billets ajoutés" : "Billet ajouté") }; dismiss() }.disabled(drafts.contains { $0.payload == nil && $0.image == nil && $0.number.isEmpty }) }
            }
        }.interactiveDismissDisabled()
    }
}
struct OptionalDate: View {
    let title: String
    @Binding var date: Date?
    let parts: DatePickerComponents
    var body: some View {
        Toggle(title, isOn: Binding { date != nil } set: { date = $0 ? .now : nil })
        if date != nil { DatePicker("Le", selection: Binding { date ?? .now } set: { date = $0 }, displayedComponents: parts).environment(\.timeZone, Jour.paris) }
    }
}
