import SwiftUI
import EzPDFCore

/// A document's change log: who changed what, and whether it worked.
struct HistorySheet: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var events: [DocumentEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History of “\(record.title)”").font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
            }
            if events.isEmpty {
                Text("No changes recorded yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(e.ok ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.action) · \(e.by)").font(.callout.weight(.medium))
                            if !e.detail.isEmpty { Text(e.detail.replacingOccurrences(of: "\n", with: "  ·  ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            if !e.ok, !e.result.isEmpty { Text(e.result).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                        }
                        Spacer()
                        Text(e.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(width: 560, height: 440)
        .onAppear { events = (try? app.ops.history(record.id, limit: 300)) ?? [] }
    }
}

/// Settings › Assistant › Memory: what the assistant remembers about you, to read, add to and delete.
struct MemorySection: View {
    @State private var notes: [MemoryNote] = []
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(notes.reversed()) { n in
                HStack {
                    Text(n.text).textSelection(.enabled)
                    Spacer()
                    Text(n.source).font(.caption).foregroundStyle(.secondary)
                    Button { forget(n) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Forget this")
                }
            }
            HStack {
                TextField("Something to remember, like “Sign as Hari L.”", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Remember", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Memory")
        } footer: {
            Text("The assistant reads these with every request, and saves new ones when you tell it something lasting. They stay in your library on this Mac and go only to the model you chose, with your request.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { notes = EzPDF.shared.memory() }
    }

    private func add() {
        do { try EzPDF.shared.remember(draft, source: "you"); draft = ""; problem = nil; notes = EzPDF.shared.memory() }
        catch { problem = error.localizedDescription }
    }

    private func forget(_ n: MemoryNote) {
        do { try EzPDF.shared.forget(id: n.id); notes = EzPDF.shared.memory() }
        catch { problem = error.localizedDescription }
    }
}
