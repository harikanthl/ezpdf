import Foundation
import Security

/// API keys and tokens in the Keychain (service ai.harikanth.ezpdf.apikeys, shared with the
/// assistant's keys), saved for this Mac only.
public enum Secrets {
    public static let service = "ai.harikanth.ezpdf.apikeys"

    /// The secret itself: read only when it's about to be used.
    public static func get(_ account: String) -> String? {
        for dataProtection in [true, false] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
               let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        }
        return nil
    }

    /// Whether a secret is saved, without decrypting it (no Keychain prompt).
    public static func has(_ account: String) -> Bool {
        for dataProtection in [true, false] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    /// Saves (or with nil or blank, removes) a secret. Returns the Keychain status.
    @discardableResult
    public static func set(_ value: String?, for account: String) -> OSStatus {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var dp = base; dp[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(dp as CFDictionary)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }
}
