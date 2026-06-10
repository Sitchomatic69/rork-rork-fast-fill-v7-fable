import Foundation
import Security

nonisolated final class KeychainService: Sendable {
    static let shared = KeychainService()
    private let serviceIdentifier = "com.fastfillbrowser.credentials"
    /// Magic prefix tagging a payload as a JSON-encoded list of passwords.
    /// Single-password legacy entries are stored as plain UTF-8 strings, so a
    /// prefix that is not a valid password character keeps the two formats
    /// unambiguous.
    private let multiPrefix = "\u{01}FFBMULTI:"

    private init() {}

    @discardableResult
    func savePassword(_ password: String, for credentialID: String) -> Bool {
        savePasswords([password], for: credentialID)
    }

    @discardableResult
    func savePasswords(_ passwords: [String], for credentialID: String) -> Bool {
        deletePassword(for: credentialID)
        let trimmed = passwords.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return false }

        let payload: String
        if trimmed.count == 1 {
            payload = trimmed[0]
        } else {
            guard let data = try? JSONEncoder().encode(trimmed),
                  let json = String(data: data, encoding: .utf8) else { return false }
            payload = multiPrefix + json
        }

        guard let data = payload.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func getPassword(for credentialID: String) -> String? {
        getPasswords(for: credentialID).first
    }

    func getPasswords(for credentialID: String) -> [String] {
        guard let raw = readRawString(for: credentialID) else { return [] }
        if raw.hasPrefix(multiPrefix) {
            let json = String(raw.dropFirst(multiPrefix.count))
            if let data = json.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                return arr
            }
            return []
        }
        return [raw]
    }

    private func readRawString(for credentialID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func batchGetPasswords(for credentialIDs: [String]) -> [String: String] {
        var results: [String: String] = [:]
        for id in credentialIDs {
            if let password = getPassword(for: id) {
                results[id] = password
            }
        }
        return results
    }

    @discardableResult
    func deletePassword(for credentialID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
