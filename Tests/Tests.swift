import XCTest
import UIKit
@testable import MonCine

final class Tests: XCTestCase {
    func testTitres() {
        let sda = ["Le Seigneur des anneaux : La Communauté de l'anneau", "The Lord of the Rings: The Fellowship of the Ring"]
        for t in ["LE SEIGNEUR DES ANNEAUX : LA COMMUNAUTE DE L’ANNEAU", "Le Seigneur des Anneaux 1 - La Communauté de l’Anneau (Version longue)", "La Communauté de l’anneau", "Le Seigneur des Anneaux : La Communauté de l’Anneau - 25 ans", "Le Seigneur des anneaux I : la communauté de l’anneau", "Marathon Le Seigneur des Anneaux"] { XCTAssertTrue(Match.same(sda, [t]), t) }
        for t in ["Le Seigneur des anneaux : Les Deux Tours", "Le Seigneur des Anneaux", "La Communauté"] { XCTAssertFalse(Match.same(sda, [t]), t) }
        XCTAssertFalse(Match.same(["Shrek"], ["Shrek 2"])); XCTAssertTrue(Match.same(["Shrek"], ["Shrek (reprise)"])); XCTAssertFalse(Match.same(["Alien"], ["Aliens"]))
        XCTAssertEqual(Match.net("Interstellar (VOST) - Reprise"), "Interstellar")
    }
    func testJournee() {
        for (l, d) in [("2026-12-12T23:59", "2026-12-12"), ("2026-12-13T00:01", "2026-12-12"), ("2026-12-13T02:59", "2026-12-12"), ("2026-12-13T03:00", "2026-12-13"), ("2027-01-01T00:01", "2026-12-31"), ("2028-03-01T00:30", "2028-02-29")] { XCTAssertEqual(Jour.cine(Jour.local(l)!), d) }
        XCTAssertEqual(Jour.shift("2026-10-25", 1), "2026-10-26"); XCTAssertEqual(Jour.shift("2027-03-28", 1), "2027-03-29")
    }
    func testAlloCine() {
        let tick: [J] = ["en", "relay", "default"].map { ["urls": ["https://\($0)"], "type": "DESKTOP", "provider": $0] as J }
        let s: J = ["internalId": 9, "startsAt": "2026-12-13T00:15:00", "diffusionVersion": "ORIGINAL", "tags": ["Localization.Subtitle.French", "Format.Projection.Imax", "Format.Projection.Digital"], "experience": NSNull(), "data": ["ticketing": tick] as J]
        let m: J = ["internalId": 5, "title": "A", "runtime": "2h 28min", "data": ["productionYear": 2026] as J]
        let f = AlloCine.film(["movie": m, "showtimes": ["original_st": [s], "multiple": [s]] as J] as J)!
        XCTAssertEqual(f.seances.count, 1); XCTAssertEqual(f.runtime, 148)
        let z = f.seances[0]
        XCTAssertEqual([z.version, z.url ?? "", z.day], ["VOST", "https://default", "2026-12-12"]); XCTAssertEqual(z.formats, ["IMAX"])
        XCTAssertEqual(AlloCine.day([f], "2026-12-12").count, 1); XCTAssertEqual(AlloCine.day([f], "2026-12-13")[0].seances[0].label, "Nuit du 12 au 13"); XCTAssertEqual(AlloCine.day([f], "2026-12-14").count, 0)
        XCTAssertEqual(AlloCine.ttl("2026-11-24", Jour.local("2026-11-24T10:00")!), 86400); XCTAssertEqual(AlloCine.ttl("2026-11-25", Jour.local("2026-11-24T10:00")!), 6 * 3600); XCTAssertEqual(AlloCine.ttl("2026-12-02", Jour.local("2026-11-26T10:00")!), 14 * 3600)
    }
    func testCinemas() { XCTAssertEqual(Salles.all.count, 2630); XCTAssertEqual(Salles.search("comoedia lyon", near: .init(latitude: 45.76, longitude: 4.83)).first?.id, "P3757") }
    func testBillets() {
        let t = Importer.parse("Pathé CinéCarte\nCode : ABC123XYZ\nPIN : 0000\nValable jusqu’au 31 août 2027", "ABC123XYZ")
        XCTAssertEqual(t.brand, .pathe); XCTAssertEqual(t.pin, "0000"); XCTAssertTrue(t.prepaid); XCTAssertEqual(t.until.map(Jour.iso), "2027-08-31"); XCTAssertEqual(t.number, "ABC123XYZ")
        let c = Importer.parse("e-CinéChèque valable jusqu'au 30/06/2027", "1234567890"); XCTAssertEqual(c.brand, .cinecheque); XCTAssertEqual(c.until.map(Jour.iso), "2027-06-30")
        for s in ["QR", "Aztec", "PDF417", "Code128"] { XCTAssertNotNil(Code.draw("ABC123XYZ", s), s) }
    }
    /// PDF de deux pages, un QR par page : importé, relu, redessiné à l’identique
    func testBilletPDF() throws {
        let u = FileManager.default.temporaryDirectory.appending(path: "t.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).writePDF(to: u) { c in
            for k in ["ABC123XYZ", "DEF456UVW"] {
                c.beginPage()
                ("Pathé CinéCarte valable jusqu'au 31/08/2027 PIN : 4321" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                c.cgContext.interpolationQuality = .none
                Code.draw(k, "QR")!.draw(in: CGRect(x: 150, y: 200, width: 250, height: 250))
            }
        }
        let l = Importer.file(u)
        if l.isEmpty { throw XCTSkip("Vision indisponible dans ce simulateur") }
        XCTAssertEqual(Set(l.compactMap(\.payload)), ["ABC123XYZ", "DEF456UVW"]); XCTAssertEqual(l[0].pin, "4321"); XCTAssertNil(l[0].image); XCTAssertEqual(l[0].until.map(Jour.iso), "2027-08-31")
    }
    func testSauvegarde() throws {
        var s = Saved(); s.ratings[3] = Rating(film: Film(id: 3, title: "A"), stars: 4.5, comment: "", date: .now); s.onboarded = true
        XCTAssertEqual(try JSONDecoder().decode(Saved.self, from: JSONEncoder().encode(s)).ratings[3]?.stars, 4.5)
        XCTAssertNoThrow(try JSONDecoder().decode(Saved.self, from: Data("{}".utf8)))
    }
    func testStreaming() { XCTAssertEqual(MonCine.Stream.url(Provider(id: 8, name: "Netflix"), "L’été & moi")?.host(), "www.netflix.com"); XCTAssertNil(MonCine.Stream.url(Provider(id: 1, name: "Inconnu"), "x")) }
}
