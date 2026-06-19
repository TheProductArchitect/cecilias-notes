import CryptoKit
import Foundation
import Security

/// Keychain-backed store for the per-peer shared secret derived during
/// pairing. The Mac MCP and the iPad each independently run HKDF over
/// the 6-digit code the user entered to land on the same 256-bit key,
/// then store it under the peer's display name. Every subsequent
/// payload is authenticated with HMAC-SHA256 using this key — peer-name
/// spoofing on the local network is a no-op because the attacker
/// doesn't have the key.
///
/// **Why Keychain, not UserDefaults**: the symmetric key has to survive
/// app uninstall on a single device but never leak via iCloud Keychain
/// or any other off-device path. We use `kSecAttrSynchronizable = false`
/// and `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// to keep the key local-only.
///
/// **Pairing flow** (designed against
/// `Documentation/MULTIPEER_SYNC_PROTOCOL.md`):
///
/// 1. iPad enters "pairing mode" via Settings → cloud → "show pairing
///    code". Generates a 6-digit numeric code uniformly at random.
/// 2. User reads the code aloud / shares it; types it into the Mac
///    MCP companion's pairing prompt.
/// 3. Both sides run `derivedKey(from: code, peerName:)` with their
///    counterpart's peer name as salt. The resulting `SymmetricKey`
///    is the shared secret.
/// 4. Mac sends a "pairing-hello" payload signed with the new key.
///    iPad verifies, then `store(key:for:)` persists the key.
/// 5. Pairing mode expires after 90 seconds — the iPad stops
///    accepting hellos from un-paired peers.
@MainActor
enum MultipeerPairingStore {

    static let serviceName = "app.ceciliasnotes.multipeer.sharedKey"

    /// Look up the persisted shared key for a peer. Nil when never
    /// paired or after the user clears the trust store.
    static func sharedKey(forPeerName peerName: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: peerName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    /// Persist (or overwrite) the shared key for a peer. Marked
    /// `synchronizable: false` so the key never travels via iCloud
    /// Keychain; this device's pairing stays this device's secret.
    static func store(key: SymmetricKey, forPeerName peerName: String) {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: peerName,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: keyBytes
        ]
        // Best-effort update-then-add: SecItemUpdate fails when the
        // item doesn't exist; SecItemAdd fails when it does. Try
        // delete-then-add for a deterministic write.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: peerName
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Remove a single peer's pairing. Called from "forget device"
    /// in Settings; the next connection from that peer will require
    /// a fresh pairing code.
    static func forget(peerName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: peerName
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Wipe every paired peer. Backs the "forget all paired devices"
    /// button.
    static func forgetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Return the list of peer names that have a stored key. Drives
    /// the Settings UI's paired-devices count + per-row forget.
    static func pairedPeerNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    // MARK: - Key derivation

    /// HKDF over the 6-digit pairing code, peppered with the peer
    /// name as info string and a known salt. Both sides MUST agree
    /// on every input for the keys to match.
    ///
    /// - `code`: 6-digit string the user typed. Treated as UTF-8 bytes.
    /// - `localPeerName`: the iPad's display name (this device).
    /// - `remotePeerName`: the Mac's display name.
    ///
    /// We bind the key derivation to both names so the same code
    /// reused across different device pairs produces different keys.
    static func derivedKey(
        fromCode code: String,
        localPeerName: String,
        remotePeerName: String
    ) -> SymmetricKey {
        let salt = "ceciliasnotes.multipeer.v1.salt".data(using: .utf8)!
        let info = "\(localPeerName)|\(remotePeerName)".data(using: .utf8)!
        let inputKey = SymmetricKey(data: code.data(using: .utf8) ?? Data())
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - Pairing-mode code generation

    /// Cryptographically-random 6-digit string. Generates 1,000,000
    /// possible codes which is fine because the code is short-lived
    /// (90 seconds), the pairing channel is local-network only, and
    /// every Mac-side input failure still requires the user to be
    /// on the iPad's LAN.
    static func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Pull a 32-bit integer out of the random bytes and modulo
        // into the 6-digit range. Modulo bias here is negligible:
        // 1,000,000 vs UInt32.max is far below any meaningful bias
        // threshold (~0.023%), and the entropy budget is the
        // user-typed code, not Apple's CSPRNG.
        let n: UInt32
        if status == errSecSuccess {
            n = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        } else {
            n = UInt32.random(in: 0...UInt32.max)
        }
        return String(format: "%06d", n % 1_000_000)
    }
}
