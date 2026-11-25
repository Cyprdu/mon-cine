import Foundation

/// Rapproche un film TMDB d’un titre AlloCiné (ressorties, versions longues, homonymes).
enum Match {
    static func plat(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "&", with: " et ")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    private static let bruit = Set("version versions longue long restauree restaure restauration remasterisee remasterise remaster remastered extended edition speciale special director directors cut final reprise ressortie rediffusion anniversaire ans years anniversary imax 4k 2k 3d 2d 4dx dolby atmos vf vo vost vostf vostfr vfst hd numerique cine club cineclub seance evenement exceptionnelle exceptionnel culte classique classiques retro soiree nuit projection partie part episode chapitre volume vol film le la les un une des de du d l s et the a of and en au aux".split(separator: " ").map(String.init))
    private static let romain = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]
    private static func mots(_ t: String) -> [String] { plat(t).split(separator: " ").map { romain[String($0)] ?? String($0) }.filter { !bruit.contains($0) } }
    private static func num(_ s: String) -> Bool { s.count <= 2 && s.allSatisfy(\.isNumber) }
    private static func annee(_ s: String) -> Bool { s.count == 4 && (s.hasPrefix("19") || s.hasPrefix("20")) && s.allSatisfy(\.isNumber) }
    private static func sub(_ s: String, _ re: String, _ by: String = " ") -> String { s.replacingOccurrences(of: re, with: by, options: [.regularExpression, .caseInsensitive]) }
    static func net(_ t: String) -> String {
        var s = sub(t, "[(\\[][^)\\]]*[)\\]]")
        s = sub(s, "(\\s[-–|]|[,:])\\s*(version|vo|vf|vost\\w*|4k|imax|reprise|ressortie|cin[ée].?club|restaur\\S*|\\d+\\s*ans).*$")
        s = sub(s, "\\b(version (longue|restaur\\S*|int[ée]grale|remast\\S*|in[ée]dite)|final cut|4k|vostf?r?|imax|director.?s cut|\\d+(e|ème|th)? anni\\S*)\\b")
        return sub(sub(s, "\\s+"), "[\\s,:–-]+$", "").trimmingCharacters(in: .whitespaces)
    }
    private static func parts(_ t: String) -> [String] {
        sub(t, "\\s*[:–—]\\s*|\\s+-\\s+", "\u{1}").split(separator: "\u{1}").map(String.init)
    }
    private static func pareil(_ a: String, _ b: String) -> Bool {
        let A = mots(a), B = mots(b).filter { !annee($0) || A.contains($0) }
        if A.isEmpty || B.isEmpty { return plat(a) == plat(b) && !plat(a).isEmpty }
        if A == B { return true }
        let na = A.filter { !num($0) }, nb = B.filter { !num($0) }
        return A.count >= 3 && na.count >= 3 && na == nb && (!A.contains(where: num) || !B.contains(where: num)) && parts(a).count > 1
    }
    static func same(_ ours: [String], _ raw: [String]) -> Bool {
        let ours = ours.filter { !$0.isEmpty }, raw = raw.filter { !$0.isEmpty }
        for o in ours {
            for t in raw where pareil(o, t) || pareil(o, net(t)) { return true }
            let p = parts(o), tail = p.dropFirst().joined(separator: " ")
            if mots(tail).count >= 2, raw.contains(where: { pareil(tail, $0) || pareil(tail, net($0)) }) { return true }
            if p.count > 1, mots(p[0]).count >= 2, raw.contains(where: { t in
                plat(t).range(of: "\\b(trilogie|trilogy|integrale|marathon|saga)\\b", options: .regularExpression) != nil && mots(p[0]).allSatisfy(mots(t).contains)
            }) { return true }
        }
        return false
    }
    /// Autre version d’une œuvre déjà connue : sa fiche AlloCiné porte souvent une autre année
    static func version(_ t: String) -> Bool {
        plat(t).range(of: "\\b(version (longue|restaure\\w*|integrale|remast\\w*|inedite|extended|noir et blanc|du realisateur)|directors? cut|director s cut|extended|final cut|remaster\\w*|restaure\\w*|anniversaire|anniversary|reprise|ressortie|4k|\\d+ ans)\\b", options: .regularExpression) != nil
    }
    /// Titre simplifié, puis sous-titre seul pour « Saga, sous-titre »
    static func variantes(_ t: String) -> [String] {
        let n = net(t).isEmpty ? t : net(t)
        let p = sub(n, "\\s*[:–—,]\\s*|\\s+-\\s+", "\u{1}").split(separator: "\u{1}").map(String.init)
        return [n] + (p.count > 1 && mots(p[p.count - 1]).count >= 2 ? [p[p.count - 1]] : [])
    }
    /// Même titre, et sortie à un an près d’une année connue d’AlloCiné.
    static func same(title: String, original: String, year: Int?, _ f: ACFilm) -> Bool {
        guard same([title, original], [f.title, f.original]) else { return false }
        guard let year, !f.years.isEmpty, !version(f.title) else { return true }
        return f.years.contains { abs($0 - year) <= 1 }
    }
}
