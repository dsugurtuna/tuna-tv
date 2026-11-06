import Foundation
import XCTest
@testable import TunaCore

final class TunaJSONTests: XCTestCase {
    private struct Stamp: Codable, Equatable {
        var at: Date
    }

    func testDatesAreISO8601WithMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        XCTAssertEqual(TunaJSON.string(from: date), "2027-01-15T08:00:00.250Z")
        let data = try TunaJSON.makeEncoder().encode(Stamp(at: date))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"at":"2027-01-15T08:00:00.250Z"}"#)
        XCTAssertEqual(try TunaJSON.makeDecoder().decode(Stamp.self, from: data), Stamp(at: date))
    }

    func testDecodingAcceptsCommonDateForms() throws {
        let decoder = TunaJSON.makeDecoder()
        let plain = try decoder.decode(Stamp.self, from: Data(#"{"at":"2027-01-15T08:00:00Z"}"#.utf8))
        XCTAssertEqual(plain.at, Date(timeIntervalSince1970: 1_800_000_000))
        let offset = try decoder.decode(Stamp.self, from: Data(#"{"at":"2027-01-15T11:00:00+03:00"}"#.utf8))
        XCTAssertEqual(offset.at, Date(timeIntervalSince1970: 1_800_000_000))
        let numeric = try decoder.decode(Stamp.self, from: Data(#"{"at":0}"#.utf8))
        XCTAssertEqual(numeric.at, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertThrowsError(try decoder.decode(Stamp.self, from: Data(#"{"at":"yesterday"}"#.utf8)))
    }

    func testPersistedJSONMergeKeepsStoredValuesAndFillsDefaults() throws {
        let base = PersistedJSON.Value.object([
            "a": .int(1),
            "nested": .object(["x": .bool(true), "y": .string("default")]),
            "mode": .object(["vlc": .object([:])]),
            "list": .array([.int(1), .int(2)]),
        ])
        let stored = PersistedJSON.Value.object([
            "nested": .object(["y": .string("stored")]),
            "mode": .object(["custom": .object(["_0": .string("UA")])]),
            "list": .array([.int(9)]),
            "a": .null,
            "extra": .double(1.5),
        ])
        let merged = PersistedJSON.Value.merge(base, stored)
        XCTAssertEqual(merged, .object([
            "a": .int(1),
            "nested": .object(["x": .bool(true), "y": .string("stored")]),
            "mode": .object(["custom": .object(["_0": .string("UA")])]),
            "list": .array([.int(9)]),
            "extra": .double(1.5),
        ]))

        let roundTrip = try TunaJSON.makeDecoder().decode(PersistedJSON.Value.self, from: TunaJSON.makeEncoder().encode(merged))
        XCTAssertEqual(roundTrip, merged)
    }
}
