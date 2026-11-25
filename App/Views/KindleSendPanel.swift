import SwiftUI
import EzPDFCore

/// Mail accounts, read once per run: asking Mail takes a moment and they rarely change.
@MainActor enum MailAccounts {
    static var cached: [String]?
    static func load() async -> [String] {
        if let cached { return cached }
        let found = await KindleSender.mailAccounts()
        if !found.isEmpty { cached = found }
        return found
    }
}

/// Where a Kindle send goes and who it comes from, chosen at send time.
/// Opens on the last choices, so Return sends straight away; Esc cancels.
struct KindleSendPanel: View {
    let record: DocumentRecord
    var onClose: () -> Void

    @Environment(AppModel.self) private var app
    @State private var s = KindleSender.Settings.load()
    @State private var to = ""
    @State private var from = ""
    @State private var epub = false
    @State private var accounts: [String]?
    @FocusState private var toFocused: Bool

    private var trimmedTo: String { to.trimmingCharacters(in: .whitespaces) }
    private var toValid: Bool { KindleSender.isValidKindleAddress(trimmedTo) }
    private var needsSender: Bool { s.method == .mailAutomatic }
    private var canSend: Bool { toValid && (!needsSender || !from.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send to Kindle").font(.headline)
                Text(record.title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("To").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    toField
                }
                if needsSender {
                    GridRow {
                        Text("From").foregroundStyle(.secondary)
                        fromField
                    }
                }
                if record.hasEPUB {
                    GridRow {
                        Text("As").foregroundStyle(.secondary)
                        Picker("", selection: $epub) {
                            Text("EPUB").tag(true)
                            Text("PDF").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }

            hint

            HStack {
                if !needsSender {
                    Text("Opens a Mail draft for you to send.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(PressableStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .buttonStyle(PressableStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            to = s.address.isEmpty ? (s.recent.first ?? "") : s.address
            from = s.sender
            epub = s.preferEPUB && record.hasEPUB
            if to.isEmpty { toFocused = true }
        }
        .task {
            guard needsSender else { return }
            let found = await MailAccounts.load()
            accounts = found
            if from.isEmpty, found.count == 1 { from = found[0] }
        }
    }

    /// Type an address, or pick one sent to before.
    private var toField: some View {
        HStack(spacing: 4) {
            TextField("To", text: $to, prompt: Text("name_abc123@kindle.com"))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .focused($toFocused)
                .onSubmit { if canSend { send() } }
            let others = s.recent.filter { $0.caseInsensitiveCompare(trimmedTo) != .orderedSame }
            if !others.isEmpty || !s.recent.isEmpty {
                Menu {
                    Section("Sent to before") {
                        ForEach(s.recent, id: \.self) { a in
                            Button { to = a } label: {
                                if a.caseInsensitiveCompare(trimmedTo) == .orderedSame { Label(a, systemImage: "checkmark") } else { Text(a) }
                            }
                        }
                    }
                    Divider()
                    Button("Clear History") { s.recent = []; var saved = KindleSender.Settings.load(); saved.recent = []; saved.save() }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Addresses you've sent to")
            }
        }
    }

    @ViewBuilder private var fromField: some View {
        if let accounts, !accounts.isEmpty {
            Picker("", selection: $from) {
                if from.isEmpty { Text("Choose an account").tag("") }
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
                if !from.isEmpty, !accounts.contains(where: { $0.caseInsensitiveCompare(from) == .orderedSame }) {
                    Text("\(from) (not in Mail)").tag(from)
                }
            }
            .labelsHidden()
        } else if accounts == nil {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking Mail…").foregroundStyle(.secondary) }
        } else {
            TextField("From", text: $from, prompt: Text("you@example.com"))
                .textFieldStyle(.roundedBorder).labelsHidden()
        }
    }

    /// One line under the fields: what's wrong, or the one thing worth remembering.
    @ViewBuilder private var hint: some View {
        if !trimmedTo.isEmpty && !toValid {
            Label("Kindle addresses end in @kindle.com", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if needsSender && !from.isEmpty {
            Text("Amazon only delivers from addresses on your approved list. Make sure \(from) is on it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send() {
        guard canSend else { return }
        // These become the defaults next time; the address joins the history once the send works.
        var saved = KindleSender.Settings.load()
        saved.address = trimmedTo
        if needsSender { saved.sender = from }
        saved.save()
        onClose()
        app.send(record, toKindleAs: record.hasEPUB ? (epub ? .epub : .pdf) : nil, to: trimmedTo)
    }
}

/// The paperplane button with its panel anchored to it.
struct KindleSendButton: View {
    let record: DocumentRecord
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Image(systemName: "paperplane") }
            .help("Send to Kindle (⇧⌘K)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                KindleSendPanel(record: record) { open = false }
            }
    }
}
