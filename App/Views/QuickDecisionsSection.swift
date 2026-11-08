import SwiftUI
import EzPDFCore

/// Settings › Assistant › Quick decisions (from ezRecord's AI settings): the small decision model that makes
/// instant commands instant. Optional: without one, the assistant's language model handles everything.
struct QuickDecisionsSection: View {
    @AppStorage(DecisionProvider.key) private var provider = DecisionProvider.jev.rawValue
    @AppStorage(DecisionClient.clefAccountKey) private var clefAccount = ""
    @AppStorage(DecisionClient.clefModelKey) private var clefModel = "clef-flash"
    @AppStorage(DecisionClient.layaEndpointKey) private var layaEndpoint = DecisionClient.defaultLayaEndpoint
    @AppStorage(DecisionClient.layaModelKey) private var layaModel = "typed-decisions"
    @State private var jevKey = ""
    @State private var clefToken = ""
    @State private var hasJevKey = Secrets.has(DecisionClient.keyAccount)
    @State private var hasClefToken = Secrets.has(DecisionClient.clefTokenAccount)
    @State private var failure: String?
    @State private var test: String?
    @State private var testing = false

    private var chosen: DecisionProvider { DecisionProvider(rawValue: provider) ?? .jev }

    var body: some View {
        Section {
            Picker("Decision model", selection: $provider) {
                ForEach(DecisionProvider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            switch chosen {
            case .jev:
                secretRow("TypeSafe API key", placeholder: "ts_…", text: $jevKey, saved: $hasJevKey, account: DecisionClient.keyAccount)
            case .clef:
                LabeledContent("Cloudflare account ID") {
                    TextField("Account ID", text: $clefAccount, prompt: Text("32 letters and digits")).textFieldStyle(.roundedBorder)
                }
                secretRow("Workers AI token", placeholder: "API token with Workers AI: Read", text: $clefToken, saved: $hasClefToken,
                          account: DecisionClient.clefTokenAccount)
                Picker("Size", selection: $clefModel) {
                    Text("Clef-flash (fast, cheapest)").tag("clef-flash")
                    Text("Clef (most precise)").tag("clef")
                }
            case .laya:
                LabeledContent("Server") {
                    TextField("Server", text: $layaEndpoint, prompt: Text(DecisionClient.defaultLayaEndpoint)).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Checkpoint") {
                    TextField("Checkpoint", text: $layaModel, prompt: Text("typed-decisions")).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button(testing ? "Testing…" : "Test") { Task { await runTest() } }.disabled(testing)
                if let test { Text(test).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Quick decisions")
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var note: String {
        let what = "Makes everyday requests instant (“compress it”, “make it searchable”, “undo that”, “make this fillable”, “send it to my Kindle”): a small model picks the action in a fraction of a second, and anything else still goes to the assistant's model. Optional."
        switch chosen {
        case .jev: return what + " Jev sends the request text to TypeSafe; it costs a tiny fraction of a cent."
        case .clef: return what + " Clef runs on your own Cloudflare account (Workers AI), within its free daily allowance for typical use."
        case .laya: return what + " Laya runs on a server you start (laya-serve); nothing leaves it. Untuned it's weak at these choices."
        }
    }

    private func secretRow(_ title: String, placeholder: String, text: Binding<String>, saved: Binding<Bool>, account: String) -> some View {
        LabeledContent(title) {
            HStack {
                SecureField(saved.wrappedValue ? "Saved in the Keychain" : placeholder, text: text).textFieldStyle(.roundedBorder)
                    .onSubmit { save(text, saved, account) }
                Button("Save") { save(text, saved, account) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved.wrappedValue {
                    Button("Remove") { Secrets.set(nil, for: account); saved.wrappedValue = false }
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
        }
    }

    private func save(_ text: Binding<String>, _ saved: Binding<Bool>, _ account: String) {
        let status = Secrets.set(text.wrappedValue, for: account)
        text.wrappedValue = ""
        saved.wrappedValue = Secrets.has(account)
        failure = status == errSecSuccess ? nil : "The Keychain didn't save it (error \(status))."
    }

    /// One routing question to the chosen model, timed.
    private func runTest() async {
        testing = true
        defer { testing = false }
        guard let client = DecisionClient.current else { test = "Not set up yet: add the key, token or server above."; return }
        let started = ContinuousClock.now
        do {
            let answers = try await client.ask(state: ["request": "please make this file smaller"],
                                               questions: ["smaller": .noul("Does `request` ask to make a document smaller (compress it)?")])
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            let p = answers["smaller"].map { String(format: "%.2f", $0.value) } ?? "?"
            test = "Works: \(client.model) answered in \(ms) ms (probability \(p))."
        } catch {
            test = error.localizedDescription
        }
    }
}
