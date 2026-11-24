import Foundation

/// Données fictives, uniquement avec l’argument de lancement -demo (captures et tests).
enum Demo {
    static let titles = ["La Dernière Bobine", "Nuit d’Ambre", "Le Chant des Marées", "Orbite Zéro", "Rue des Lilas", "L’Horloger de Verre", "Tempête Douce", "Les Invisibles du Quai", "Sable Noir", "Un Été à Contretemps", "Le Grand Silence Bleu", "Mille Soleils"]
    static let films: [J] = titles.enumerated().map { i, t in
        ["id": i + 1, "title": t, "original_title": t, "release_date": i > 8 ? "2027-0\(i - 7)-12" : "2026-11-\(String(format: "%02d", 4 + i))", "vote_average": 8.6 - Double(i) * 0.2, "vote_count": 900, "runtime": 98 + i * 6,
         "overview": "Synopsis fictif : une projectionniste découvre, dans une bobine oubliée, les images d’un film que personne n’a encore tourné.", "genres": [["name": "Drame"], ["name": "Aventure"]], "popularity": 10.0,
         "credits": ["crew": [["id": 900, "job": "Director", "name": "Camille Fictive"]], "cast": (1...5).map { ["id": $0, "name": "Interprète \($0)", "character": "Rôle \($0)"] as J }] as J,
         "videos": ["results": [["site": "YouTube", "type": "Trailer", "key": "simulation1"]]] as J,
         "watch/providers": ["results": ["FR": ["link": "https://www.themoviedb.org", "flatrate": [["provider_id": 8, "provider_name": "Netflix"]], "rent": [["provider_id": 2, "provider_name": "Apple TV"]]] as J]] as J]
    }
    static func tmdb(_ p: String, _ q: [String: String]) -> J {
        if let m = p.wholeMatch(of: /\/movie\/(\d+)/), let i = Int(m.1), var f = films.first(where: { $0["id"] as? Int == i }) { f["recommendations"] = ["results": films]; return f }
        if p.contains("providers") { return ["results": [["provider_id": 8, "provider_name": "Netflix"], ["provider_id": 337, "provider_name": "Disney Plus"]]] }
        if q["page"] == "2" { return ["results": [J]()] }
        if let s = q["query"] { return ["results": films.filter { Match.plat($0["title"] as! String).contains(Match.plat(s)) }] }
        let k = abs(p.unicodeScalars.reduce(q.count) { $0 + Int($1.value) }) % films.count
        return ["results": Array(films[k...] + films[..<k])]
    }
    static func programme(_ id: String, _ day: String) -> Programme {
        Programme(films: films.prefix(6).enumerated().map { i, f in
            let hours: [(Int, String)] = [(14, "VF"), (18, "VOST"), (21, "VOST"), (24, "VF")]
            return ACFilm(movie: 100 + i, title: titles[i], original: titles[i], years: [2026], year: 2026, runtime: 98 + i * 6, genres: ["Drame"], director: "Camille Fictive", poster: nil, seances: hours.enumerated().compactMap { n, h in
                guard let base = Jour.parse(day, "yyyy-MM-dd") else { return nil }
                let s = base.addingTimeInterval(Double(h.0) * 3600 + Double(i) * 300)
                return Seance(id: "\(id)\(day)\(i)\(n)", start: s, end: s.addingTimeInterval(6600), version: h.1, formats: n == 2 ? ["IMAX"] : [], url: "https://example.com/", label: "")
            })
        })
    }
}
