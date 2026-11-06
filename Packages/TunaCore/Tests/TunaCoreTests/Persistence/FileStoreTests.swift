import Foundation
import XCTest
@testable import TunaCore

final class FileStoreTests: XCTestCase {
    private var store: FileStore!

    override func setUp() {
        super.setUp()
        store = FileStore.temporary()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.baseURL)
        store = nil
        super.tearDown()
    }

    private struct Doc: Codable, Equatable {
        var name: String
        var count: Int
        var when: Date
        var link: String
    }

    /// Every name in a directory, hidden ones included.
    private func rawNames(_ relative: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.url(for: relative).path)) ?? []).sorted()
    }

    func testDataRoundTripCreatesIntermediateDirectoriesAndLeavesNoTempFiles() throws {
        let payload = Data("hello".utf8)
        try store.writeData(payload, to: "a/b/c/file.bin")
        XCTAssertEqual(store.readData("a/b/c/file.bin"), payload)
        XCTAssertTrue(store.exists("a/b/c/file.bin"))
        try store.writeData(Data("replaced".utf8), to: "a/b/c/file.bin")
        XCTAssertEqual(store.readData("a/b/c/file.bin"), Data("replaced".utf8))
        XCTAssertEqual(rawNames("a/b/c"), ["file.bin"], "no temporary files left behind")
    }

    func testJSONUsesSortedKeysAndISO8601Dates() throws {
        let doc = Doc(name: "Tuna", count: 3, when: Date(timeIntervalSince1970: 1_800_000_000.25), link: "http://x.test/a")
        try store.write(doc, to: "doc.json")
        let text = String(decoding: store.readData("doc.json") ?? Data(), as: UTF8.self)
        XCTAssertEqual(text, #"{"count":3,"link":"http://x.test/a","name":"Tuna","when":"2027-01-15T08:00:00.250Z"}"#)
        XCTAssertEqual(store.read(Doc.self, from: "doc.json"), doc)
    }

    func testMissingAndCorruptFilesReadAsNil() throws {
        XCTAssertNil(store.readData("nope.json"))
        XCTAssertNil(store.read(Doc.self, from: "nope.json"))
        try store.writeData(Data("{not json".utf8), to: "broken.json")
        XCTAssertNil(store.read(Doc.self, from: "broken.json"))
        try store.writeData(Data(#"{"name":"x"}"#.utf8), to: "partial.json")
        XCTAssertNil(store.read(Doc.self, from: "partial.json"))
        try store.writeData(Data(), to: "empty.json")
        XCTAssertNil(store.read(Doc.self, from: "empty.json"))
        try store.writeData(Data("x".utf8), to: "dir/inside.txt")
        XCTAssertNil(store.readData("dir"), "a directory is not a file")
    }

    func testReadersNeverSeeAPartialFile() throws {
        let small = Data(repeating: 0x41, count: 64 * 1024)
        let large = Data(repeating: 0x42, count: 512 * 1024)
        try store.writeData(small, to: "race/blob.bin")
        let failures = LockedCounter()
        let reads = LockedCounter()
        let store = self.store!
        DispatchQueue.concurrentPerform(iterations: 120) { index in
            if index.isMultiple(of: 3) {
                try? store.writeData(index.isMultiple(of: 2) ? small : large, to: "race/blob.bin")
            } else if let data = store.readData("race/blob.bin") {
                reads.increment()
                if data != small && data != large { failures.increment() }
            } else {
                failures.increment()
            }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertGreaterThan(reads.value, 0)
        XCTAssertEqual(rawNames("race"), ["blob.bin"])
    }

    func testPathsCannotEscapeTheBaseDirectory() throws {
        try store.writeData(Data("x".utf8), to: "../../escape.txt")
        XCTAssertTrue(store.url(for: "../../escape.txt").path.hasPrefix(store.baseURL.path))
        XCTAssertEqual(store.readData("escape.txt"), Data("x".utf8))
        XCTAssertEqual(store.url(for: "a/./b//c"), store.url(for: "a/b/c"))
        XCTAssertThrowsError(try store.writeData(Data(), to: ""))
        XCTAssertThrowsError(try store.writeData(Data(), to: "../.."))
    }

    func testListSizeModifiedAtAndRemove() throws {
        try store.writeData(Data(count: 10), to: "dir/one.bin")
        try store.writeData(Data(count: 20), to: "dir/two.bin")
        try store.writeData(Data(count: 30), to: "dir/sub/three.bin")
        try store.writeData(Data(count: 5), to: "dir/.hidden")
        try store.writeData(Data(count: 7), to: "top.bin")

        XCTAssertEqual(store.list("dir"), ["one.bin", "sub", "two.bin"])
        XCTAssertEqual(store.list("missing"), [])
        XCTAssertEqual(store.size(of: "dir"), 65)
        XCTAssertEqual(store.size(of: ""), 72)
        XCTAssertEqual(store.size(of: "dir/one.bin"), 10)
        XCTAssertEqual(store.size(of: "missing"), 0)

        let modified = try XCTUnwrap(store.modifiedAt("dir/one.bin"))
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 300)
        XCTAssertNil(store.modifiedAt("missing"))

        store.remove("dir/sub")
        XCTAssertEqual(store.list("dir"), ["one.bin", "two.bin"])
        store.remove("dir/one.bin")
        XCTAssertFalse(store.exists("dir/one.bin"))
        store.remove("never-existed")

        store.remove("")
        XCTAssertEqual(store.list(""), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.baseURL.path), "the base directory itself stays")
        try store.writeData(Data("again".utf8), to: "again.txt")
        XCTAssertEqual(store.readData("again.txt"), Data("again".utf8))
    }
}

/// Thread-safe counter for `concurrentPerform` tests.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
