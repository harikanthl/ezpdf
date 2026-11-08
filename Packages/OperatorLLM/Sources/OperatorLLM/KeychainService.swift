//
//  KeychainService.swift
//  OperatorLLM
//
//  Secure storage for BYOK API keys. Keys live ONLY in the Keychain —
//  never in UserDefaults, on disk, or logs, and are never synced through the relay.
//
//  Lifted from MuseDrop's KeychainService.swift; made public and re-namespaced so
//  Operator's entries never collide with MuseDrop's on the same Mac. Accounts are
//  `operator.llm.<provider>.apiKey` (+ `operator.tts.elevenlabs.apiKey` for voice).
//

import Foundation
#if canImport(Security)
import Security
#endif

// ‼️ THE ACCOUNT NAMES ARE PORTABLE; THE KEYCHAIN IS NOT (2026-09-11, docs/LINUX_WORKSTATION.md L0).
//
// `OperatorCore` gained an edge to this package on 2026-09-04 (31e6784, for `LLMToolSpec`), which
// made this file's bare `import Security` a Linux build failure for OperatorCore, OperatorSupervisor
// and everything downstream — the second of the two regressions the Linux CI job was added to catch.
//
// The split below is what keeps the edge cheap: `Account` is string building and compiles anywhere,
// so `LLMProvider.keychainAccount` still answers on Linux; the six `SecItem*` functions are Apple's
// and are absent there. A Linux caller that needs to STORE a secret uses the daemon's own backend
// (LINUX_WORKSTATION §5: the 0600 document beside `SupervisorState`'s identity, Secret Service
// later) — behind the same seam, never a fake Keychain that silently loses keys.
public enum KeychainService {
    #if canImport(Security)
    /// Service namespace for all Operator secrets. Distinct from MuseDrop's
    /// `com.kekasatori.apikeys` so the two apps never read each other's keys.
    private static let service = "ai.harikanth.ezpdf.apikeys" // ezpdf assistant keys

    // MARK: - Queries
    //
    // All storage uses the DATA-PROTECTION keychain
    // (`kSecUseDataProtectionKeychain: true`). Data-protection items are scoped
    // by application identifier, not by a per-code-signature ACL, so re-signed
    // builds (dev vs notarized) never re-prompt "Operator wants to access…" per
    // item.
    //
    // GOTCHA (verified on macOS 15.5): a query WITHOUT the flag is not
    // "file-based only" — it matches data-protection items too. So an unflagged
    // SecItemDelete removes BOTH copies, and ordering matters: any legacy cleanup
    // must happen BEFORE a fresh data-protection write, never after.

    /// Query targeting the legacy file-based keychain.
    private static func legacyQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Query targeting the data-protection keychain (all items).
    private static func query(for account: String) -> [String: Any] {
        var query = legacyQuery(for: account)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    /// Store (or replace) a secret for the given account key. Empty value deletes it.
    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        store(value, for: account) == errSecSuccess
    }

    /// `set`, but it SAYS WHY. Returns the raw `OSStatus` of the write (`errSecSuccess` on success),
    /// so a settings screen can tell the person what happened instead of clearing the field and
    /// hoping. Found 2026-09-05: "Save key" on the phone showed nothing either way — the only success
    /// signal was a placeholder-text change, and a failed `SecItemAdd` (an access-group entitlement
    /// missing from a dev profile is `-34018`, a stale duplicate in another group is `-25299`) was
    /// indistinguishable from success except that "Test connection" then said "Add an API key first".
    public static func store(_ value: String, for account: String) -> OSStatus {
        guard !value.isEmpty else { return remove(account) }
        guard let data = value.data(using: .utf8) else { return errSecParam }

        let query = query(for: account)

        // Replace if present. The unflagged delete clears BOTH keychains (see
        // GOTCHA), which is why it runs BEFORE the add: after the add it would
        // delete the item we just wrote.
        SecItemDelete(legacyQuery(for: account) as CFDictionary)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecMissingEntitlement else { return status }
        // ezRecord ships without an application-identifier entitlement (Developer ID, no provisioning
        // profile), so the data-protection keychain refuses it (-34018, found 2026-10-24: the key never
        // saved and Settings › AI's Test stayed off). The login keychain needs no entitlement.
        var legacy = legacyQuery(for: account)
        legacy[kSecValueData as String] = data
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(legacy as CFDictionary, nil)
    }

    /// A sentence for an `OSStatus`, with the code kept in it — the code is what a search finds.
    public static func describe(_ status: OSStatus) -> String {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
        return "\(text) (OSStatus \(status))"
    }

    /// Load a secret, or nil if absent. Reached only on a real user action that
    /// needs the key — never on passive status checks (see `has`).
    public static func get(_ account: String) -> String? {
        // Unflagged, so it finds the data-protection copy or the login-keychain fallback (see `store`).
        var query = legacyQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }

    /// True if a secret exists for the account.
    ///
    /// This is an EXISTENCE check only — it deliberately omits `kSecReturnData`, so
    /// SecItem never decrypts the stored secret. Decrypting a value is what triggers
    /// the macOS "wants to use your confidential information" prompt; an existence
    /// check does not. Status/readiness callers must stay prompt-free.
    public static func has(_ account: String) -> Bool {
        var query = legacyQuery(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        remove(account) == errSecSuccess
    }

    /// `delete`, but it SAYS WHY: the first status that was neither success nor "not found", or
    /// `errSecSuccess`. "Never written" is not a failure; a keychain that refuses the call is, and its
    /// code (`-34018` for a missing application-identifier entitlement) is worth more than a `false`.
    public static func remove(_ account: String) -> OSStatus {
        // Delete from BOTH keychains so a stale legacy copy can't resurface.
        let status = SecItemDelete(query(for: account) as CFDictionary)
        let legacyStatus = SecItemDelete(legacyQuery(for: account) as CFDictionary)
        for candidate in [status, legacyStatus] where ![errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(candidate) {
            return candidate
        }
        return errSecSuccess
    }
    #endif   // canImport(Security)

    // MARK: - Known accounts
    //
    // Portable on purpose (see the file header): no `Security` symbol appears below this line.

    public enum Account {
        /// Keychain account holding a given provider's BYOK API key:
        /// `operator.llm.<provider>.apiKey`. On-device needs no key.
        public static func llm(_ provider: LLMProviderPreset) -> String? {
            guard provider.requiresAPIKey else { return nil }
            return "operator.llm.\(provider.rawValue).apiKey"
        }

        /// ElevenLabs key (`xi-api-key`) for the voice text-to-speech engine (V4).
        public static let elevenLabs = "operator.tts.elevenlabs.apiKey"
    }
}
