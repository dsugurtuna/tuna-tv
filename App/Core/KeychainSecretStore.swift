import Foundation
import Security
import TunaCore

/// Provider passwords and metadata API keys as generic passwords in the login keychain
/// (service "io.github.dsugurtuna.tunatv"). Reads are cached in memory (misses too), so SwiftUI bodies
/// and repeated lookups never hit the keychain twice.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    let service: String
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    init(service: String = "io.github.dsugurtuna.tunatv") {
        self.service = service
    }

    func secret(for key: String) -> String? {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = read(key)
        lock.lock()
        cache.updateValue(value, forKey: key)
        lock.unlock()
        return value
    }

    func setSecret(_ value: String?, for key: String) {
        let stored: String?
        if let value, !value.isEmpty {
            stored = write(value, for: key) ? value : read(key)
        } else {
            delete(key)
            stored = nil
        }
        lock.lock()
        cache.updateValue(stored, forKey: key)
        lock.unlock()
    }

    // MARK: Security framework

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { TunaLog.shared.log("keychain", "read failed (\(status))") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            TunaLog.shared.log("keychain", "update failed (\(status))")
            return false
        }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Tuna TV"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { TunaLog.shared.log("keychain", "add failed (\(addStatus))") }
        return addStatus == errSecSuccess
    }

    private func delete(_ key: String) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            TunaLog.shared.log("keychain", "delete failed (\(status))")
        }
    }
}
