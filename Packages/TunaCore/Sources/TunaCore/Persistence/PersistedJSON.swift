import Foundation

/// JSON helpers of the persistence layer (namespaced to keep the module's top level free).
enum PersistedJSON {}

extension PersistedJSON {
    /// A JSON document as a value, used to repair persisted files whose shape is slightly off.
    enum Value: Codable, Hashable, Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([Value].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: Value].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        var objectValue: [String: Value]? {
            if case .object(let value) = self { return value }
            return nil
        }

        /// `overlay` laid on top of `base`: objects merge key by key (recursively), everything else is replaced, and an
        /// explicit `null` in the overlay keeps the base value. Two single-key objects with different keys are treated as
        /// different enum cases (Swift's synthesized enum coding), so the overlay replaces the base instead of mixing.
        static func merge(_ base: Value, _ overlay: Value) -> Value {
            switch (base, overlay) {
            case (_, .null):
                return base
            case (.object(let lower), .object(let upper)):
                if lower.count == 1, upper.count == 1, lower.keys.first != upper.keys.first { return overlay }
                var merged = lower
                for (key, value) in upper {
                    merged[key] = lower[key].map { merge($0, value) } ?? value
                }
                return .object(merged)
            default:
                return overlay
            }
        }
    }
}

/// Decoding that survives schema drift: a document written by an older or newer version of the app (missing keys,
/// extra keys) is overlaid on the JSON of a default value, so known fields keep their stored values and new
/// fields get defaults instead of the whole document being thrown away.
extension PersistedJSON {
    /// Strict decode first; on failure, the stored object merged over `defaults`. nil when even that fails.
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> T? {
        let decoder = TunaJSON.makeDecoder()
        if let value = try? decoder.decode(T.self, from: data) { return value }
        guard let stored = try? decoder.decode(PersistedJSON.Value.self, from: data) else { return nil }
        return decode(T.self, stored: stored, defaults: defaults)
    }

    /// `stored` merged over the JSON form of `defaults`, decoded as `T`.
    static func decode<T: Codable>(_ type: T.Type, stored: Value, defaults: T) -> T? {
        let encoder = TunaJSON.makeEncoder()
        let decoder = TunaJSON.makeDecoder()
        guard let defaultData = try? encoder.encode(defaults),
              let base = try? decoder.decode(PersistedJSON.Value.self, from: defaultData),
              let mergedData = try? encoder.encode(Value.merge(base, stored)) else { return nil }
        return try? decoder.decode(T.self, from: mergedData)
    }
}
