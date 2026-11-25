import Testing
import Foundation
@testable import EzPDFCore

@Suite struct KindleSenderTests {
    @Test func pullsOurScriptErrorsOutOfOsascriptOutput() {
        let err = "-: execution error: Mail didn't send it. Check Mail is signed in to your email account. (9004)\n"
        #expect(KindleSender.scriptMessage(err) == "Mail didn't send it. Check Mail is signed in to your email account.")
        #expect(KindleSender.scriptMessage("-: execution error: Mail got an error: AppleEvent timed out. (-1712)") == nil)
    }
}

@Suite struct KindleSettingsTests {
    @Test func oldSettingsStillLoad() throws {
        let old = #"{"address":"me_x@kindle.com","method":"mailAutomatic","preferEPUB":false}"#
        let s = try JSONDecoder().decode(KindleSender.Settings.self, from: Data(old.utf8))
        #expect(s.address == "me_x@kindle.com")
        #expect(s.preferEPUB == false)
        #expect(s.sender == "")
    }

    @Test @MainActor func automaticSendNeedsASender() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: EzPDFError.self) {
            try await KindleSender.send(file: file, title: "T", settings: .init(address: "me_x@kindle.com", method: .mailAutomatic))
        }
    }
}

@Suite struct KindleRecentTests {
    @Test func remembersMostRecentFirstWithoutRepeats() {
        var s = KindleSender.Settings()
        s.remember("a_1@kindle.com"); s.remember("b_2@kindle.com"); s.remember("A_1@kindle.com")
        #expect(s.recent == ["A_1@kindle.com", "b_2@kindle.com"])
        for i in 0..<10 { s.remember("x\(i)@kindle.com") }
        #expect(s.recent.count == 6)
        #expect(s.recent.first == "x9@kindle.com")
    }
}
