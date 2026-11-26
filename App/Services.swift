import Foundation
import CryptoKit
import Security
import Observation
import CoreLocation
import Vision
import UIKit

// MARK: Trousseau
enum Trousseau {
    private static let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "moncine", kSecAttrAccount as String: "tmdb"]
    static func read() -> String? {
        var o: AnyObject?
        if SecItemCopyMatching(q.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &o) == errSecSuccess, let d = o as? Data { return String(data: d, encoding: .utf8) }
        return UserDefaults.standard.string(forKey: "tmdb")   // signature sans trousseau
    }
    static func write(_ v: String?) {
        SecItemDelete(q as CFDictionary); UserDefaults.standard.removeObject(forKey: "tmdb")
        guard let v, !v.isEmpty else { return }
        let s = SecItemAdd(q.merging([kSecValueData as String: Data(v.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil)
        if s != errSecSuccess { UserDefaults.standard.set(v, forKey: "tmdb") }
    }
}

// MARK: Cache disque
enum Disk {
    static let dir: URL = { let u = URL.cachesDirectory.appending(path: "data"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }()
    static func url(_ key: String) -> URL { dir.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()) }
    static func read(_ key: String) -> (data: Data, age: TimeInterval)? {
        let u = url(key)
        guard let d = try? Data(contentsOf: u), let m = try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date else { return nil }
        return (d, -m.timeIntervalSinceNow)
    }
    static func write(_ key: String, _ d: Data) { try? d.write(to: url(key), options: .atomic) }
    static func purge(days: Double = 14) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, -m.timeIntervalSinceNow > days * 86400 { try? FileManager.default.removeItem(at: f) }
        }
    }
    static func clear() { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
}

// MARK: TMDB
typealias J = [String: Any]
enum TMDB {
    static let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    static func img(_ p: String?, _ w: Int) -> URL? {
        guard let p, !p.isEmpty else { return nil }
        if p.hasPrefix("https://images.justwatch.com") { return URL(string: w >= 500 ? p.replacingOccurrences(of: "/s332/", with: "/s718/") : w <= 200 ? p.replacingOccurrences(of: "/s332/", with: "/s166/").replacingOccurrences(of: "/s1440/", with: "/s640/") : w <= 342 ? p.replacingOccurrences(of: "/s1440/", with: "/s640/") : p) }
        return p.hasPrefix("https://") ? URL(string: p) : URL(string: "https://image.tmdb.org/t/p/w\(w)\(p)")
    }
    static func get(_ path: String, _ params: [String: String] = [:], ttl: Double, key override: String? = nil) async throws -> J {
        if demo { return Demo.tmdb(path, params) }
        let all = ["language": "fr-FR", "region": "FR"].merging(params) { $1 }
        let id = path + "?" + all.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        let old = override == nil ? Disk.read(id) : nil
        func decode(_ d: Data) -> J? { (try? JSONSerialization.jsonObject(with: d)) as? J }
        if let old, old.age < ttl, let j = decode(old.data) { return j }
        do {
            guard let key = (override ?? Trousseau.read())?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw Oops("Ajoute ta clé TMDB dans les réglages") }
            let v4 = key.hasPrefix("eyJ")
            var c = URLComponents(string: "https://api.themoviedb.org/3" + path)!
            c.queryItems = (v4 ? all : all.merging(["api_key": key]) { $1 }).map { URLQueryItem(name: $0.key, value: $0.value) }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            var r = URLRequest(url: c.url!, timeoutInterval: 12)
            if v4 { r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            let res: (Data, URLResponse)
            do { res = try await URLSession.shared.data(for: r) } catch is CancellationError { throw CancellationError() } catch { if Task.isCancelled { throw CancellationError() }; throw Oops("Connexion impossible à TMDB") }
            switch (res.1 as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 401: throw Oops("Clé TMDB refusée")
            case 404: throw Oops("Fiche introuvable")
            case let s: throw Oops("TMDB a répondu avec l’erreur \(s)")
            }
            guard let j = decode(res.0) else { throw Oops("Réponse TMDB illisible") }
            Disk.write(id, res.0)
            return j
        } catch { if let old, let j = decode(old.data) { return j }; throw error }
    }
    static func film(_ j: J) -> Film? {
        let media = j["media_type"] as? String
        guard media != "person", let id = j["id"] as? Int, let t = (j["title"] ?? j["name"]) as? String else { return nil }
        let tv = media == "tv" || (media == nil && j["title"] == nil)
        return Film(id: tv ? -id : id, title: t, release: (tv ? j["first_air_date"] : j["release_date"]) as? String ?? "", poster: j["poster_path"] as? String, back: j["backdrop_path"] as? String,
                    note: (j["vote_count"] as? Int ?? 0) > 20 ? j["vote_average"] as? Double : nil, overview: j["overview"] as? String ?? "")
    }
    static func list(_ path: String, _ params: [String: String] = [:], page: Int = 1, ttl: Double = 43200) async throws -> [Film] {
        let j = try await get(path, params.merging(["page": "\(page)"]) { $1 }, ttl: ttl)
        var seen = Set<Int>()
        return ((j["results"] as? [J]) ?? []).compactMap(film).filter { seen.insert($0.id).inserted }
    }
    static func search(_ q: String) async throws -> [Film] {
        async let a = list("/search/multi", ["query": q, "include_adult": "false"], page: 1, ttl: 86400)
        async let b = list("/search/multi", ["query": q, "include_adult": "false"], page: 2, ttl: 86400)
        var seen = Set<Int>()
        let l = (try await a + b).filter { seen.insert($0.id).inserted }
        return l.filter { $0.poster != nil } + l.filter { $0.poster == nil }
    }
    static func people(_ q: String) async throws -> [Person] {
        let j = try await get("/search/person", ["query": q, "include_adult": "false"], ttl: 86400)
        return ((j["results"] as? [J]) ?? []).compactMap { x in
            guard let i = x["id"] as? Int, let n = x["name"] as? String, let p = x["profile_path"] as? String else { return nil }
            return Person(id: i, name: n, role: x["known_for_department"] as? String == "Directing" ? "Director" : "", photo: p)
        }
    }
    static func detail(_ id: Int) async throws -> FilmDetail {
        let tv = id < 0
        let j = try await get((tv ? "/tv/" : "/movie/") + String(abs(id)), ["append_to_response": "credits,videos,watch/providers,recommendations,images,translations", "include_video_language": "fr,en", "include_image_language": "fr,en,ja,ko,es,it,de,zh,null"], ttl: 3 * 86400)
        guard let f = film(j) else { throw Oops("Fiche introuvable") }
        var d = FilmDetail(film: f)
        let ot = (j["original_title"] ?? j["original_name"]) as? String ?? ""
        d.original = ot == f.title ? "" : ot
        d.runtime = (j["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        d.tagline = j["tagline"] as? String ?? ""
        d.votes = j["vote_count"] as? Int ?? 0
        d.genres = ((j["genres"] as? [J]) ?? []).compactMap { $0["name"] as? String }
        let cr = j["credits"] as? J
        func people(_ l: [J], _ role: String) -> [Person] { l.compactMap { x in (x["id"] as? Int).map { Person(id: $0, name: x["name"] as? String ?? "", role: x[role] as? String ?? "", photo: x["profile_path"] as? String) } } }
        d.directors = people(((cr?["crew"] as? [J]) ?? []).filter { $0["job"] as? String == "Director" }, "job")
        if tv {
            d.directors = people((j["created_by"] as? [J]) ?? [], "job").map { var p = $0; p.role = "Création"; return p }
            d.runtime = (j["episode_run_time"] as? [Int])?.first ?? (j["last_episode_to_air"] as? J)?["runtime"] as? Int
            d.saisons = ((j["seasons"] as? [J]) ?? []).compactMap { s in
                guard let n = s["season_number"] as? Int, n > 0, let k = s["episode_count"] as? Int, k > 0 else { return nil }
                return Saison(id: n, nom: s["name"] as? String ?? "Saison \(n)", nb: k, date: s["air_date"] as? String ?? "")
            }
            d.prochain = (j["next_episode_to_air"] as? J)?["air_date"] as? String
            d.fini = ["Ended", "Canceled"].contains(j["status"] as? String ?? "")
        }
        d.cast = people(Array(((cr?["cast"] as? [J]) ?? []).prefix(20)), "character")
        func score(_ v: J) -> Int { (v["iso_639_1"] as? String == "fr" ? 8 : 0) + (v["type"] as? String == "Trailer" ? 4 : 0) + (v["official"] as? Bool == true ? 2 : 0) }
        d.trailer = (((j["videos"] as? J)?["results"] as? [J]) ?? []).filter {
            $0["site"] as? String == "YouTube" && ["Trailer", "Teaser"].contains($0["type"] as? String ?? "") && ($0["key"] as? String ?? "").wholeMatch(of: /[\w-]{6,20}/) != nil
        }.max { (score($0), $0["published_at"] as? String ?? "") < (score($1), $1["published_at"] as? String ?? "") }?["key"] as? String
        // « Aucune langue » sur TMDB : images sans texte, la mieux votée d’abord
        func clean(_ k: String) -> String? {
            let l = (((j["images"] as? J)?[k] as? [J]) ?? []).filter { $0["iso_639_1"] == nil || $0["iso_639_1"] is NSNull }
            return l.max { ($0["vote_average"] as? Double ?? 0, $0["vote_count"] as? Int ?? 0) < ($1["vote_average"] as? Double ?? 0, $1["vote_count"] as? Int ?? 0) }?["file_path"] as? String
        }
        d.cleanPoster = clean("posters"); d.cleanBack = clean("backdrops")
        d.logo = await logo(j, titre: f.title)
        if let c = j["belongs_to_collection"] as? J, let i = c["id"] as? Int { d.saga = Saga(id: i, nom: Self.nomSaga(c["name"] as? String ?? "")) }
        d.libre = libre(j, id)
        if let w = ((j["watch/providers"] as? J)?["results"] as? J)?["FR"] as? J {
            func prov(_ k: String) -> [Provider] { ((w[k] as? [J]) ?? []).compactMap(provider) }
            d.stream = prov("flatrate"); d.free = prov("free") + prov("ads"); d.rent = prov("rent"); d.buy = prov("buy")
            d.watchLink = (w["link"] as? String).flatMap(URL.init)
        }
        d.similar = (((j["recommendations"] as? J)?["results"] as? [J]) ?? []).compactMap(film)
        return d
    }
    /// Film entier publié gratuitement par ses auteurs : lien connu, ou site officiel de la fiche TMDB quand c’est une vidéo
    private static let publies = [1716849: "https://www.youtube.com/watch?v=OCO9W9VPPc0"]
    static func libre(_ j: J, _ id: Int) -> URL? {
        let tr = ((j["translations"] as? J)?["translations"] as? [J]) ?? []
        for s in [publies[id] ?? "", j["homepage"] as? String ?? ""] + tr.compactMap({ ($0["data"] as? J)?["homepage"] as? String }) {
            guard let u = URL(string: s), ["https", "http"].contains(u.scheme ?? ""), let h = u.host()?.replacingOccurrences(of: "www.", with: "") else { continue }
            let p = u.path()
            let video = (h == "youtu.be" && p.count > 8) || (h.hasSuffix("youtube.com") && p == "/watch") || (h == "vimeo.com" && p.dropFirst().allSatisfy(\.isNumber) && p.count > 5) || (h == "dailymotion.com" && p.hasPrefix("/video/"))
            if video { return u }
        }
        return nil
    }
    /// Logos dans l’ordre de préférence. Film non traduit en France : logo d’origine. Film traduit : logo français, jamais le québécois.
    static func logos(_ j: J, titre: String) -> (sur: [String], douteux: [String], quebec: String) {
        let l = (((j["images"] as? J)?["logos"] as? [J]) ?? []).filter { !(($0["file_path"] as? String)?.hasSuffix(".svg") ?? true) }
        let tr = ((j["translations"] as? J)?["translations"] as? [J]) ?? []
        func t(_ lang: String, _ pays: String?) -> String {
            let d = tr.first { $0["iso_639_1"] as? String == lang && (pays == nil || $0["iso_3166_1"] as? String == pays) }?["data"] as? J
            return (d?["title"] ?? d?["name"]) as? String ?? ""
        }
        func pris(_ lang: String?, _ ok: (String) -> Bool = { _ in true }) -> [String] {
            l.filter { x in (x["iso_639_1"] as? String) == lang && ok(x["iso_3166_1"] as? String ?? "") }.compactMap { $0["file_path"] as? String }
        }
        let ol = j["original_language"] as? String ?? "en", original = (j["original_title"] ?? j["original_name"]) as? String ?? ""
        let anglais = ol == "en" ? original : t("en", "US").isEmpty ? t("en", nil) : t("en", "US"), quebec = t("fr", "CA"), nous = Match.plat(titre)
        let q = Match.plat(quebec).isEmpty || Match.plat(quebec) == nous ? "" : quebec
        let fr = pris("fr") { $0 == "FR" }, flou = pris("fr") { $0 != "FR" && $0 != "CA" }
        if ol == "fr" { return (fr + flou + pris(nil) + pris("en"), [], "") }
        if nous == Match.plat(anglais) { return (pris("en") + fr + pris(nil), q.isEmpty ? flou : [], q) }
        if nous == Match.plat(original) { return (pris(ol) + fr + pris(nil), q.isEmpty ? flou : [], q) }
        return q.isEmpty ? (fr + flou, [], "") : (fr, flou, q)
    }
    /// Un logo français de pays inconnu est lu : s’il porte le titre québécois, il est écarté
    private static func logo(_ j: J, titre: String) async -> String? {
        let c = logos(j, titre: titre)
        if let p = c.sur.first { return p }
        for p in c.douteux.prefix(4) {
            let key = "ocr:" + p
            var lu = Disk.read(key).flatMap { String(data: $0.data, encoding: .utf8) }
            if lu == nil, !demo, let u = img(p, 500), let (data, _) = try? await URLSession.shared.data(from: u) {
                let texte = lire(data)
                Disk.write(key, Data(texte.utf8)); lu = texte
            }
            if !quebecois(lu ?? "", titre, c.quebec) { return p }
        }
        return nil
    }
    private static func lire(_ d: Data) -> String {
        guard let im = UIImage(data: d) else { return "" }
        // Logo transparent : posé sur fond gris pour que Vision distingue un texte blanc comme un texte noir
        let r = UIGraphicsImageRenderer(size: CGSize(width: im.size.width + 40, height: im.size.height + 40)).image { c in
            UIColor(white: 0.45, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: im.size.width + 40, height: im.size.height + 40)); im.draw(at: CGPoint(x: 20, y: 20))
        }
        guard let cg = r.cgImage else { return "" }
        let q = VNRecognizeTextRequest(); q.recognitionLanguages = ["fr-FR", "en-US"]
        try? VNImageRequestHandler(cgImage: cg).perform([q])
        return (q.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    /// Le texte lu ressemble davantage au titre québécois qu’au titre français
    static func quebecois(_ lu: String, _ fr: String, _ qc: String) -> Bool {
        let l = Set(Match.plat(lu).split(separator: " ")), a = Set(Match.plat(fr).split(separator: " ")), b = Set(Match.plat(qc).split(separator: " "))
        return l.intersection(b.subtracting(a)).count > l.intersection(a.subtracting(b)).count
    }
    static func nomSaga(_ n: String) -> String { n.replacingOccurrences(of: "\\s*[-–:(\\[]*\\s*(saga|collection|la collection|la saga|la série)[)\\]]*\\s*$", with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces) }
    /// Films d’une saga, dans l’ordre de sortie
    static func saga(_ id: Int) async throws -> [Film] {
        let j = try await get("/collection/\(id)", ttl: 7 * 86400)
        return ((j["parts"] as? [J]) ?? []).compactMap(film).filter { $0.poster != nil }.sorted { ($0.release.isEmpty ? "9" : $0.release) < ($1.release.isEmpty ? "9" : $1.release) }
    }
    /// Saga célèbre : numéro connu s’il correspond bien au mot attendu, sinon recherche
    static func saga(_ id: Int, mot: String) async -> [Film] {
        let m = Match.plat(mot)
        if let j = try? await get("/collection/\(id)", ttl: 7 * 86400) {
            let t = ([j["name"] as? String ?? ""] + ((j["parts"] as? [J]) ?? []).flatMap { [$0["title"] as? String ?? "", $0["original_title"] as? String ?? ""] }).map(Match.plat)
            if t.contains(where: { (" " + $0 + " ").contains(" " + m + " ") }), let l = try? await saga(id), l.count > 1 { return l }
        }
        guard let j = try? await get("/search/collection", ["query": mot], ttl: 30 * 86400) else { return [] }
        let r = (j["results"] as? [J]) ?? []
        let c = r.first { (" " + Match.plat($0["name"] as? String ?? "") + " ").contains(" " + m + " ") }
        guard let i = c?["id"] as? Int else { return [] }
        return (try? await saga(i)) ?? []
    }
    /// Films d’une personne : réalisés, ou joués, les plus vus d’abord
    static func filmographie(_ nom: String, joue: Bool) async -> [Film] {
        guard let p = (try? await people(nom))?.first(where: { Match.plat($0.name) == Match.plat(nom) }), let j = try? await get("/person/\(p.id)/movie_credits", ttl: 7 * 86400) else { return [] }
        let l = (j[joue ? "cast" : "crew"] as? [J] ?? []).filter { joue ? ($0["order"] as? Int ?? 99) < 6 : $0["job"] as? String == "Director" }
        var vus = Set<Int>()
        return l.sorted { ($0["vote_count"] as? Int ?? 0) > ($1["vote_count"] as? Int ?? 0) }.compactMap(film).filter { $0.poster != nil && vus.insert($0.id).inserted }.prefix(40).map { $0 }
    }
    static func saison(_ id: Int, _ n: Int) async throws -> [Episode] {
        let j = try await get("/tv/\(abs(id))/season/\(n)", ttl: 86400)
        return ((j["episodes"] as? [J]) ?? []).compactMap { e in
            guard let i = e["id"] as? Int, let k = e["episode_number"] as? Int else { return nil }
            return Episode(id: i, n: k, titre: e["name"] as? String ?? "Épisode \(k)", texte: e["overview"] as? String ?? "", date: e["air_date"] as? String ?? "", min: e["runtime"] as? Int, image: e["still_path"] as? String)
        }
    }
    static func provider(_ x: J) -> Provider? { (x["provider_id"] as? Int).map { Provider(id: $0, name: x["provider_name"] as? String ?? "", logo: x["logo_path"] as? String) } }
    static func providers() async throws -> [Provider] {
        let j = try await get("/watch/providers/movie", ["watch_region": "FR"], ttl: 7 * 86400)
        func rank(_ x: J) -> Int { ((x["display_priorities"] as? J)?["FR"] as? Int) ?? 999 }
        return Array(((j["results"] as? [J]) ?? []).sorted { rank($0) < rank($1) }.compactMap(provider).prefix(50))
    }
    /// AlloCiné → fiche TMDB ; les versions longues ou restaurées mènent à l’œuvre d’origine
    static func resolve(_ f: ACFilm) async throws -> Film? {
        if let i = await Registre.shared.tmdb(ac: f.movie, base: true), let d = try? await detail(i) { return d.film }
        let v = Match.version(f.title)
        var essais: [String] = []
        for t in Match.variantes(f.title) + (f.original.isEmpty ? [] : Match.variantes(f.original)) where !essais.contains(t) { essais.append(t) }
        for t in essais {
            let j = try await get("/search/movie", ["query": t, "include_adult": "false", "page": "1"], ttl: 7 * 86400)
            let ok = ((j["results"] as? [J]) ?? []).compactMap { x -> (Film, Double, Int)? in
                guard let m = film(x), Match.same(title: m.title, original: x["original_title"] as? String ?? "", year: Int(m.year), f) else { return nil }
                return (m, x["popularity"] as? Double ?? 0, v ? 0 : f.year.flatMap { y in Int(m.year).map { abs($0 - y) } } ?? 0)
            }
            if let b = ok.min(by: { ($0.2, -$0.1) < ($1.2, -$1.1) }) {
                if v { Alias.noter(b.0.id, f.movie) }
                return b.0
            }
        }
        // Titre introuvable : le numéro AlloCiné, connu de la base ou de Wikidata, désigne la fiche
        if let i = await Registre.shared.tmdb(ac: f.movie), let d = try? await detail(i) { return d.film }
        return nil
    }
}
/// Fiches AlloCiné reconnues comme une autre version d’un film
enum Alias {
    static func lire(_ id: Int) -> [Int] { (UserDefaults.standard.dictionary(forKey: "alias") as? [String: [Int]])?[String(id)] ?? [] }
    static func noter(_ id: Int, _ ac: Int) {
        var d = UserDefaults.standard.dictionary(forKey: "alias") as? [String: [Int]] ?? [:]
        if d[String(id)]?.contains(ac) != true { d[String(id), default: []].append(ac); UserDefaults.standard.set(d, forKey: "alias") }
    }
}

/// Ouvre le film chez un service : TMDB ne donne pas l’adresse exacte, on lance donc la recherche du titre dans le service.
enum Stream {
    static func url(_ p: Provider, _ title: String) -> URL? {
        let q = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", n = p.name.lowercased()
        // Les « chaînes » vendues par Amazon ou Apple s’ouvrent chez eux
        let table: [(String, String)] = [
            ("amazon", "https://www.primevideo.com/search?phrase="), ("prime video", "https://www.primevideo.com/search?phrase="), ("apple", "https://tv.apple.com/fr/search?term="),
            ("netflix", "https://www.netflix.com/search?q="), ("disney", "https://www.disneyplus.com/fr-fr/browse/search?q="), ("hbo", "https://play.hbomax.com/search/result?q="),
            ("canal", "https://www.canalplus.com/rechercher?q="), ("paramount", "https://www.paramountplus.com/fr/search/?q="), ("arte", "https://www.arte.tv/fr/search/?q="),
            ("france", "https://www.france.tv/recherche/?q="), ("tf1", "https://www.tf1.fr/recherche?q="), ("youtube", "https://www.youtube.com/results?search_query="),
            ("google", "https://play.google.com/store/search?c=movies&q="), ("rakuten", "https://rakuten.tv/fr/search?q="), ("crunchyroll", "https://www.crunchyroll.com/fr/search?q="),
            ("mubi", "https://mubi.com/fr/search/films?query="), ("plex", "https://watch.plex.tv/search?q="), ("universcin", "https://www.universcine.com/recherche?q="),
        ]
        return table.first { n.contains($0.0) }.flatMap { URL(string: $0.1 + q) }
    }
}

// MARK: AlloCiné (source non officielle, usage personnel modéré)
actor AlloCine {
    static let shared = AlloCine()
    private var recent: [Date] = [], pause = Date.distantPast, last = Date.distantPast, inflight: [String: Task<Programme, Error>] = [:]

    var pauseFinie: Bool { pause < .now }
    func programme(_ id: String, _ day: String, fresh: Bool = false) async throws -> Programme {
        let key = "ac2:\(id):\(day)"
        if TMDB.demo { return Demo.programme(id, day) }
        let old = Disk.read(key).flatMap { d in (try? JSONDecoder().decode(Programme.self, from: d.data)).map { ($0, d.age) } }
        if let old, old.1 < (old.0.partial ? 600 : Self.ttl(day, .now)), !(fresh && old.1 > 1800) { return old.0 }
        if let t = inflight[key] { return try await t.value }
        let t = Task { try await self.load(id, day) }
        inflight[key] = t
        defer { inflight[key] = nil }
        do {
            let p = try await t.value
            if let d = try? JSONEncoder().encode(p) { Disk.write(key, d) }
            return p
        } catch { if var p = old?.0 { p.stale = true; return p }; throw error }
    }
    /// Semaine de cinéma du mercredi au mardi : grilles en cours 24 h, suivantes 6 ou 14 h.
    static func ttl(_ day: String, _ now: Date) -> Double {
        let dow = Jour.cal.component(.weekday, from: now) - 1            // 0 = dimanche
        let fin = Jour.shift(Jour.iso(now), (2 - dow + 7) % 7)
        return (day <= fin ? 24 : (1...3).contains(dow) ? 6 : 14) * 3600
    }
    private func page(_ id: String, _ day: String, _ n: Int) async throws -> J {
        let j = try await fetch("showtimes/theater-\(id)/d-\(day)/p-\(n)/")
        guard j["results"] is [Any] else { throw Oops("Le format d’AlloCiné a changé") }
        return j
    }
    func fetch(_ path: String) async throws -> J {
        // Une demande à la fois : le créneau est réservé avant d’attendre (les acteurs sont réentrants)
        let now = Date.now
        if pause > now { throw Oops("AlloCiné demande une pause, réessaie dans un quart d’heure", quota: true) }
        recent.removeAll { now.timeIntervalSince($0) > 60 }
        if recent.count >= 20 { throw Oops("Trop de séances demandées d’un coup, réessaie dans une minute", quota: true) }
        let k = "ac-" + Jour.iso(now), today = UserDefaults.standard.integer(forKey: k)
        if today >= 400 { throw Oops("Trop de demandes aujourd’hui, réessaie demain", quota: true) }
        let slot = max(now, last.addingTimeInterval(1.5))
        last = slot; recent.append(slot); UserDefaults.standard.set(today + 1, forKey: k)
        if slot > now { try await Task.sleep(for: .seconds(slot.timeIntervalSince(now))) }
        if pause > .now { throw Oops("AlloCiné demande une pause, réessaie dans un quart d’heure", quota: true) }
        var r = URLRequest(url: URL(string: "https://www.allocine.fr/_/\(path)")!, timeoutInterval: 14)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("mon-cine-perso/1.0", forHTTPHeaderField: "User-Agent")
        let res: (Data, URLResponse)
        do { res = try await URLSession.shared.data(for: r) } catch { throw Oops("AlloCiné ne répond pas") }
        switch (res.1 as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 403, 429: pause = .now.addingTimeInterval(900); throw Oops("AlloCiné demande une pause, réessaie dans un quart d’heure", quota: true)
        case 404: throw Oops("Cinéma introuvable")
        case let s: throw Oops("AlloCiné a répondu avec l’erreur \(s)")
        }
        guard let j = (try? JSONSerialization.jsonObject(with: res.0)) as? J else { throw Oops("Le format d’AlloCiné a changé") }
        return j
    }
    private func load(_ id: String, _ day: String) async throws -> Programme {
        var out = Programme(), films: [ACFilm] = [], n = 1, total = 1
        while n <= total {
            if n > 5 { out.partial = true; break }
            let j: J
            do { j = try await page(id, day, n) } catch { if n == 1 { throw error }; out.partial = true; break }
            if n == 1 { out.next = (j["nextDate"] as? String).map { String($0.prefix(10)) }; total = (j["pagination"] as? J)?["totalPages"] as? Int ?? 1 }
            for x in j["results"] as? [J] ?? [] {
                guard let f = Self.film(x) else { continue }
                if let i = films.firstIndex(where: { $0.movie == f.movie }) { films[i].seances += f.seances.filter { s in !films[i].seances.contains { $0.id == s.id } } } else { films.append(f) }
            }
            n += 1
        }
        out.films = Self.day(films, day)
        return out
    }
    /// AlloCiné donne la vraie date des séances de nuit ; elles restent rangées sous la veille.
    static func day(_ films: [ACFilm], _ day: String) -> [ACFilm] {
        films.map { f in
            var f = f
            f.seances = f.seances.filter { $0.day == day || Jour.iso($0.start) == day }.map { s in
                var s = s
                if s.day < day { s.label = "Nuit du \(Int(s.day.suffix(2)) ?? 0) au \(Int(day.suffix(2)) ?? 0)" }
                return s
            }.sorted { $0.start < $1.start }
            return f
        }.filter { !$0.seances.isEmpty }.sorted { ($1.seances.count, $0.title) < ($0.seances.count, $1.title) }
    }
    static func film(_ x: J) -> ACFilm? {
        guard let m = x["movie"] as? J, let id = m["internalId"] as? Int else { return nil }
        let rt = (m["runtime"] as? String ?? "").firstMatch(of: /(\d+)\s*h\s*(\d+)/).flatMap { a in Int(a.1).flatMap { h in Int(a.2).map { h * 60 + $0 } } }
        let runtime = rt == 0 ? nil : rt
        let py = (m["data"] as? J)?["productionYear"] as? Int
        let rel = ((m["releases"] as? [J]) ?? []).compactMap { (($0["releaseDate"] as? J)?["date"] as? String).flatMap { Int($0.prefix(4)) } }
        let credits = m["credits"] as? [J] ?? (m["credits"] as? J)?["nodes"] as? [J] ?? []
        var seen = Set<String>(), seances: [Seance] = []
        for (g, l) in ((x["showtimes"] as? J) ?? [:]).sorted(by: { ($0.key.contains("_") ? 0 : 1, $0.key) < ($1.key.contains("_") ? 0 : 1, $1.key) }) {
            for s in l as? [J] ?? [] { if let z = seance(s, g, runtime), seen.insert(z.id).inserted { seances.append(z) } }
        }
        let p = (m["poster"] as? J)?["url"] as? String
        return ACFilm(movie: id, title: m["title"] as? String ?? "Film", original: m["originalTitle"] as? String ?? "", years: Array(Set(([py].compactMap { $0 }) + rel)), year: py, runtime: runtime,
                      genres: ((m["genres"] as? [J]) ?? []).compactMap { $0["translate"] as? String },
                      director: credits.filter { ($0["position"] as? J)?["name"] as? String == "DIRECTOR" }.compactMap { c in (c["person"] as? J).map { p in [p["firstName"] as? String, p["lastName"] as? String].compactMap { $0 }.joined(separator: " ") } }.joined(separator: ", "),
                      poster: p?.hasPrefix("https://") == true ? p : nil, seances: seances)
    }
    static func seance(_ s: J, _ group: String, _ runtime: Int?) -> Seance? {
        guard let id = s["internalId"] as? Int, let start = (s["startsAt"] as? String).flatMap(Jour.local) else { return nil }
        let tags = s["tags"] as? [String] ?? [], gst = group.hasSuffix("_st") || group.hasSuffix("_sme")
        let st = gst || tags.contains("Localization.Subtitle.French") || tags.contains("Showtime.Accessibility.Subtitled")
        var f = tags.filter { $0.hasPrefix("Format.") && $0 != "Format.Projection.Digital" }.map { String($0.split(separator: ".").last ?? "") }
        for k in ["experience", "comfort", "picture", "sound"] { f += s[k] as? [String] ?? (s[k] as? String).map { [$0] } ?? [] }
        var fs: [String] = []
        for x in f { let l = formats[x.lowercased()] ?? x; if !l.isEmpty, !fs.contains(l) { fs.append(l) } }
        func rank(_ t: J) -> Int { (t["type"] as? String == "DESKTOP" ? 0 : 10) + (t["provider"] as? String == "default" ? 0 : t["provider"] as? String == "relay" ? 5 : 2) }
        let url = (((s["data"] as? J)?["ticketing"] as? [J]) ?? []).sorted { rank($0) < rank($1) }.compactMap { ($0["urls"] as? [String])?.first }.first { $0.hasPrefix("https://") }
        return Seance(id: String(id), start: start, end: runtime.map { start.addingTimeInterval(Double($0) * 60) },
                      version: s["diffusionVersion"] as? String == "ORIGINAL" ? (st ? "VOST" : "VO") : gst ? "VFST" : "VF", formats: fs, url: url, label: s["isPreview"] as? Bool == true ? "Avant-première" : "")
    }
    static let formats = ["imax": "IMAX", "screen_x": "ScreenX", "screenx": "ScreenX", "e_4dx": "4DX", "4dx": "4DX", "e_4d_emotion": "4D Emotion", "dolby_cinema": "Dolby Cinema", "dolby_atmos": "Dolby Atmos", "dolby_71": "Dolby 7.1", "dolby71": "Dolby 7.1", "infinity_vision": "Infinity Vision", "ice": "ICE", "laser": "Laser", "laser_ultra": "Laser Ultra", "thx": "THX", "3d": "3D", "4k": "4K", "plf": "Grand écran", "luxury": "Fauteuils luxe", "electric_recliner_seats": "Fauteuils inclinables", "recliners": "Fauteuils inclinables", "71": "Son 7.1", "s_71": "Son 7.1", "air_conditioning": "", "dolby_digital": "", "dolbydigital": "", "digital": ""]
}

// MARK: Cinémas et position
enum Salles {
    static let all: [Cinema] = {
        guard let u = Bundle.main.url(forResource: "cinemas", withExtension: "json"), let d = try? Data(contentsOf: u), let l = (try? JSONSerialization.jsonObject(with: d)) as? [[Any]] else { return [] }
        return l.compactMap { x in
            guard x.count >= 5, let id = x[0] as? String, let n = x[1] as? String, let a = x[2] as? String, let la = x[3] as? Double, let lo = x[4] as? Double else { return nil }
            return Cinema(id: id, name: n, address: a, lat: la, lon: lo)
        }
    }()
    private static let index = all.map { Match.plat($0.name + " " + $0.address) }
    static func km(_ c: Cinema, _ p: CLLocationCoordinate2D) -> Double {
        let r = Double.pi / 180, x = (c.lon - p.longitude) * r * cos((c.lat + p.latitude) / 2 * r), y = (c.lat - p.latitude) * r
        return (x * x + y * y).squareRoot() * 6371
    }
    static func search(_ q: String, near p: CLLocationCoordinate2D, max: Int = 60) -> [Cinema] {
        let w = Match.plat(q).split(separator: " ").map(String.init)
        let l = w.isEmpty ? all : all.indices.filter { i in w.allSatisfy(index[i].contains) }.map { all[$0] }
        return Array(l.map { ($0, km($0, p)) }.sorted { $0.1 < $1.1 }.prefix(max).map(\.0))
    }
}
@MainActor @Observable final class Position: NSObject, CLLocationManagerDelegate {
    static let shared = Position()
    var here: CLLocationCoordinate2D?
    @ObservationIgnored private let m = CLLocationManager()
    /// Sans position : premier cinéma favori, sinon le centre de Lyon
    var best: CLLocationCoordinate2D { here ?? Store.shared.cinemas.first.map { .init(latitude: $0.lat, longitude: $0.lon) } ?? .init(latitude: 45.764, longitude: 4.8357) }
    func ask() { m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyKilometer; if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() } else { m.requestLocation() } }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) { manager.requestLocation() } }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations l: [CLLocation]) { let c = l.last?.coordinate; Task { @MainActor in self.here = c } }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
