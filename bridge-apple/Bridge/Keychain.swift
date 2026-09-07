import Foundation
import CryptoKit

// Two secrets live here and nowhere else: the Gateway's shared auth token, and
// Bridge's own Ed25519 device private key.
//
// The token is typed once by the user (Settings, or `Bridge --set-token` reading
// stdin) and read back only by native code. It is never written to a file, never
// passed as an argv, never logged, and never crosses into the web view — the
// page has no way to ask for it, because nothing on the JS bridge returns it.
//
// Writing the item from inside the app matters: an item created by another
// process (say `security add-generic-password` in a terminal) has that process
// in its ACL, and the first read from Bridge raises a keychain prompt. Bridge
// creating its own item owns it outright and reads silently.
enum Keychain {
    static let service = "net.myatlasapp.bridge"

    enum Item: String {
        case gatewayToken   // the Gateway's gateway.auth.token
        case deviceKey      // Ed25519 private key, raw 32 bytes
    }

    /// Injected by the smoke test to stand in for the primary `SecItemAdd`.
    /// A failing add cannot be provoked on a healthy keychain, and the loss this
    /// method now guards against is only reachable when one fails — so the
    /// failure is supplied rather than waited for. The RESTORE below always goes
    /// through the real `SecItemAdd`, which is the half being measured.
    static var addOverride: ((CFDictionary) -> OSStatus)?

    /// Writing a secret must never be able to destroy the one already there.
    ///
    /// This was `SecItemDelete` then `SecItemAdd`, returning false if the add
    /// failed — by which point the previous value was already gone. The two
    /// items here are the gateway token and the Ed25519 **device key**, and the
    /// device key is not re-derivable: losing it means a new device identity and
    /// a re-pair with the gateway. The visible shape is worse than it sounds,
    /// because the only caller that overwrites a live value is Settings — so
    /// merely *trying* to change a working token could leave the app with none.
    ///
    /// The old value is now read before the delete and put back if the add
    /// fails. `SecItemAdd` after a successful `SecItemDelete` is the standard
    /// idiom and rarely fails; this is the four lines that make "rarely" not
    /// mean "silently unrecoverable".
    @discardableResult
    static func set(_ item: Item, _ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        let previous = get(item)
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // After-first-unlock, not when-unlocked: Bridge should reconnect after a
        // reboot+login without waiting for someone to open Settings again.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = (addOverride ?? { SecItemAdd($0, nil) })(add as CFDictionary)
        if status == errSecSuccess { return true }

        NSLog("bridge: keychain write failed for \(item.rawValue) (OSStatus \(status))")
        if let previous {
            var back = base
            back[kSecValueData as String] = previous
            back[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(back as CFDictionary, nil) != errSecSuccess {
                NSLog("bridge: and the previous \(item.rawValue) could NOT be restored")
            }
        }
        return false
    }

    static func get(_ item: Item) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ item: Item) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ] as CFDictionary)
    }

    static var token: String? {
        get { get(.gatewayToken).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                delete(.gatewayToken); return
            }
            set(.gatewayToken, Data(v.utf8))
        }
    }
}

// Bridge's device identity. The Gateway grants operator scopes to a *paired
// device*, not to a bare shared secret: a connect carrying the token but no
// device proof authenticates as role `operator` with an empty scope set, and
// every read then fails MISSING_SCOPE. So the client must hold a stable Ed25519
// key, sign the challenge-bound payload with it, and be approved once.
//
// deviceId is the SHA-256 of the raw 32-byte public key, hex — the same
// derivation the Gateway uses, so both ends agree without exchanging it.
struct DeviceIdentity {
    let key: Curve25519.Signing.PrivateKey

    static func loadOrCreate() -> DeviceIdentity {
        if let raw = Keychain.get(.deviceKey),
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return DeviceIdentity(key: k)
        }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(.deviceKey, k.rawRepresentation)
        NSLog("bridge: generated a new device identity")
        return DeviceIdentity(key: k)
    }

    var publicKeyRaw: Data { key.publicKey.rawRepresentation }
    var publicKeyBase64URL: String { Self.b64url(publicKeyRaw) }
    var deviceId: String {
        SHA256.hash(data: publicKeyRaw).map { String(format: "%02x", $0) }.joined()
    }

    func sign(_ payload: String) -> String? {
        guard let sig = try? key.signature(for: Data(payload.utf8)) else { return nil }
        return Self.b64url(sig)
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
