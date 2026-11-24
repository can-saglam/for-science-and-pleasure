import Foundation
import XCTest
@testable import SyncCore

final class RowMergeTests: XCTestCase {
    private let base: Fields = [
        "id": .string("a"), "title": .string("Lee Miller"), "notes": .null, "plan_on": .null, "plan_time": .null,
        "status": .string("saved"), "image_url": .null, "updated_at": .string("2026-11-20T10:00:00.000Z"),
        "updated_by": .string("joyce"),
    ]

    private func with(_ fields: Fields, _ changes: Fields) -> Fields {
        fields.merging(changes) { _, new in new }
    }

    // MARK: - What a phone sends

    func testNothingChangedSendsNothing() {
        XCTAssertEqual(RowMerge.changes(base: base, local: base), [:])
    }

    func testOnlyTheEditedColumnIsSent() {
        let local = with(base, ["notes": .string("book ahead")])
        XCTAssertEqual(RowMerge.changes(base: base, local: local), ["notes": .string("book ahead")])
    }

    func testClearingAColumnSendsNull() {
        let base = with(self.base, ["notes": .string("old")])
        let local = with(base, ["notes": .null])
        XCTAssertEqual(RowMerge.changes(base: base, local: local), ["notes": .null])
    }

    func testServerStampsAreNeverSent() {
        let local = with(base, ["updated_at": .string("2026-11-21T09:00:00.000Z"), "updated_by": .string("can")])
        XCTAssertEqual(RowMerge.changes(base: base, local: local), [:])
    }

    func testANullPlaceIsNoEdit() {
        let base = with(self.base, ["place_id": .string("ChIJ"), "showings": .array([])])
        let local = with(base, ["place_id": .null, "showings": .null])
        XCTAssertEqual(RowMerge.changes(base: base, local: local), [:])
        XCTAssertEqual(RowMerge.merge(base: base, local: local, server: base)["place_id"], .string("ChIJ"))
    }

    // MARK: - What a pull keeps

    func testUnchangedPhoneTakesTheServer() {
        let server = with(base, ["title": .string("Lee Miller at Tate")])
        XCTAssertEqual(RowMerge.merge(base: base, local: base, server: server), server)
    }

    func testDifferentColumnsBothSurvive() {
        let local = with(base, ["notes": .string("book ahead")])
        let server = with(base, ["plan_on": .string("2026-11-29"), "updated_by": .string("can")])
        let merged = RowMerge.merge(base: base, local: local, server: server)
        XCTAssertEqual(merged["notes"], .string("book ahead"))
        XCTAssertEqual(merged["plan_on"], .string("2026-11-29"))
        XCTAssertEqual(merged["updated_by"], .string("can"))
    }

    func testSameColumnKeepsThePhonesUnsentEdit() {
        // Sent next, so it lands after the other one: the later edit wins.
        let local = with(base, ["title": .string("Mine")])
        let server = with(base, ["title": .string("Theirs")])
        XCTAssertEqual(RowMerge.merge(base: base, local: local, server: server)["title"], .string("Mine"))
    }

    func testAPlanTravelsWithItsTime() {
        let local = with(base, ["plan_on": .string("2026-11-29")])
        let server = with(base, ["plan_time": .string("19:30")])
        let merged = RowMerge.merge(base: base, local: local, server: server)
        XCTAssertEqual(merged["plan_on"], .string("2026-11-29"))
        XCTAssertEqual(merged["plan_time"], .null, "no half-plan from each side")
    }

    func testAServerPictureArrivesUnderAnEdit() {
        let local = with(base, ["notes": .string("x")])
        let server = with(base, ["image_url": .string("https://img")])
        let merged = RowMerge.merge(base: base, local: local, server: server)
        XCTAssertEqual(merged["image_url"], .string("https://img"))
        XCTAssertEqual(merged["notes"], .string("x"))
    }

    func testADeleteElsewhereWinsOverNothing() {
        let server = with(base, ["deleted_at": .string("2026-11-21T09:00:00.000Z")])
        XCTAssertEqual(RowMerge.merge(base: base, local: base, server: server)["deleted_at"], server["deleted_at"])
    }

    func testMarkingDoneHereSurvivesAnEditThere() {
        let local = with(base, ["status": .string("done"), "went_on": .string("2026-11-16")])
        let server = with(base, ["notes": .string("loved it")])
        let merged = RowMerge.merge(base: base, local: local, server: server)
        XCTAssertEqual(merged["status"], .string("done"))
        XCTAssertEqual(merged["went_on"], .string("2026-11-16"))
        XCTAssertEqual(merged["notes"], .string("loved it"))
    }

    // MARK: - Without a base

    func testWithoutABaseTheNewerCopyWinsWhole() {
        let now = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        let local = with(base, ["notes": .string("mine")])
        let server = with(base, ["title": .string("theirs")])
        XCTAssertEqual(RowMerge.wholeRow(local: local, server: server, localStamp: now, serverStamp: later), server)
        XCTAssertEqual(RowMerge.wholeRow(local: local, server: server, localStamp: later, serverStamp: now), local)
    }

    func testEqualStampsTakeTheServersPicture() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let local = with(base, ["notes": .string("mine")])
        let server = with(base, ["image_url": .string("https://img"), "title": .string("theirs")])
        let merged = RowMerge.wholeRow(local: local, server: server, localStamp: stamp, serverStamp: stamp)
        XCTAssertEqual(merged["image_url"], .string("https://img"))
        XCTAssertEqual(merged["title"], .string("Lee Miller"))
        XCTAssertEqual(merged["notes"], .string("mine"))
    }

    // MARK: - JSON

    func testValuesRoundTrip() throws {
        let row: Fields = ["a": .number(51.5), "b": .bool(true), "c": .array([.string("x")]), "d": .null]
        let decoded = try JSONDecoder().decode(Fields.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded, row)
    }
}
