import Foundation

/// Small, dependency-free hashes. Pure Swift on purpose: no CryptoKit / CommonCrypto, so the same code runs on
/// macOS and Linux and gives identical results everywhere.
///
/// - `sha256Hex`: FIPS 180-4 SHA-256 as 64 lowercase hex characters (adult PIN hashes, content fingerprints).
/// - `fnv1a64`: 64-bit FNV-1a over UTF-8 bytes. Fast and stable across launches and platforms (unlike `Hasher`),
///   so it is the right tool for stable ids and cache keys derived from URLs. Not cryptographic.
public enum TunaHash {
    /// Lowercase hex SHA-256 digest of `data`.
    public static func sha256Hex(_ data: Data) -> String { hex(sha256(data)) }

    /// Lowercase hex SHA-256 digest of the UTF-8 bytes of `string`.
    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    /// Raw 32-byte SHA-256 digest of `data`.
    public static func sha256(_ data: Data) -> [UInt8] {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    /// 64-bit FNV-1a of the UTF-8 bytes of `string`.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// `fnv1a64` as 16 lowercase hex characters (zero padded).
    public static func fnv1a64Hex(_ string: String) -> String {
        let digits = String(fnv1a64(string), radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let table: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0f)])
        }
        return out
    }
}

extension TunaHash {
    /// Streaming SHA-256 (FIPS 180-4).
    struct SHA256Hasher {
        private static let roundConstants: [UInt32] = [
            0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
            0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
            0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
            0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
            0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
            0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
            0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
            0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
        ]

        private var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        /// Bytes waiting for a full 64-byte block.
        private var pending: [UInt8] = []
        /// Total message length in bytes.
        private var length: UInt64 = 0
        /// Message schedule, reused between blocks.
        private var schedule = [UInt32](repeating: 0, count: 64)

        mutating func update(_ data: Data) {
            length &+= UInt64(data.count)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                if !pending.isEmpty {
                    let take = min(64 - pending.count, raw.count)
                    pending.append(contentsOf: raw[0 ..< take])
                    offset = take
                    if pending.count == 64 {
                        let block = pending
                        block.withUnsafeBytes { compress($0, at: 0) }
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                while raw.count - offset >= 64 {
                    compress(raw, at: offset)
                    offset += 64
                }
                if offset < raw.count { pending.append(contentsOf: raw[offset ..< raw.count]) }
            }
        }

        mutating func finalize() -> [UInt8] {
            let bitLength = length &* 8
            var tail = pending
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
            tail.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    compress(raw, at: offset)
                    offset += 64
                }
            }
            pending.removeAll()
            var digest: [UInt8] = []
            digest.reserveCapacity(32)
            for word in state {
                digest.append(UInt8(truncatingIfNeeded: word >> 24))
                digest.append(UInt8(truncatingIfNeeded: word >> 16))
                digest.append(UInt8(truncatingIfNeeded: word >> 8))
                digest.append(UInt8(truncatingIfNeeded: word))
            }
            return digest
        }

        @inline(__always)
        private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }

        private mutating func compress(_ raw: UnsafeRawBufferPointer, at offset: Int) {
            for t in 0 ..< 16 {
                let base = offset + t * 4
                schedule[t] = UInt32(raw[base]) << 24 | UInt32(raw[base + 1]) << 16 | UInt32(raw[base + 2]) << 8 | UInt32(raw[base + 3])
            }
            for t in 16 ..< 64 {
                let w15 = schedule[t - 15], w2 = schedule[t - 2]
                let s0 = Self.rotr(w15, 7) ^ Self.rotr(w15, 18) ^ (w15 >> 3)
                let s1 = Self.rotr(w2, 17) ^ Self.rotr(w2, 19) ^ (w2 >> 10)
                schedule[t] = schedule[t - 16] &+ s0 &+ schedule[t - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for t in 0 ..< 64 {
                let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ Self.roundConstants[t] &+ schedule[t]
                let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }
    }
}
