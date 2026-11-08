import Foundation
import Security
import Testing
@testable import OperatorLLM

/// `KeychainService.store` reports its `OSStatus` so a settings screen can say what a failed save
/// was, and `describe` keeps the code in the sentence — the code is what a search finds. The write
/// itself is not exercised here: it needs a real Keychain, and a unit test that writes to the test
/// host's is the kind of side effect this suite must not have.
@Suite struct KeychainStatusTests {

    @Test func aDescriptionKeepsTheCode() {
        let missingEntitlement = KeychainService.describe(-34018)
        #expect(missingEntitlement.contains("-34018"))
        #expect(KeychainService.describe(errSecDuplicateItem).contains("\(errSecDuplicateItem)"))
        #expect(KeychainService.describe(errSecSuccess).contains("(OSStatus 0)"))
    }

    /// An empty value is a remove, reported with the remove's REAL status — not a sentinel — and `set`
    /// stays the Bool view of `store`. Asserted as wiring, not as an outcome: an unsigned test host has
    /// no application-identifier entitlement, so the data-protection keychain refuses even a delete
    /// here (`-34018`), and a test that expected success would be testing the host, not the code.
    @Test func anEmptyValueIsARemoveWithItsRealStatus() {
        let account = "operator.test.never-written"
        #expect(KeychainService.store("", for: account) == KeychainService.remove(account))
        #expect(KeychainService.set("", for: account) == (KeychainService.remove(account) == errSecSuccess))
        #expect(KeychainService.delete(account) == (KeychainService.remove(account) == errSecSuccess))
    }
}
