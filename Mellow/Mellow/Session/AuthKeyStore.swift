import Foundation
import Security

// 16-byte ring auth_key in iOS Keychain. app-layer secret the ring requires
// for the handshake (PROTOCOL.md §1.3, §3.1); originates from official Oura
// app assa-store.realm. provisioned via hex paste or realm import.
enum AuthKeyStore {
    private static let service = "com.maniforoughi.mellow.authkey"
    private static let account = "ring-auth-key"

    // confirmed = saved key authenticated against ring at least once (session
    // reached steady). distinct from "key saved": key is written at claim START
    // before ring confirms it, so a mid-flow interrupt would strand a dead key
    // and auto-connect would hang. gating off this flag falls back to fresh claim.
    private static let claimedKey = "mellow.ringClaimConfirmed"

    static func save(_ key: [UInt8]) throws {
        guard key.count == 16 else { throw RingCrypto.CryptoError.badKeyLength(key.count) }
        let data = Data(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load() -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 16 else { return nil }
        return [UInt8](data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: claimedKey)
    }

    // key present (may be unconfirmed / mid-claim)
    static var isProvisioned: Bool { load() != nil }

    // saved key authenticated against ring. only this gates auto-connect + live tabs
    static var isClaimConfirmed: Bool {
        load() != nil && UserDefaults.standard.bool(forKey: claimedKey)
    }

    // call once session reaches steady authenticated link
    static func markClaimConfirmed() {
        guard load() != nil else { return }
        UserDefaults.standard.set(true, forKey: claimedKey)
    }

    enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let s): return "Keychain error \(s)"
            }
        }
    }
}
