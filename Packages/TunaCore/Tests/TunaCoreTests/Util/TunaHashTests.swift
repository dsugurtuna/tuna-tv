import Foundation
import XCTest
@testable import TunaCore

/// Vectors: FIPS 180-4 examples plus values computed with Python's hashlib.
final class TunaHashTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(TunaHash.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TunaHash.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(TunaHash.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(TunaHash.sha256Hex("The quick brown fox jumps over the lazy dog"),
                       "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        XCTAssertEqual(TunaHash.sha256Hex("Tuna TV ı ş"), "65ae817fa285a141bad2e688b7e0ae69a7b114a887b6fab9f72470ecec2b333d")
        XCTAssertEqual(TunaHash.sha256Hex(Data("abc".utf8)), TunaHash.sha256Hex("abc"))
        XCTAssertEqual(TunaHash.sha256(Data()).count, 32)
    }

    func testSHA256PaddingBoundaries() {
        let expected: [Int: String] = [
            55: "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072",
            56: "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e",
            63: "75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2",
            64: "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c",
            65: "9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9",
            119: "000b48d4edf0fa7bee3c6236ecd2785baa5db4eeb8bb54341b029e0d9fa5fb0c",
            120: "13f05a0b594787f5ecd315edc96141bd3243203d1b7d4f0836f37308b276ba98",
        ]
        for (length, digest) in expected {
            XCTAssertEqual(TunaHash.sha256Hex(String(repeating: "x", count: length)), digest, "length \(length)")
        }
    }

    func testSHA256OfOneMillionBytesAndStreamingAgree() {
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(TunaHash.sha256Hex(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

        var hasher = TunaHash.SHA256Hasher()
        var offset = 0
        for chunk in [1, 63, 64, 65, 7, 1000, 129] {
            hasher.update(million.subdata(in: offset ..< offset + chunk))
            offset += chunk
        }
        hasher.update(million.subdata(in: offset ..< million.count))
        XCTAssertEqual(TunaHash.hex(hasher.finalize()), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testFNV1a64KnownVectors() {
        XCTAssertEqual(TunaHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(TunaHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(TunaHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
        XCTAssertEqual(TunaHash.fnv1a64Hex("http://panel.test/live/1.ts"), "339ede0f73246e85")
        XCTAssertEqual(TunaHash.fnv1a64Hex("İstanbul"), "bdda57a45a7597d0")
        XCTAssertEqual(TunaHash.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(TunaHash.fnv1a64Hex("foobar").count, 16)
    }
}
